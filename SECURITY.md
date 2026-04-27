# Security

## Report something

Email **security@blendbyte.net**. Use PGP if it's sensitive (key below).

Helpful to include: affected package and version, what the issue is, a reproducer if you have one.

We'll acknowledge within 72 hours. After that:

- **Critical** (RCE, signing key compromise, malicious package): patched within 7 days, public advisory within 14
- **High** (auth bypass, privilege escalation): patched within 14 days
- **Medium / Low**: rolled into the next regular build cycle

## What's in scope

- Build infrastructure (Dockerfiles, build scripts, CI workflows)
- Packaging metadata (debian/control, postinst scripts, dependencies)
- The apt repo at apt.blendbyte.net and our GPG signing process

Not in scope: vulnerabilities in upstream module code (report to the upstream project), nginx itself (report to nginx.org), or Debian's libraries like libmaxminddb and libzstd. If you're not sure, send it to us and we'll route it.

## GPG key

All packages and repo metadata are signed with a dedicated Blendbyte APT signing key used only for this repo.

- **Key ID**: `TBD`
- **Fingerprint**: `TBD`
- **Key URL**: https://apt.blendbyte.net/nginx/blendbyte-archive-keyring.gpg
- **Backup**: https://keys.openpgp.org/

To verify:

```bash
curl -fsSL https://apt.blendbyte.net/nginx/blendbyte-archive-keyring.gpg \
  | gpg --show-keys --with-fingerprint
```

If the fingerprint doesn't match what's listed here, don't trust the keyring and open an issue immediately.

## Upstream CVEs

When a module we package gets a CVE: we watch for the upstream fix, bump `upstream_ref` in `modules.yaml` (within 7 days for High/Critical, 14 days for Medium/Low), and add a `CHANGELOG.md` entry referencing the CVE.

We don't backport to older nginx versions. Stay current.

## Supply chain

A few things we do to make attacks harder:

- Module sources are pinned to **specific commit hashes**, not tags. Tag-rewriting attacks on upstream repos don't affect our builds.
- Builds run in **clean ephemeral CI containers**.
- The signing key lives only as a **GitHub Actions secret**, accessible only to the publish workflow.
- Builds are **reproducible**: same `modules.yaml` + same nginx version + same Debian image = byte-equivalent `.deb` files.

## Honest limitations

We're not a vendor. No 24/7 incident response, no pre-disclosure embargoes, no backports, no customer notification system. Advisories go up on the GitHub Security tab and `CHANGELOG.md`. If any of that's a dealbreaker, [NGINX Plus](https://www.nginx.com/products/nginx/) or [GetPageSpeed](https://www.getpagespeed.com/) have you covered.
