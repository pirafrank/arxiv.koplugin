#!/bin/sh
# Syntax, lint and unit tests; optionally the KOReader-runtime integration spec.
#
#   scripts/check.sh                  syntax + luacheck + shellcheck + unit tests
#   scripts/check.sh --integration    also run spec/integration_spec.lua
#
# Integration needs KOREADER_DIR (an extracted KOReader Linux release, the dir
# containing ./luajit and reader.lua). Optional: ARXIV_REAL_NETWORK=1.
set -eu
unset CDPATH

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
LUAJIT=${LUAJIT:-luajit}

echo "== syntax (LuaJIT)"
for f in arxiv.koplugin/*.lua spec/*.lua; do
    "$LUAJIT" -bl "$f" >/dev/null
done

echo "== luacheck"
luacheck -q arxiv.koplugin spec

echo "== shellcheck"
shellcheck scripts/*.sh

echo "== unit tests"
"$LUAJIT" spec/runner.lua spec/arxiv_spec.lua spec/download_spec.lua

if [ "${1:-}" = "--integration" ]; then
    : "${KOREADER_DIR:?set KOREADER_DIR to an extracted KOReader Linux release}"
    echo "== integration (KOReader runtime: $(cat "$KOREADER_DIR/git-rev" 2>/dev/null || echo unknown))"
    ko_home=$(mktemp -d)
    trap 'rm -rf "$ko_home"' EXIT
    mkdir -p "$ko_home/plugins"
    cp -R arxiv.koplugin "$ko_home/plugins/"
    log="$ko_home/integration.log"
    if ! (cd "$KOREADER_DIR" && KO_HOME="$ko_home" SDL_VIDEODRIVER=dummy \
        ./luajit "$repo/spec/runner.lua" "$repo/spec/integration_spec.lua") >"$log" 2>&1; then
        grep -v '^ffi\.\|^lib_' "$log" | tail -40
        grep -A1 '^FAIL' "$log"
        echo "integration FAILED"
        exit 1
    fi
    grep -E '^(FAIL|[0-9]+ passed)' "$log"
    if grep -n 'arxiv' "$log" | grep -iE 'error|traceback|WARN' | grep -v 'arXiv: download failed'; then
        echo "unexpected arxiv warnings in KOReader log"
        exit 1
    fi
fi
echo "OK"
