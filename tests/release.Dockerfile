FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    apt dpkg-dev reprepro gnupg python3 python3-debian python3-yaml \
    shellcheck ca-certificates nodejs \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
CMD ["python3", "-m", "unittest", "discover", "-s", "tests", "-v"]
