FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

# Base build tools (kept minimal; per-module deps are added at build time
# via apt install in build.sh, driven by build_deps in modules.yaml)
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        build-essential \
        debhelper \
        dpkg-dev \
        devscripts \
        fakeroot \
        git \
        cmake \
        pkg-config \
        libssl-dev \
        libpcre3-dev \
        zlib1g-dev \
        jq \
        rsync \
    && rm -rf /var/lib/apt/lists/*

# yq (mikefarah, the Go one). Single static binary, used by build.sh and
# resolve-refs.sh to slice modules.yaml.
ARG YQ_VERSION=v4.45.1
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" \
        -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq && \
    yq --version

# Add nginx.org's official APT repository
# (Public key fingerprint pinned inline for verification. The fingerprint
# is public information; it's published by nginx.org so anyone can verify
# the signing key. Keeping it as a local shell var avoids Docker's
# SecretsUsedInArgOrEnv linter false-positive on names containing "key".)
RUN FP=573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 && \
    install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor \
        | tee /etc/apt/keyrings/nginx.gpg > /dev/null && \
    gpg --no-default-keyring --keyring /etc/apt/keyrings/nginx.gpg \
        --list-keys --with-fingerprint --with-colons | \
        grep -q "$FP" || \
        (echo "ERROR: nginx GPG key fingerprint mismatch" && exit 1) && \
    echo "deb [signed-by=/etc/apt/keyrings/nginx.gpg] https://nginx.org/packages/debian bookworm nginx" \
        > /etc/apt/sources.list.d/nginx.list && \
    echo "deb-src [signed-by=/etc/apt/keyrings/nginx.gpg] https://nginx.org/packages/debian bookworm nginx" \
        >> /etc/apt/sources.list.d/nginx.list && \
    apt-get update

# Install nginx and download matching source. The nginx.org repo ships
# binary packages only (no nginx-source convenience package like Debian's
# own archive provides), so we use 'apt-get source' against the deb-src
# line to fetch the actual upstream tarball. dpkg-source unpacks it to
# /usr/src/nginx-X.Y.Z/, which is what build.sh expects.
RUN apt-get install -y --no-install-recommends nginx && \
    cd /usr/src && apt-get source nginx && \
    rm -rf /var/lib/apt/lists/*

# Pre-install all known per-module build/runtime deps from modules.yaml
# (Doing this in the image rather than at build time saves ~30s per CI run.
# When modules.yaml grows, regenerate this list from the build_deps fields.)
RUN apt-get update && apt-get install -y --no-install-recommends \
        libbrotli-dev \
        libzstd-dev \
        libmodsecurity-dev \
        libmaxminddb-dev \
        libxml2-dev \
        libxslt1-dev \
    && rm -rf /var/lib/apt/lists/*

# Non-root build user, reduces blast radius if a build script is ever
# compromised
RUN useradd -ms /bin/bash -u 1000 builder && \
    install -d -o builder -g builder /workspace /artifacts

USER builder
WORKDIR /workspace

# The actual build command is invoked by CI as:
#   docker run --rm \
#     -v $PWD:/workspace:ro \
#     -v /tmp/artifacts:/artifacts \
#     -e ARCH=amd64 \
#     blendbyte/nginx-modules-builder:bookworm \
#     /workspace/scripts/build.sh
ENTRYPOINT ["/bin/bash"]
CMD ["/workspace/scripts/build.sh"]
