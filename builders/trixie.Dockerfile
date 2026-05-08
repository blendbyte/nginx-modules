FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive

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
        libpcre2-dev \
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
# (Public key fingerprint pinned inline; see bookworm.Dockerfile for the
# rationale on why this isn't an ARG.)
RUN FP=573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 && \
    install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor \
        | tee /etc/apt/keyrings/nginx.gpg > /dev/null && \
    gpg --no-default-keyring --keyring /etc/apt/keyrings/nginx.gpg \
        --list-keys --with-fingerprint --with-colons | \
        grep -q "$FP" || \
        (echo "ERROR: nginx GPG key fingerprint mismatch" && exit 1) && \
    echo "deb [signed-by=/etc/apt/keyrings/nginx.gpg] https://nginx.org/packages/debian trixie nginx" \
        > /etc/apt/sources.list.d/nginx.list && \
    echo "deb-src [signed-by=/etc/apt/keyrings/nginx.gpg] https://nginx.org/packages/debian trixie nginx" \
        >> /etc/apt/sources.list.d/nginx.list && \
    apt-get update

RUN apt-get install -y --no-install-recommends nginx && \
    cd /usr/src && apt-get source nginx && \
    rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends \
        libzstd-dev \
        libmodsecurity-dev \
        libmaxminddb-dev \
        libxml2-dev \
        libxslt1-dev \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -ms /bin/bash -u 1000 builder && \
    install -d -o builder -g builder /workspace /artifacts

USER builder
WORKDIR /workspace

ENTRYPOINT ["/bin/bash"]
CMD ["/workspace/scripts/build.sh"]
