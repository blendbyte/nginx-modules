#!/usr/bin/env bash
#
# build.sh
#
# Main build orchestrator. For each module in modules.yaml:
#   1. Look up the resolved commit hash (from .resolved-refs.yaml)
#   2. Clone the upstream source at that commit
#   3. Generate the Debian packaging tree (debian/control, rules, etc.)
#   4. Run dpkg-buildpackage to produce the .deb
#   5. Move artifacts to ARTIFACTS_DIR
#
# Designed to run inside one of the builder containers. CI invokes it via
# "docker run blendbyte/nginx-modules-builder:<codename>-<arch>".
#
# Required env:
#   ARCH              dpkg architecture (amd64 or arm64)
#
# Optional env:
#   ONLY_MODULE       Build just this one module (for development)
#   BUILD_SERIAL      Override build serial in version string (default: 1)
#   ARTIFACTS_DIR     Where finished .debs land (default: /artifacts)
#   WORK_DIR          Build scratch directory (default: /tmp/build)
#
# Exit code: 0 if all modules built successfully, 1 if any failed.
#
# Run resolve-refs.sh first to produce .resolved-refs.yaml.

set -euo pipefail

# ─── Setup ──────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES_YAML="$REPO_ROOT/modules.yaml"
RESOLVED_REFS="$REPO_ROOT/.resolved-refs.yaml"

ARCH="${ARCH:?ARCH must be set (amd64 or arm64)}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-/artifacts}"
WORK_DIR="${WORK_DIR:-/tmp/build}"
BUILD_SERIAL="${BUILD_SERIAL:-1}"
ONLY_MODULE="${ONLY_MODULE:-}"

# ─── Tool checks ────────────────────────────────────────────────────
need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: '$1' not found in PATH" >&2
        exit 1
    }
}
need yq
need jq
need git
need dpkg-buildpackage
need dpkg-query
need lsb_release

# ─── Determine target nginx version and ABI ─────────────────────────
CODENAME="$(lsb_release -cs)"
NGINX_VERSION="$(dpkg-query -f='${Version}' -W nginx | cut -d- -f1)"

# Full Debian version of nginx, e.g. "1.30.0-1~bookworm". We pin our
# module's Depends to this exact version so apt refuses to install a
# module against the wrong nginx (and refuses to upgrade nginx unless
# matching new modules are available). This is what F5's own modules in
# the official nginx.org repo do — simpler and more robust than the
# nginx-abi-* virtual package approach (which sury uses but nginx.org
# does not).
NGINX_FULL_VERSION="$(dpkg-query -f='${Version}' -W nginx)"

# ─── Header ─────────────────────────────────────────────────────────
cat <<EOF
============================================================
Building nginx-modules
  Codename:      $CODENAME
  Architecture:  $ARCH
  nginx version: $NGINX_VERSION
  nginx full:    $NGINX_FULL_VERSION
  Build serial:  $BUILD_SERIAL
$([[ -n "$ONLY_MODULE" ]] && echo "  Only module:   $ONLY_MODULE")
============================================================
EOF

mkdir -p "$ARTIFACTS_DIR" "$WORK_DIR"

# ─── Pre-flight checks ──────────────────────────────────────────────
[[ -f "$RESOLVED_REFS" ]] || {
    echo "ERROR: $RESOLVED_REFS not found. Run scripts/resolve-refs.sh first." >&2
    exit 1
}

dpkg -l nginx 2>/dev/null | grep -q '^ii' || {
    echo "ERROR: nginx package not installed" >&2
    exit 1
}

# The Dockerfile pre-fetches and unpacks nginx source via 'apt-get source'.
# build_module's debian/rules expects to find the source tree here.
[[ -d "/usr/src/nginx-${NGINX_VERSION}" ]] || {
    echo "ERROR: nginx source not found at /usr/src/nginx-${NGINX_VERSION}" >&2
    echo "       The builder image should have unpacked it at image-build time." >&2
    echo "       Check the Dockerfile's 'apt-get source nginx' step." >&2
    exit 1
}

# ─── Convert YAML inputs to JSON once ───────────────────────────────
MODULES_JSON="$WORK_DIR/.modules.json"
RESOLVED_JSON="$WORK_DIR/.resolved.json"
yq -o json '.modules'   "$MODULES_YAML"   > "$MODULES_JSON"
yq -o json '.modules'   "$RESOLVED_REFS"  > "$RESOLVED_JSON"

mod_count="$(jq 'length' "$MODULES_JSON")"

# ─── Schema validation (fail fast, before any clone or build) ───────
echo "Validating modules.yaml schema..."

# Allowed-character regexes for fields that go into shell, paths, sed:
NAME_RE='^[a-z0-9-]+$'
SO_RE='^[a-zA-Z0-9_]+\.so$'
VERSION_RE='^[a-zA-Z0-9.+~-]+$'
DEB_DEP_RE='^[a-zA-Z0-9.+-]+$'

required=(name description upstream_url upstream_ref upstream_version
          packaging_revision module_so nginx_context license homepage)

for ((i=0; i<mod_count; i++)); do
    name="$(jq -r ".[$i].name // \"<index $i>\"" "$MODULES_JSON")"

    # Required fields present?
    for field in "${required[@]}"; do
        val="$(jq -r ".[$i].$field // empty" "$MODULES_JSON")"
        [[ -n "$val" ]] || { echo "ERROR: module '$name' missing field: $field" >&2; exit 1; }
    done

    # Field-format checks
    [[ "$name" =~ $NAME_RE ]] || {
        echo "ERROR: invalid module name: '$name' (must match $NAME_RE)" >&2; exit 1
    }
    so="$(jq -r ".[$i].module_so" "$MODULES_JSON")"
    [[ "$so" =~ $SO_RE ]] || {
        echo "ERROR: invalid module_so for '$name': '$so'" >&2; exit 1
    }
    upstream_version="$(jq -r ".[$i].upstream_version" "$MODULES_JSON")"
    [[ "$upstream_version" =~ $VERSION_RE ]] || {
        echo "ERROR: invalid upstream_version for '$name': '$upstream_version'" >&2; exit 1
    }
    ctx="$(jq -r ".[$i].nginx_context" "$MODULES_JSON")"
    [[ "$ctx" == "http" || "$ctx" == "stream" ]] || {
        echo "ERROR: invalid nginx_context for '$name': '$ctx' (must be http or stream)" >&2; exit 1
    }

    # Each declared dep must look like a Debian package name. We validate
    # build_deps and runtime_deps together since the rules are the same.
    # Capturing into a variable first so a jq failure trips set -e (process
    # substitution would have hidden the error).
    all_deps="$(jq -r "((.[$i].build_deps // []) + (.[$i].runtime_deps // [])) | .[]" "$MODULES_JSON")"
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        [[ "$dep" =~ $DEB_DEP_RE ]] || {
            echo "ERROR: invalid dep name for '$name': '$dep'" >&2; exit 1
        }
    done <<< "$all_deps"
done

echo "  $mod_count modules pass validation."
echo

# ─── Per-module build function ──────────────────────────────────────
#
# Returns 0 on success, non-zero on failure.
# Caller wraps in "if ! build_module ...; then" to capture failures
# without aborting the whole run.
#
build_module() {
    local idx="$1"

    # Read every field once, fail fast if anything's missing.
    local name desc url ref upstream_version packaging_revision
    local module_so submodules license homepage
    local replaces load_order

    name="$(jq -r ".[$idx].name" "$MODULES_JSON")"
    desc="$(jq -r ".[$idx].description" "$MODULES_JSON")"
    url="$(jq -r ".[$idx].upstream_url" "$MODULES_JSON")"
    ref="$(jq -r ".[$idx].upstream_ref" "$MODULES_JSON")"
    upstream_version="$(jq -r ".[$idx].upstream_version" "$MODULES_JSON")"
    packaging_revision="$(jq -r ".[$idx].packaging_revision" "$MODULES_JSON")"
    module_so="$(jq -r ".[$idx].module_so" "$MODULES_JSON")"
    submodules="$(jq -r ".[$idx].submodules // false" "$MODULES_JSON")"
    license="$(jq -r ".[$idx].license" "$MODULES_JSON")"
    homepage="$(jq -r ".[$idx].homepage" "$MODULES_JSON")"
    replaces="$(jq -r ".[$idx].replaces // empty" "$MODULES_JSON")"
    load_order="$(jq -r ".[$idx].load_order // 50" "$MODULES_JSON")"

    # Let jq build the comma-separated dep strings for us. Avoids needing
    # bash arrays and works on any bash version.
    local build_deps_csv runtime_deps_csv
    build_deps_csv="$(jq -r ".[$idx].build_deps   // [] | join(\", \")" "$MODULES_JSON")"
    runtime_deps_csv="$(jq -r ".[$idx].runtime_deps // [] | join(\", \")" "$MODULES_JSON")"

    # Look up the resolved commit
    local commit
    commit="$(jq -r ".\"$name\".resolved_commit // empty" "$RESOLVED_JSON")"
    [[ -n "$commit" ]] || {
        echo "  ERROR: no resolved commit for $name. Re-run resolve-refs.sh." >&2
        return 1
    }
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
        echo "  ERROR: invalid commit hash for $name: '$commit'" >&2
        return 1
    }

    local version="${upstream_version}-${packaging_revision}+nginx${NGINX_VERSION}+blendbyte${BUILD_SERIAL}~${CODENAME}"
    local snippet_name="${load_order}-mod-${name#nginx-module-}.conf"

    cat <<EOF

============================================================
Building $name
============================================================
  Version: $version
  Commit:  $commit
  .so:     $module_so
EOF

    # Fresh working directory
    local pkg_dir="$WORK_DIR/$name"
    rm -rf "$pkg_dir"
    mkdir -p "$pkg_dir"
    local upstream_dir="$pkg_dir/upstream"

    # Clone the upstream module source at the pinned commit.
    # (Clone first, then checkout, then submodule update - this way
    # submodules end up at versions referenced by the target commit,
    # not by master.)
    git clone --quiet "$url" "$upstream_dir"
    git -C "$upstream_dir" checkout --quiet "$commit"
    if [[ "$submodules" == "true" ]]; then
        git -C "$upstream_dir" submodule update --init --recursive --quiet
    fi

    # ─── Apply patches to upstream files ────────────────────────────
    # Some upstream modules hardcode things that don't work in our
    # build context (most commonly: static library names that aren't
    # built with -fPIC on the target arch). modules.yaml can specify
    # a list of {file, sed} objects to patch upstream files before
    # build. The "file" path is relative to upstream_dir.
    local patches_count
    patches_count="$(jq -r ".[$idx].patches // [] | length" "$MODULES_JSON")"
    if [[ "$patches_count" -gt 0 ]]; then
        local p patch_file patch_sed full_path
        for ((p=0; p<patches_count; p++)); do
            patch_file="$(jq -r ".[$idx].patches[$p].file // empty" "$MODULES_JSON")"
            patch_sed="$(jq -r ".[$idx].patches[$p].sed // empty" "$MODULES_JSON")"
            if [[ -z "$patch_file" || -z "$patch_sed" ]]; then
                echo "  ERROR: $name patch #$p missing 'file' or 'sed'" >&2
                return 1
            fi
            full_path="$upstream_dir/$patch_file"
            if [[ ! -f "$full_path" ]]; then
                echo "  ERROR: $name patch #$p targets missing file: $patch_file" >&2
                return 1
            fi
            echo "  Patch: $patch_file <- $patch_sed"
            sed -i "$patch_sed" "$full_path"
        done
    fi

    # ─── Generate debian/ tree ──────────────────────────────────────
    local debian="$pkg_dir/debian"
    mkdir -p "$debian/source"

    # Build dependency strings (comma-separated)
    local depends="nginx (= $NGINX_FULL_VERSION)"
    [[ -n "$runtime_deps_csv" ]] && depends+=", $runtime_deps_csv"

    local build_deps_str="dpkg-dev"
    [[ -n "$build_deps_csv" ]] && build_deps_str+=", $build_deps_csv"

    # Optional Replaces/Conflicts/Provides block (sury migration)
    local replaces_block=""
    if [[ -n "$replaces" ]]; then
        replaces_block="Provides: $replaces"$'\n'
        replaces_block+="Replaces: $replaces"$'\n'
        replaces_block+="Conflicts: $replaces"$'\n'
    fi

    # debian/control
    # Note: \${shlibs:Depends} and \${misc:Depends} are LITERAL in the
    # output - debhelper substitutes them at build time.
    # Note 2: we don't list nginx-source in Build-Depends because the
    # nginx.org repo doesn't ship one. The Dockerfile pre-fetches the
    # source tree to /usr/src/nginx-X.Y.Z/ via 'apt-get source nginx',
    # and the rules file uses it from there.
    cat > "$debian/control" <<EOF
Source: $name
Section: httpd
Priority: optional
Maintainer: Blendbyte <apt@blendbyte.com>
Build-Depends: debhelper-compat (= 13), $build_deps_str
Standards-Version: 4.6.0
Homepage: $homepage

Package: $name
Architecture: any
Depends: $depends, \${shlibs:Depends}, \${misc:Depends}
${replaces_block}Description: $desc
 This package provides the $module_so dynamic module for nginx,
 built against the official nginx.org stable release.
 .
 Built and maintained by Blendbyte. See
 https://github.com/blendbyte/nginx-modules for the source.
EOF

    # debian/changelog
    local now; now="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    cat > "$debian/changelog" <<EOF
$name ($version) $CODENAME; urgency=medium

  * Built from $url
    ref: $ref  ->  commit $commit
  * For nginx $NGINX_VERSION on Debian $CODENAME $ARCH

 -- Blendbyte <apt@blendbyte.com>  $now
EOF

    # Note: we don't write debian/compat. Modern debhelper (12+) wants the
    # compat level declared via "Build-Depends: debhelper-compat (= 13)"
    # only — having both files is a hard error.

    # debian/copyright
    cat > "$debian/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: $name
Source: $homepage

Files: *
Copyright: Upstream contributors
License: $license
 See upstream source for full license text.

Files: debian/*
Copyright: 2026 Blendbyte
License: BSD-2-Clause
EOF

    # debian/source/format
    echo "3.0 (native)" > "$debian/source/format"

    # debian/rules
    # We use a quoted heredoc here ('RULES') so Make's $(VAR) syntax is
    # safe from bash interpretation. Per-module values are then patched
    # in via sed. The placeholder names use double underscores so they
    # can't collide with anything Make produces.
    cat > "$debian/rules" <<'RULES'
#!/usr/bin/make -f
export DH_VERBOSE = 1
export NGINX_VERSION = __NGINX_VERSION__

MODULE_SRC := $(CURDIR)/upstream
NGINX_SRC  := $(CURDIR)/nginx-src
MODULE_SO  := __MODULE_SO__
PKG_NAME   := __PKG_NAME__

%:
	dh $@

override_dh_auto_configure:
	# Copy nginx source into our build dir. The Docker image unpacked it
	# at /usr/src/nginx-$(NGINX_VERSION) as root, but the build runs as
	# an unprivileged user, and configure needs to write objs/ alongside
	# the source. Copy gives us a writable tree per module build, plus
	# isolation between modules.
	rm -rf $(NGINX_SRC)
	cp -a /usr/src/nginx-$(NGINX_VERSION) $(NGINX_SRC)
	cd $(NGINX_SRC) && ./configure --with-compat --with-stream --with-mail --add-dynamic-module=$(MODULE_SRC)

override_dh_auto_build:
	cd $(NGINX_SRC) && make modules

override_dh_auto_install:
	install -d $(CURDIR)/debian/$(PKG_NAME)/usr/lib/nginx/modules
	install -m 0644 $(NGINX_SRC)/objs/$(MODULE_SO) \
	    $(CURDIR)/debian/$(PKG_NAME)/usr/lib/nginx/modules/
	install -d $(CURDIR)/debian/$(PKG_NAME)/etc/nginx/modules-available
	install -d $(CURDIR)/debian/$(PKG_NAME)/etc/nginx/modules-enabled
	echo 'load_module modules/$(MODULE_SO);' \
	    > $(CURDIR)/debian/$(PKG_NAME)/etc/nginx/modules-available/__SNIPPET_NAME__

override_dh_auto_clean:
	rm -rf $(CURDIR)/debian/$(PKG_NAME)
	rm -rf $(NGINX_SRC)
RULES

    sed -i \
        -e "s|__NGINX_VERSION__|$NGINX_VERSION|g" \
        -e "s|__MODULE_SO__|$module_so|g" \
        -e "s|__PKG_NAME__|$name|g" \
        -e "s|__SNIPPET_NAME__|$snippet_name|g" \
        "$debian/rules"
    chmod 0755 "$debian/rules"

    # debian/postinst
    cat > "$debian/postinst" <<EOF
#!/bin/sh
set -e

if [ "\$1" = "configure" ]; then
    if [ ! -L /etc/nginx/modules-enabled/$snippet_name ]; then
        ln -sf /etc/nginx/modules-available/$snippet_name \\
            /etc/nginx/modules-enabled/$snippet_name
    fi
    if systemctl is-active --quiet nginx; then
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    fi
fi

#DEBHELPER#
EOF
    chmod 0755 "$debian/postinst"

    # debian/prerm
    cat > "$debian/prerm" <<EOF
#!/bin/sh
set -e

if [ "\$1" = "remove" ] || [ "\$1" = "purge" ]; then
    rm -f /etc/nginx/modules-enabled/$snippet_name
fi

#DEBHELPER#
EOF
    chmod 0755 "$debian/prerm"

    # ─── Build the .deb ─────────────────────────────────────────────
    if ! ( cd "$pkg_dir" && dpkg-buildpackage -us -uc -b "-a$ARCH" ); then
        echo "  Build failed for $name" >&2
        return 1
    fi

    # Move artifacts. dpkg-buildpackage drops .debs one level above
    # the build dir, alongside the .changes file. Check mv explicitly
    # because we're called from inside an `if !` chain which suppresses
    # set -e — a silent mv failure would falsely report success.
    local moved=0
    for deb in "$WORK_DIR/${name}"_*.deb; do
        [[ -f "$deb" ]] || continue
        if mv "$deb" "$ARTIFACTS_DIR/"; then
            echo "  Built: $(basename "$deb")"
            moved=$((moved + 1))
        else
            echo "  ERROR: failed to move $(basename "$deb") to $ARTIFACTS_DIR" >&2
            echo "         (likely a permission issue between container and host)" >&2
            return 1
        fi
    done

    if [[ "$moved" -eq 0 ]]; then
        echo "  ERROR: no .deb produced for $name" >&2
        return 1
    fi
    return 0
}

# ─── Main loop ──────────────────────────────────────────────────────
declare -a failures=()
declare -a built=()

for ((i=0; i<mod_count; i++)); do
    name="$(jq -r ".[$i].name" "$MODULES_JSON")"

    if [[ -n "$ONLY_MODULE" && "$name" != "$ONLY_MODULE" ]]; then
        continue
    fi

    if build_module "$i"; then
        built+=("$name")
    else
        failures+=("$name")
    fi
done

# ─── Summary ────────────────────────────────────────────────────────
echo
echo "============================================================"
if [[ ${#failures[@]} -eq 0 ]]; then
    echo "Build complete. ${#built[@]} package(s) in $ARTIFACTS_DIR:"
    ls -la "$ARTIFACTS_DIR"/*.deb 2>/dev/null || echo "  (none)"
    echo "============================================================"
    exit 0
else
    echo "Build had ${#failures[@]} failure(s):"
    printf '  - %s\n' "${failures[@]}"
    if [[ ${#built[@]} -gt 0 ]]; then
        echo
        echo "Successful builds (${#built[@]}):"
        printf '  - %s\n' "${built[@]}"
    fi
    echo "============================================================"
    exit 1
fi
