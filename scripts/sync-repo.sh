#!/usr/bin/env bash
# Transfer only the repository state and files needed for incremental releases.
# Usage: bash scripts/sync-repo.sh pull|push <local-repo> <s3-prefix> [--dry-run]
set -euo pipefail

mode="${1:?pull or push required}"
repo="${2:?local repository required}"
remote="${3:?S3 prefix required}"
remote="${remote%/}"
options=()
if [[ "${4:-}" == "--dry-run" ]]; then
    options+=(--dryrun)
elif [[ -n "${4:-}" ]]; then
    echo "Unknown option: $4" >&2
    exit 1
fi

case "$mode" in
    pull)
        # Dry runs must restore real state too. They only skip uploads.
        aws s3 sync "$remote/db/" "$repo/db/"
        aws s3 sync "$remote/dists/" "$repo/dists/"
        ;;
    push)
        # Never delete remote pool files. Upload new payloads before indexes
        # can reference them, and publish signed Release files last.
        aws s3 sync "$repo/pool/" "$remote/pool/" "${options[@]}"
        aws s3 sync "$repo/db/" "$remote/db/" "${options[@]}"
        aws s3 sync "$repo/dists/" "$remote/dists/" \
            --exclude '*/Release' --exclude '*/Release.gpg' --exclude '*/InRelease' "${options[@]}"
        aws s3 sync "$repo/dists/" "$remote/dists/" --exclude '*' \
            --include '*/Release' --include '*/Release.gpg' --include '*/InRelease' "${options[@]}"
        aws s3 sync "$repo/" "$remote/" --exclude '*' \
            --include 'blendbyte-archive-keyring.gpg' \
            --include 'blendbyte-archive-keyring.gpg.asc' --include 'status.txt' "${options[@]}"
        ;;
    *) echo "Unknown mode: $mode" >&2; exit 1 ;;
esac
