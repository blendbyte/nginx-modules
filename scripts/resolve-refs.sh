#!/usr/bin/env bash
#
# resolve-refs.sh
#
# Reads modules.yaml. For each module, resolves its upstream_ref (a tag
# name, branch name, or already-a-commit) into a specific 40-char commit
# hash via "git ls-remote". Writes the result to .resolved-refs.yaml.
#
# Why we do this:
#   * Builds become reproducible. We pin to a hash, not a branch tip.
#   * Tag-rewriting attacks on upstream repos are caught (if the same
#     "v0.39" tag points at a different commit between runs, we notice).
#   * The Debian changelog can record the exact commit that was built.
#
# Run BEFORE scripts/build.sh.
#
# Output: .resolved-refs.yaml at repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES_YAML="$REPO_ROOT/modules.yaml"
OUTPUT="$REPO_ROOT/.resolved-refs.yaml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

# 'timeout' is GNU coreutils, not on stock macOS. We use it as a guard
# against a hung git ls-remote, but it's not essential. Without it we
# just rely on git's own network timeouts. Detect once, use everywhere.
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(timeout 60)
else
    TIMEOUT_CMD=()
fi

[[ -f "$MODULES_YAML" ]] || {
    echo "ERROR: $MODULES_YAML not found" >&2
    exit 1
}

# ─── Convert YAML to JSON for iteration ─────────────────────────────
yq -o json '.modules' "$MODULES_YAML" > "$TMP/modules.json"
mod_count="$(jq 'length' "$TMP/modules.json")"

if [[ "$mod_count" -eq 0 ]]; then
    echo "ERROR: no modules found in $MODULES_YAML" >&2
    exit 1
fi

# ─── Schema validation (catches typos before any network calls) ─────
echo "Validating modules.yaml..."
for ((i=0; i<mod_count; i++)); do
    name="$(jq -r ".[$i].name // \"<index $i>\"" "$TMP/modules.json")"
    for field in name upstream_url upstream_ref; do
        val="$(jq -r ".[$i].$field // empty" "$TMP/modules.json")"
        if [[ -z "$val" ]]; then
            echo "ERROR: module '$name' missing required field: $field" >&2
            exit 1
        fi
    done
done
echo "  $mod_count modules pass validation."
echo

# ─── Resolve refs ───────────────────────────────────────────────────
# Note: we don't cache shared upstreams (e.g. brotli filter + static both
# pull from nginx-modules/ngx_brotli). Two extra git ls-remote calls is
# ~2 seconds, not worth a bash 4 dependency for the cache.
resolve_one() {
    local url="$1" ref="$2"

    # Already a 40-char hex commit hash? Pass through.
    if [[ ${#ref} -eq 40 && "$ref" =~ ^[0-9a-f]+$ ]]; then
        echo "$ref"
        return 0
    fi

    # Pick the ref namespace
    local pattern
    if [[ "$ref" == "master" || "$ref" == "main" ]]; then
        pattern="refs/heads/$ref"
    else
        pattern="refs/tags/$ref"
    fi

    # ls-remote with both the ref and its dereferenced (^{}) variant.
    # Annotated tags point at a tag object; ^{} dereferences to the
    # actual commit. We prefer the dereferenced commit.
    local output
    if ! output="$("${TIMEOUT_CMD[@]}" git ls-remote "$url" "$pattern" "${pattern}^{}" 2>&1)"; then
        echo "ERROR: git ls-remote failed for $url@$ref" >&2
        echo "$output" >&2
        return 1
    fi

    if [[ -z "$output" ]]; then
        echo "ERROR: no matching ref for $url@$ref" >&2
        echo "  Tried: $pattern, ${pattern}^{}" >&2
        return 1
    fi

    # Pick dereferenced (^{}) over the tag object if both exist
    local commit
    commit="$(awk '
        /\^\{\}$/ { deref = $1 }
        !/\^\{\}$/ { if (!plain) plain = $1 }
        END { print (deref ? deref : plain) }
    ' <<< "$output")"

    if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
        echo "ERROR: ls-remote returned non-hash for $url@$ref: '$commit'" >&2
        return 1
    fi

    echo "$commit"
}

# ─── Build the output YAML ──────────────────────────────────────────
{
    printf '_metadata:\n'
    printf '  resolved_at: "%s"\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '  source: modules.yaml\n'
    printf 'modules:\n'

    for ((i=0; i<mod_count; i++)); do
        name="$(jq -r ".[$i].name" "$TMP/modules.json")"
        url="$(jq -r ".[$i].upstream_url" "$TMP/modules.json")"
        ref="$(jq -r ".[$i].upstream_ref" "$TMP/modules.json")"

        echo "  Resolving $name: $url @ $ref" >&2

        commit="$(resolve_one "$url" "$ref")"
        echo "    -> $commit" >&2

        printf '  %s:\n' "$name"
        printf '    upstream_url: %s\n' "$url"
        printf '    upstream_ref: "%s"\n' "$ref"
        printf '    resolved_commit: %s\n' "$commit"
    done
} > "$OUTPUT"

echo
echo "Wrote $OUTPUT"
echo "Commit this file if you want builds to pin to specific commits."