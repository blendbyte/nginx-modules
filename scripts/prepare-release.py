#!/usr/bin/env python3
"""Merge a complete module build into a restored, existing APT repository.

Requires python3-debian, python3-yaml, dpkg, reprepro, and the signing key in
GNUPGHOME. Only the local staging tree is changed; this script never uploads.
"""

import argparse
import hashlib
import itertools
import re
import subprocess
import sys
from pathlib import Path

import yaml
from debian.deb822 import Deb822, Packages, Release


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def nginx_dependency(record):
    match = re.search(r"(?:^|,)\s*nginx\s*\(=\s*([^()]+)\)", record.get("Depends", ""))
    require(match, f"{record['Package']} has no exact nginx dependency")
    return match.group(1).strip()


def read_indexes(repo, codenames, architectures):
    """Verify signatures and index checksums before trusting package records."""
    records = {}
    for codename in codenames:
        dist = repo / "dists" / codename
        run("gpg", "--batch", "--verify", str(dist / "Release.gpg"), str(dist / "Release"))
        release = Release((dist / "Release").read_text())
        checksums = {entry["name"]: entry for entry in release.get("SHA256", [])}
        for arch in architectures:
            name = f"main/binary-{arch}/Packages"
            path = dist / name
            require(path.is_file() and name in checksums, f"Missing published index: {codename}/{name}")
            checksum = checksums[name]
            require(digest(path) == checksum["sha256"] and path.stat().st_size == int(checksum["size"]),
                    f"Index checksum mismatch: {codename}/{name}")
            packages = list(Packages.iter_paragraphs(path.read_text(), use_apt_pkg=False))
            require(packages, f"Empty published index: {codename}/{name}")
            for record in packages:
                require(record["Architecture"] == arch, f"Unexpected architecture in {path}")
                key = (codename, arch, record["Package"])
                require(key not in records, f"Duplicate package in index: {key}")
                records[key] = dict(record)
    return records


def check_preserved(before, after, updates):
    require(set(after) == set(before) | set(updates), "Package inventory changed unexpectedly; refusing to publish")
    for key, record in before.items():
        if key not in updates:
            require(after[key] == record, f"Unrelated package changed: {key}")
    for key, update in updates.items():
        record = after[key]
        for field in ("Package", "Version", "Architecture", "Depends", "SHA256", "Size"):
            require(record.get(field) == update.get(field), f"Imported {key} has incorrect {field}")


def prepare(repo, artifacts, manifest):
    config = manifest["config"]
    codenames = config["debian_codenames"] + config["ubuntu_codenames"]
    architectures = config["architectures"]
    names = {module["name"] for module in manifest["modules"]}

    # A missing database is never treated as a new repository. Bootstrap or
    # recovery must be done separately, otherwise a partial build could erase
    # every unrelated package from the published indexes.
    database = repo / "db" / "packages.db"
    require(database.is_file() and database.stat().st_size > 0, "Missing repository database; refusing to initialize an empty repo")
    before = read_indexes(repo, codenames, architectures)
    updates = {}
    paths = {}
    for path in sorted(artifacts.glob("*.deb")):
        record = dict(Deb822(run("dpkg-deb", "--field", str(path))))
        name, version, arch = (record[field] for field in ("Package", "Version", "Architecture"))
        require(name in names, f"Unknown module: {name}")
        require(arch in architectures, f"Unsupported architecture: {arch}")
        codename = version.rsplit("~", 1)[-1]
        require(codename in codenames, f"Unknown distribution in package version: {version}")
        require(re.fullmatch(r"[0-9A-Za-z.+~:-]+-\d+\+nginx[0-9.]+\+blendbyte\d+~" + re.escape(codename), version),
                f"Unexpected package version: {version}")
        key = (codename, arch, name)
        require(key not in updates, f"Duplicate build artifact: {key}")
        record.update(SHA256=digest(path), Size=str(path.stat().st_size))
        nginx_dependency(record)
        if key in before:
            old = before[key]
            require(subprocess.run(["dpkg", "--compare-versions", version, "ge", old["Version"]]).returncode == 0,
                    f"Refusing downgrade of {key}: {old['Version']} to {version}")
            require(version != old["Version"] or record["SHA256"] == old["SHA256"],
                    f"Package bytes changed without a version bump: {key}")
        updates[key], paths[key] = record, path
    require(updates, "No .deb artifacts to publish")
    selected = {key[2] for key in updates}
    expected = set(itertools.product(codenames, architectures, selected))
    require(set(updates) == expected, f"Incomplete build matrix; missing: {sorted(expected - set(updates))}")
    for name in selected:
        versions = {record["Version"].rsplit("~", 1)[0] for key, record in updates.items() if key[2] == name}
        require(len(versions) == 1, f"Mixed build versions for {name}")

    # All modules in one suite/architecture must remain installable together.
    # A partial rebuild against a newer nginx requires a full rebuild instead.
    merged = before | updates
    for codename, arch in itertools.product(codenames, architectures):
        deps = {nginx_dependency(record) for key, record in merged.items() if key[:2] == (codename, arch)}
        require(len(deps) == 1, f"Mixed nginx dependencies for {codename}/{arch}; rebuild all modules against the same nginx package")

    # Export from the restored database and compare with the signed, published
    # indexes. Restoring dists/ alone cannot reconstruct reprepro's database.
    run("reprepro", "--basedir", str(repo), "export")
    restored = read_indexes(repo, codenames, architectures)
    require(restored == before, "Repository database does not match published indexes; refusing to publish")
    for key, path in paths.items():
        if key in before and before[key]["Version"] == updates[key]["Version"]:
            continue  # An identical release is safely repeatable without pool/.
        run("reprepro", "--basedir", str(repo), "--keepunreferencedfiles", "--export=never", "includedeb", key[0], str(path))
    run("reprepro", "--basedir", str(repo), "export")
    after = read_indexes(repo, codenames, architectures)
    check_preserved(before, after, updates)
    for key, record in updates.items():
        if key in before and before[key]["SHA256"] == record["SHA256"]:
            continue
        filename = Path(after[key]["Filename"])
        require(not filename.is_absolute() and ".." not in filename.parts and filename.parts[0] == "pool",
                f"Invalid pool filename: {filename}")
        require(digest(repo / filename) == record["SHA256"], f"Pool file checksum mismatch: {key}")
    print(f"Validated {len(updates)} artifacts for {', '.join(sorted(selected))}; "
          f"preserved {len(set(before) - set(updates))} unrelated package entries.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", type=Path)
    parser.add_argument("artifacts", type=Path)
    parser.add_argument("--manifest", type=Path, default=Path("modules.yaml"))
    args = parser.parse_args()
    try:
        prepare(args.repo.resolve(), args.artifacts.resolve(), yaml.safe_load(args.manifest.read_text()))
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.output, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
