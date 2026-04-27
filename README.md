# nginx-modules

Debian packages of nginx dynamic modules for Debian Bookworm and Trixie. Built against the official [nginx.org](https://nginx.org) stable releases. Free to use.

> **We only provide modules, not nginx itself.** You need the official nginx.org repo installed first. This repo sits alongside it -- apt treats them as one source.

## Why this exists

We run a lot of nginx at Blendbyte. We need brotli, geoip2, headers-more, and a few others. Sury's nginx repo wound down (archived December 2025), the alternatives either cost money or depend on a single person with a lot on their plate. So we built our own and figured we'd share it.

You probably want this if you were on sury and need somewhere to go, or if you want prebuilt modules that stay current without compiling anything yourself.

You probably don't want this if you're on Ubuntu (might work, not tested), need a module we don't ship, or need an SLA (try [GetPageSpeed](https://www.getpagespeed.com/) or [NGINX Plus](https://www.nginx.com/products/nginx/)).


## Quick start

**Step 0:** make sure you have the [official nginx.org repo](https://nginx.org/en/linux_packages.html) set up. These packages depend on nginx from there -- they won't work with Debian's own nginx package.

Once that's done:

```bash
sudo install -d -m 0755 /etc/apt/keyrings

curl -fsSL https://apt.blendbyte.net/nginx/blendbyte-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/blendbyte.gpg >/dev/null

echo "deb [signed-by=/etc/apt/keyrings/blendbyte.gpg] https://apt.blendbyte.net/nginx $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/blendbyte.list

sudo apt update
sudo apt install nginx-module-brotli nginx-module-geoip2 nginx-module-headers-more
```

Most packages auto-enable on install. If one doesn't:

```bash
sudo ln -s /etc/nginx/modules-available/50-mod-brotli.conf /etc/nginx/modules-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

## What's in the box

| Package | What it does | Replaces (sury) |
|---|---|---|
| `nginx-module-brotli` | Brotli compression | `libnginx-mod-http-brotli-filter` |
| `nginx-module-brotli-static` | Serve pre-compressed Brotli files | `libnginx-mod-http-brotli-static` |
| `nginx-module-zstd` | Zstandard compression | *(new)* |
| `nginx-module-modsecurity` | ModSecurity v3 WAF | *(new)* |
| `nginx-module-geoip2` | MaxMind GeoIP2 (HTTP) | `libnginx-mod-http-geoip2` |
| `nginx-module-stream-geoip2` | MaxMind GeoIP2 (Stream) | `libnginx-mod-stream-geoip2` |
| `nginx-module-headers-more` | Modify response headers | `libnginx-mod-http-headers-more-filter` |
| `nginx-module-substitutions` | Regex substitutions in response bodies | `libnginx-mod-http-subs-filter` |
| `nginx-module-cache-purge` | Purge the FastCGI/proxy cache | `libnginx-mod-http-cache-purge` |
| `nginx-module-fancyindex` | Pretty directory listings | `libnginx-mod-http-fancyindex` |
| `nginx-module-dav-ext` | Full WebDAV support | `libnginx-mod-http-dav-ext` |

### What we don't ship

A few things that come up:

- **Lua** -- use [OpenResty](https://openresty.org/) instead. Bolting the Lua module onto stock nginx is a bad time.
- **VTS** -- the [nginx-prometheus-exporter](https://github.com/nginx/nginx-prometheus-exporter) sidecar is more flexible and doesn't require a custom nginx build.
- **GeoIP v1** -- MaxMind killed those databases in 2018. Use `nginx-module-geoip2`.
- **PageSpeed** -- Google archived it in 2020. It's done.
- **njs, otel, acme, image-filter, perl, xslt** -- already available from the official nginx.org repo. Get them there.
- **stream and mail modules** -- already compiled into the nginx.org `nginx` package. Nothing to install.

We only ship modules we actually run in production. If it's not on the list, we probably either don't need it or there's a better answer.

## Coming from sury?

The migration is one apt transaction. Our packages declare `Replaces`, `Conflicts`, and `Provides` so apt handles the rename automatically. You don't need to touch your nginx configs.

**Before you migrate**, check if you're using any sury packages we don't replace:

```bash
dpkg -l | grep -E '^ii\s+libnginx-mod-' | awk '{print $2}'
```

The packages we can't replace: `libnginx-mod-http-geoip` (v1 GeoIP, dead since 2018), `libnginx-mod-http-lua` (use OpenResty), `libnginx-mod-http-ndk` (Lua dependency, same answer), `libnginx-mod-http-echo` (use `return 200 "text";`), `libnginx-mod-http-uploadprogress`, `libnginx-mod-http-upstream-fair` (use `least_conn`), `libnginx-mod-http-auth-pam`, `libnginx-mod-http-image-filter` / `perl` / `xslt` (get from nginx.org). If any of these are in your config, fix that first or nginx won't start after the swap.

**Backup your config** (optional but you'll thank yourself):

```bash
sudo tar czf /root/nginx-config-backup-$(date +%Y%m%d).tar.gz /etc/nginx/
```

**Run the migration:**

```bash
# Remove sury's nginx repo (leave PHP alone if you use sury for that)
sudo rm -f /etc/apt/sources.list.d/sury-nginx.list

# Add ours
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.blendbyte.net/nginx/blendbyte-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/blendbyte.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/blendbyte.gpg] https://apt.blendbyte.net/nginx $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/blendbyte.list

# Pin to avoid conflicts with other module sources
cat <<EOF | sudo tee /etc/apt/preferences.d/blendbyte-nginx
Package: nginx-module-*
Pin: origin apt.blendbyte.net
Pin-Priority: 1001
EOF

sudo apt update && sudo apt upgrade
```

You should see apt pulling in the new packages and removing the sury ones in the same transaction. Then verify:

```bash
sudo nginx -t && sudo systemctl reload nginx
sudo tail -20 /var/log/nginx/error.log
```

**To roll back** if something goes wrong:

```bash
echo "deb https://packages.sury.org/nginx/ $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/sury-nginx.list
curl -fsSL https://packages.sury.org/nginx/apt.gpg | sudo apt-key add -
sudo rm /etc/apt/sources.list.d/blendbyte.list
sudo apt update && sudo apt install --reinstall libnginx-mod-http-brotli-filter # ...etc
```

## Pinning (recommended if you have multiple module sources)

```bash
cat <<EOF | sudo tee /etc/apt/preferences.d/blendbyte-nginx
Package: nginx-module-*
Pin: origin apt.blendbyte.net
Pin-Priority: 1001
EOF
```

## Versioning

Versions look like `1.0.0-1+nginx1.30.0+blendbyte1~bookworm`: upstream module version, our packaging revision, the nginx version it was built for, and the distro. The `+nginx1.30.0` part prevents apt from installing a 1.30-built module on nginx 1.32. Each package also declares `Depends: nginx-abi-X.Y.Z` as a safety net.

When nginx ships a new stable release, new packages are usually out within 24 hours. `apt upgrade` handles it.

## Contributing

PRs are welcome. Bug fixes, build improvements, version bumps, and docs are all fair game. Open an issue first if you're unsure.

**Adding a new module** is a bit more involved. The deal is: you maintain it. That means reviewing version bumps within two weeks, looking at build failures within a week, and responding to upstream security advisories. It's not a lifetime sentence -- if you want out, open a PR to remove yourself. If nobody steps up within 30 days, the module gets pulled (existing packages stay in the pool so nothing breaks for existing users).

To add a module:
1. Open a PR adding it to `modules.yaml` (schema is documented at the top of that file)
2. Make sure all four CI jobs pass (Bookworm + Trixie, amd64 + arm64)
3. Add yourself as maintainer in `modules.yaml`
4. Update the sury migration table above if it replaces a sury package

We close "please add X" issues without a maintainer attached. Nothing personal, it's just how a small project stays manageable.

## Security

Found something? Email `security@blendbyte.net`. Full policy, response timelines, GPG key, and supply chain details are in [SECURITY.md](./SECURITY.md).

## License

Build scripts, CI, packaging, and docs in this repo are [BSD-2-Clause](LICENSE). Each compiled module keeps its own upstream license -- see the package's `debian/copyright`.
