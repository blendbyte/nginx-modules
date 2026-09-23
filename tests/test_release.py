"""Integration tests using real Debian packages, signed indexes, and APT.

Run in tests/release.Dockerfile so no host APT configuration is touched.
"""

import importlib.util
import itertools
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release", ROOT / "scripts/prepare-release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


def run(*args, **kwargs):
    return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True, **kwargs)


class ReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.home = cls.root / "gnupg"
        cls.home.mkdir(mode=0o700)
        cls.old_home = os.environ.get("GNUPGHOME")
        os.environ["GNUPGHOME"] = str(cls.home)
        run("gpg", "--batch", "--passphrase", "", "--quick-generate-key",
            "Repository integration tests <test@example.invalid>", "ed25519", "sign", "0")
        cls.key = next(line.split(":")[9] for line in run("gpg", "--with-colons", "--list-keys").splitlines()
                       if line.startswith("fpr:"))
        cls.manifest = yaml.safe_load((ROOT / "modules.yaml").read_text())
        cls.codenames = cls.manifest["config"]["debian_codenames"] + cls.manifest["config"]["ubuntu_codenames"]
        cls.architectures = cls.manifest["config"]["architectures"]
        cls.names = ["nginx-module-cache-purge", "nginx-module-headers-more"]
        cls.base = cls.root / "published"
        (cls.base / "conf").mkdir(parents=True)
        (cls.base / "conf/distributions").write_text("".join(
            f"Codename: {code}\nSuite: {code}\nComponents: main\n"
            f"Architectures: {' '.join(cls.architectures)} source\nSignWith: {cls.key}\n\n"
            for code in cls.codenames))
        for name, code, arch in itertools.product(cls.names, cls.codenames, cls.architectures):
            deb = cls.package(cls.root / "seed", name, code, arch)
            run("reprepro", "--basedir", str(cls.base), "--export=never", "includedeb", code, str(deb))
        run("reprepro", "--basedir", str(cls.base), "export")
        cls.before = release.read_indexes(cls.base, cls.codenames, cls.architectures)

    @classmethod
    def tearDownClass(cls):
        run("gpgconf", "--kill", "gpg-agent")
        if cls.old_home is None:
            os.environ.pop("GNUPGHOME", None)
        else:
            os.environ["GNUPGHOME"] = cls.old_home
        cls.temp.cleanup()

    @classmethod
    def package(cls, destination, name, code, arch, serial=1, nginx="1.30.5", payload=None):
        destination.mkdir(parents=True, exist_ok=True)
        version = f"1.0-1+nginx{nginx}+blendbyte{serial}~{code}"
        with tempfile.TemporaryDirectory(dir=cls.root) as directory:
            tree = Path(directory)
            (tree / "DEBIAN").mkdir()
            (tree / "DEBIAN/control").write_text(
                f"Package: {name}\nVersion: {version}\nArchitecture: {arch}\n"
                f"Depends: nginx (= {nginx}-1~{code})\nSection: httpd\nPriority: optional\n"
                "Maintainer: Test <test@example.invalid>\nDescription: Release integration fixture\n")
            data = tree / "usr/share" / name
            data.mkdir(parents=True)
            (data / "payload").write_text(payload or version)
            deb = destination / f"{name}_{version}_{arch}.deb"
            run("dpkg-deb", "--build", "--root-owner-group", str(tree), str(deb))
            return deb

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(dir=self.root))
        self.repo = self.work / "repo"
        # Match production: restore db/ and dists/, but no historical pool/.
        shutil.copytree(self.base, self.repo, ignore=shutil.ignore_patterns("pool"))
        self.artifacts = self.work / "artifacts"
        self.artifacts.mkdir()

    def tearDown(self):
        shutil.rmtree(self.work)

    def build(self, names=None, serial=2, nginx="1.30.5"):
        for name, code, arch in itertools.product(names or self.names[:1], self.codenames, self.architectures):
            self.package(self.artifacts, name, code, arch, serial=serial, nginx=nginx)

    def prepare(self):
        release.prepare(self.repo, self.artifacts, self.manifest)

    def test_partial_update_preserves_other_packages_and_apt_downloads_both(self):
        self.build()
        output = run("python3", str(ROOT / "scripts/prepare-release.py"), str(self.repo),
                     str(self.artifacts), "--manifest", str(ROOT / "modules.yaml"))
        self.assertIn("preserved 10 unrelated package entries", output)
        after = release.read_indexes(self.repo, self.codenames, self.architectures)
        self.assertEqual(set(after), set(self.before))
        for key, record in self.before.items():
            if key[2] == self.names[1]:
                self.assertEqual(record, after[key])
        # Emulate the resulting object store: old pool objects remain present
        # and only the new payloads and indexes are added/replaced.
        published = self.work / "published"
        shutil.copytree(self.base, published)
        shutil.copytree(self.repo, published, dirs_exist_ok=True)
        for record in after.values():
            self.assertEqual(release.digest(published / record["Filename"]), record["SHA256"])

        # A real APT client verifies signatures and downloads both the changed
        # and unchanged package from the merged repository.
        apt = self.work / "apt"
        for directory in ("state/lists/partial", "cache/archives/partial", "downloads"):
            (apt / directory).mkdir(parents=True)
        keyring = apt / "keyring.gpg"
        keyring.write_bytes(subprocess.check_output(["gpg", "--export", self.key]))
        (apt / "sources.list").write_text(
            f"deb [signed-by={keyring}] file:{published} bookworm main\n")
        command = ["apt-get", "-o", f"Dir::Etc::sourcelist={apt / 'sources.list'}",
                   "-o", "Dir::Etc::sourceparts=-", "-o", f"Dir::State={apt / 'state'}",
                   "-o", f"Dir::Cache={apt / 'cache'}", "-o", "APT::Architecture=amd64",
                   "-o", "APT::Architectures::=amd64", "-o", "Acquire::Languages=none",
                   "-o", "APT::Sandbox::User=root"]
        run(*command, "update")
        run(*command, "download", *self.names, cwd=apt / "downloads")
        downloads = list((apt / "downloads").glob("*.deb"))
        self.assertEqual(len(downloads), 2)
        for path in downloads:
            name = run("dpkg-deb", "-f", str(path), "Package").strip()
            self.assertEqual(release.digest(path), after[("bookworm", "amd64", name)]["SHA256"])

    def test_full_rebuild_can_change_nginx(self):
        self.build(self.names, nginx="1.30.6")
        self.prepare()
        after = release.read_indexes(self.repo, self.codenames, self.architectures)
        self.assertTrue(all("1.30.6" in record["Depends"] for record in after.values()))

    def test_partial_rebuild_cannot_change_nginx(self):
        self.build(nginx="1.30.6")
        with self.assertRaisesRegex(ValueError, "Mixed nginx dependencies"):
            self.prepare()

    def test_missing_database_is_rejected(self):
        self.build()
        shutil.rmtree(self.repo / "db")
        with self.assertRaisesRegex(ValueError, "Missing repository database"):
            self.prepare()

    def test_cli_failure_returns_nonzero(self):
        result = subprocess.run(
            ["python3", str(ROOT / "scripts/prepare-release.py"), str(self.repo), str(self.artifacts)],
            capture_output=True, text=True, cwd=ROOT)
        self.assertEqual(result.returncode, 1)
        self.assertIn("No .deb artifacts", result.stderr)

    def test_database_missing_an_indexed_package_is_rejected(self):
        self.build()
        run("reprepro", "--basedir", str(self.repo), "--keepunreferencedfiles", "--export=never",
            "remove", "bookworm", self.names[1])
        with self.assertRaisesRegex(ValueError, "database does not match"):
            self.prepare()

    def test_missing_published_index_is_rejected(self):
        self.build()
        (self.repo / "dists/bookworm/main/binary-arm64/Packages").unlink()
        with self.assertRaisesRegex(ValueError, "Missing published index"):
            self.prepare()

    def test_tampered_index_is_rejected(self):
        self.build()
        path = self.repo / "dists/bookworm/main/binary-amd64/Packages"
        path.write_text(path.read_text().replace(self.names[1], "nginx-module-missing"))
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.prepare()

    def test_invalid_signature_is_rejected(self):
        self.build()
        (self.repo / "dists/bookworm/Release.gpg").write_text("invalid signature")
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare()

    def test_empty_artifacts_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "No .deb artifacts"):
            self.prepare()

    def test_missing_architecture_artifact_is_rejected(self):
        self.build()
        next(self.artifacts.glob("*bookworm_arm64.deb")).unlink()
        with self.assertRaisesRegex(ValueError, "Incomplete build matrix"):
            self.prepare()

    def test_duplicate_artifact_is_rejected(self):
        self.build()
        shutil.copy(next(self.artifacts.glob("*.deb")), self.artifacts / "duplicate.deb")
        with self.assertRaisesRegex(ValueError, "Duplicate build artifact"):
            self.prepare()

    def test_unknown_module_is_rejected(self):
        self.build(["nginx-module-unknown"])
        with self.assertRaisesRegex(ValueError, "Unknown module"):
            self.prepare()

    def test_mixed_build_versions_are_rejected(self):
        self.build()
        next(self.artifacts.glob("*bookworm_arm64.deb")).unlink()
        self.package(self.artifacts, self.names[0], "bookworm", "arm64", serial=3)
        with self.assertRaisesRegex(ValueError, "Mixed build versions"):
            self.prepare()

    def test_downgrade_is_rejected(self):
        self.build(serial=0)
        with self.assertRaisesRegex(ValueError, "Refusing downgrade"):
            self.prepare()

    def test_changed_bytes_without_version_bump_are_rejected(self):
        for code, arch in itertools.product(self.codenames, self.architectures):
            self.package(self.artifacts, self.names[0], code, arch, payload="changed bytes")
        with self.assertRaisesRegex(ValueError, "bytes changed without a version bump"):
            self.prepare()

    def test_identical_release_can_be_repeated_without_old_pool(self):
        for path in (self.root / "seed").glob(f"{self.names[0]}_*.deb"):
            shutil.copy(path, self.artifacts)
        self.prepare()
        self.assertEqual(release.read_indexes(self.repo, self.codenames, self.architectures), self.before)

    def test_unrelated_package_loss_during_import_is_rejected(self):
        self.build()
        real_run = release.run

        def faulty_import(*args):
            result = real_run(*args)
            if "includedeb" in args:
                real_run("reprepro", "--basedir", str(self.repo), "--keepunreferencedfiles",
                         "--export=never", "remove", "bookworm", self.names[1])
            return result

        with patch.object(release, "run", side_effect=faulty_import):
            with self.assertRaisesRegex(ValueError, "inventory changed unexpectedly"):
                self.prepare()


class WorkflowTests(unittest.TestCase):
    def test_source_build_validation_handles_dispatch_race_and_failures(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())
        script = next(step["with"]["script"] for step in workflow["jobs"]["publish"]["steps"]
                      if step.get("name") == "Validate source build")
        # Execute the workflow's JavaScript with a fake GitHub API and instant
        # timers, including the automatic-dispatch race with the parent run.
        javascript = r'''
const assert = require('node:assert/strict');
const script = require('node:fs').readFileSync(0, 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const validate = new AsyncFunction('github', 'context', 'process', 'setTimeout', script);
const base = { path: '.github/workflows/build.yml',
  head_repository: { full_name: 'blendbyte/nginx-modules' },
  status: 'completed', conclusion: 'success' };
async function check(states, id = '123') {
  let calls = 0;
  const github = { rest: { actions: { getWorkflowRun: async () => ({
    data: { ...base, ...states[Math.min(calls++, states.length - 1)] }
  }) } } };
  await validate(github, { repo: { owner: 'blendbyte', repo: 'nginx-modules' } },
    { env: { BUILD_RUN_ID: id } }, callback => callback());
  return calls;
}
(async () => {
  assert.equal(await check([{}]), 1);
  assert.equal(await check([{status: 'in_progress', conclusion: null}, {}]), 2);
  await assert.rejects(check([{conclusion: 'failure'}]), /did not succeed/);
  await assert.rejects(check([{conclusion: 'cancelled'}]), /did not succeed/);
  await assert.rejects(check([{status: 'in_progress'}]), /has not completed/);
  await assert.rejects(check([{path: '.github/workflows/other.yml'}]), /Only the build workflow/);
  await assert.rejects(check([{head_repository: {full_name: 'fork/nginx-modules'}}]), /Only the build workflow/);
  await assert.rejects(check([{}], 'invalid'), /numeric/);
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
        run("node", "-e", javascript, input=script)

    def test_release_serialization_and_dry_run_validation(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())
        self.assertEqual(workflow["concurrency"], {"group": "apt-repository-production", "cancel-in-progress": False})
        steps = {step["name"]: step for step in workflow["jobs"]["publish"]["steps"] if "name" in step}
        self.assertNotIn("if", steps["Pull existing apt repo state"])
        self.assertNotIn("if", steps["Validate state and merge packages"])

    def test_transfer_order_dry_run_and_failure_propagation(self):
        # Replace only the network boundary. Exercise the actual transfer
        # script, including its argument arrays and fail-fast behavior.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            aws = root / "aws"
            aws.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\nexit "${AWS_EXIT:-0}"\n')
            aws.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", CALLS=str(root / "calls"))
            command = ["bash", str(ROOT / "scripts/sync-repo.sh")]
            run(*command, "pull", "repo", "s3://bucket", "--dry-run", env=env)
            calls = (root / "calls").read_text().splitlines()
            self.assertEqual(calls, ["s3 sync s3://bucket/db/ repo/db/", "s3 sync s3://bucket/dists/ repo/dists/"])
            (root / "calls").write_text("")
            run(*command, "push", "repo", "s3://bucket", "--dry-run", env=env)
            calls = (root / "calls").read_text().splitlines()
            self.assertEqual(len(calls), 5)
            self.assertTrue(calls[0].startswith("s3 sync repo/pool/"))
            self.assertTrue(calls[1].startswith("s3 sync repo/db/"))
            self.assertIn("--exclude */InRelease", calls[2])
            self.assertIn("--include */InRelease", calls[3])
            self.assertTrue(all("--dryrun" in call and "--delete" not in call for call in calls))
            (root / "calls").write_text("")
            with self.assertRaises(subprocess.CalledProcessError):
                run(*command, "push", "repo", "s3://bucket", env=dict(env, AWS_EXIT="1"))
            self.assertEqual(len((root / "calls").read_text().splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
