#!/bin/sh
# Build (and verify) the release zip: dist/arxiv.koplugin-v<version>.zip
#
#   scripts/package.sh            build + verify
#   scripts/package.sh --verify   verify an existing zip only
#
# The archive contains exactly arxiv.koplugin/{_meta,main,arxiv,download}.lua,
# so extracting it into koreader/plugins/ yields the correct layout.
set -eu
unset CDPATH

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"

FILES="_meta.lua arxiv.lua download.lua main.lua"
version=$(sed -n 's/^ *version = "\([0-9][0-9.]*\)",$/\1/p' arxiv.koplugin/_meta.lua)
[ -n "$version" ] || { echo "cannot read version from _meta.lua" >&2; exit 1; }
zip_path="dist/arxiv.koplugin-v$version.zip"

if [ "${1:-}" != "--verify" ]; then
    rm -rf dist/stage
    mkdir -p dist/stage/arxiv.koplugin
    for f in $FILES; do
        cp "arxiv.koplugin/$f" "dist/stage/arxiv.koplugin/$f"
    done
    # Reproducible archive: fixed timestamps and permissions, sorted entries, no extra attributes.
    epoch=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || echo 315532800)}
    find dist/stage -exec touch -h -d "@$epoch" {} +
    chmod 0755 dist/stage/arxiv.koplugin
    chmod 0644 dist/stage/arxiv.koplugin/*
    rm -f "$zip_path"
    (cd dist/stage && zip -X -q -D "../$(basename "$zip_path")" arxiv.koplugin/_meta.lua arxiv.koplugin/arxiv.lua \
        arxiv.koplugin/download.lua arxiv.koplugin/main.lua)
    rm -rf dist/stage
fi

[ -f "$zip_path" ] || { echo "missing $zip_path" >&2; exit 1; }
expected=$(for f in $FILES; do echo "arxiv.koplugin/$f"; done | sort)
actual=$(zipinfo -1 "$zip_path" | sort)
if [ "$expected" != "$actual" ]; then
    echo "unexpected archive layout:" >&2
    echo "$actual" >&2
    exit 1
fi
for f in $FILES; do
    if ! unzip -p "$zip_path" "arxiv.koplugin/$f" | cmp -s - "arxiv.koplugin/$f"; then
        echo "archive content differs from source: $f" >&2
        exit 1
    fi
done
(cd dist && sha256sum "$(basename "$zip_path")" > "$(basename "$zip_path").sha256")
echo "verified $zip_path"
cat "$zip_path.sha256"
