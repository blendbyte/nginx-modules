# nginx-modules

Debian and Ubuntu packages of nginx dynamic modules, built against the official [nginx.org](https://nginx.org) stable releases. Supports Debian Bookworm/Trixie and Ubuntu 22.04/24.04/26.04 on amd64 and arm64.

Requires nginx from [nginx.org](https://nginx.org/en/linux_packages.html) -- not the version in Debian/Ubuntu's default repos.

```bash
sudo install -d -m 0755 /etc/apt/keyrings

curl -fsSL https://apt.blendbyte.net/nginx/blendbyte-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/blendbyte.gpg >/dev/null

echo "deb [signed-by=/etc/apt/keyrings/blendbyte.gpg] https://apt.blendbyte.net/nginx $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/blendbyte.list

sudo apt update
sudo apt install nginx-module-brotli nginx-module-geoip2 nginx-module-headers-more
```

For the full module list, migration from Sury, and more: [nginx-modules.com](https://www.nginx-modules.com)

## Contributing

PRs are welcome. Bug fixes, build improvements, version bumps, and docs are all fair game. Open an issue first if you're unsure.

**Adding a new module** is a bit more involved. The deal is: you maintain it. That means reviewing version bumps within two weeks, looking at build failures within a week, and responding to upstream security advisories. It's not a lifetime sentence -- if you want out, open a PR to remove yourself. If nobody steps up within 30 days, the module gets pulled (existing packages stay in the pool so nothing breaks for existing users).

To add a module:
1. Open a PR adding it to `modules.yaml` (schema is documented at the top of that file)
2. Make sure all ten CI jobs pass (Bookworm, Trixie, Jammy, Noble, Resolute x amd64 + arm64)
3. Add yourself as maintainer in `modules.yaml`
4. Update the sury migration table on the website if it replaces a sury package

We close "please add X" issues without a maintainer attached. Nothing personal, it's just how a small project stays manageable.

## Security

Found something? Email `security@blendbyte.net`. Full policy, response timelines, GPG key, and supply chain details are in [SECURITY.md](./SECURITY.md).

## License

Build scripts, CI, packaging, and docs in this repo are [BSD-2-Clause](LICENSE). Each compiled module keeps its own upstream license -- see the package's `debian/copyright`.

## Maintained by Blendbyte

<br>

<p align="center">
  <a href="https://www.blendbyte.com">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://www.blendbyte.com/logo_horizontal_light.png">
      <img src="https://www.blendbyte.com/logo_horizontal.png" alt="Blendbyte" width="360">
    </picture>
  </a>
</p>

<p align="center">
  <strong><a href="https://www.blendbyte.com">Blendbyte</a></strong> builds cloud infrastructure, web apps, and developer tools.<br>
  We've been shipping software to production for 20+ years.
</p>

<p align="center">
  This package runs in our own stack, which is why we keep it maintained.<br>
  Issues and PRs get read. Good ones get merged.
</p>

<br>

<p align="center">
  <a href="https://www.blendbyte.com">blendbyte.com</a> · <a href="mailto:hello@blendbyte.com">hello@blendbyte.com</a>
</p>
