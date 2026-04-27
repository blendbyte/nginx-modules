#!/usr/bin/env bash
#
# verify.sh
#
# Smoke-test built .deb files by installing them in a clean container
# and running `nginx -t` with each module loaded.
#
# Catches packaging bugs (wrong .so path, missing dependencies, broken
# config snippets) that the build itself doesn't surface.
#
# Usage:
#   ./scripts/verify.sh <codename> <arch> <artifacts-dir>
#
# Example:
#   ./scripts/verify.sh bookworm amd64 /tmp/artifacts

set -euo pipefail

CODENAME="${1:?codename required (bookworm or trixie)}"
ARCH="${2:?architecture required (amd64 or arm64)}"
ARTIFACTS_DIR="${3:?artifacts directory required}"

if [[ ! -d "${ARTIFACTS_DIR}" ]]; then
    echo "ERROR: artifacts directory not found: ${ARTIFACTS_DIR}" >&2
    exit 1
fi

DEB_COUNT=$(find "${ARTIFACTS_DIR}" -name "*_${ARCH}.deb" | wc -l)
if [[ "${DEB_COUNT}" -eq 0 ]]; then
    echo "ERROR: no .deb files found in ${ARTIFACTS_DIR} for arch ${ARCH}" >&2
    exit 1
fi

echo "Verifying ${DEB_COUNT} packages on debian:${CODENAME} (${ARCH})..."

# Run verification inside a clean container, same base as the builder
# but without our build tools, to mimic a real user install
docker run --rm \
    --platform "linux/${ARCH}" \
    -v "${ARTIFACTS_DIR}:/debs:ro" \
    "debian:${CODENAME}-slim" \
    bash -c '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive

        apt-get update -qq
        apt-get install -y --no-install-recommends \
            ca-certificates curl gnupg lsb-release > /dev/null

        # Add nginx.org official repo
        install -d -m 0755 /etc/apt/keyrings
        curl -fsSL https://nginx.org/keys/nginx_signing.key \
            | gpg --dearmor > /etc/apt/keyrings/nginx.gpg
        echo "deb [signed-by=/etc/apt/keyrings/nginx.gpg] https://nginx.org/packages/debian $(lsb_release -cs) nginx" \
            > /etc/apt/sources.list.d/nginx.list
        apt-get update -qq
        apt-get install -y --no-install-recommends nginx > /dev/null

        echo "nginx version: $(nginx -v 2>&1 | cut -d/ -f2)"

        FAIL=0
        for deb in /debs/*.deb; do
            pkg=$(dpkg-deb -f "$deb" Package)
            echo
            echo "=== Verifying ${pkg} ==="

            # Install the .deb (apt resolves dependencies from configured repos)
            if ! apt-get install -y --no-install-recommends "$deb" 2>&1 | tail -20; then
                echo "  ❌ install failed for $pkg"
                FAIL=$((FAIL+1))
                continue
            fi

            # Verify nginx config still valid
            if ! nginx -t 2>&1; then
                echo "  ❌ nginx -t failed after installing $pkg"
                FAIL=$((FAIL+1))
                continue
            fi

            # Verify the module .so was actually deployed
            so_path=$(dpkg -L "$pkg" | grep "/usr/lib/nginx/modules/.*\.so$" || true)
            if [[ -z "$so_path" ]]; then
                echo "  ❌ no .so file found in package $pkg"
                FAIL=$((FAIL+1))
                continue
            fi
            echo "  ✓ $so_path installed"

            # Remove before next iteration to test independence
            apt-get remove -y "$pkg" > /dev/null 2>&1 || true
        done

        echo
        if [[ $FAIL -eq 0 ]]; then
            echo "✅ All packages verified."
            exit 0
        else
            echo "❌ $FAIL package(s) failed verification."
            exit 1
        fi
    '
