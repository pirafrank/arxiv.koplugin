#!/bin/sh
# Copy arxiv.koplugin onto a USB-mounted Kindle (or any KOReader install).
# Only copies plugin files; never touches system partitions, other plugins,
# KOReader settings, or the jailbreak. Does not unmount the device.
#
#   scripts/install-to-kindle.sh [--yes] <kindle-usb-root> [plugin-zip]
#   scripts/install-to-kindle.sh --rollback <kindle-usb-root> <backup-dir>
#
# Quit KOReader completely before connecting USB mass storage.
set -eu
unset CDPATH

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
FILES="_meta.lua arxiv.lua download.lua main.lua"

die() { echo "error: $*" >&2; exit 1; }

check_root() {
    root=$1
    [ -n "$root" ] || die "empty target"
    root=$(CDPATH='' cd -- "$root" 2>/dev/null && pwd) || die "target does not exist: $1"
    [ "$root" != "/" ] || die "refusing to use / as target"
    [ -d "$root/koreader" ] || die "$root/koreader not found: not a KOReader device root"
    [ -d "$root/koreader/plugins" ] || die "$root/koreader/plugins not found: is KOReader installed?"
    [ -f "$root/koreader/reader.lua" ] || die "$root/koreader/reader.lua not found: implausible KOReader install"
    if command -v findmnt >/dev/null 2>&1 && ! findmnt -T "$root" >/dev/null 2>&1; then
        die "$root is not on a mounted filesystem"
    fi
    echo "$root"
}

confirm() {
    [ "$assume_yes" = 1 ] && return 0
    printf '%s [y/N] ' "$1"
    read -r answer
    [ "$answer" = y ] || [ "$answer" = Y ] || die "aborted"
}

assume_yes=0
if [ "${1:-}" = "--rollback" ]; then
    root=$(check_root "${2:-}")
    backup=${3:-}
    if [ -z "$backup" ] || [ ! -f "$backup/_meta.lua" ]; then die "backup dir with _meta.lua required"; fi
    target="$root/koreader/plugins/arxiv.koplugin"
    echo "Rollback: remove $target and restore $backup"
    confirm "Proceed (KOReader must be closed)?"
    rm -rf "$target"
    cp -R "$backup" "$target"
    echo "Restored. Eject the device safely before unplugging."
    exit 0
fi
if [ "${1:-}" = "--yes" ]; then
    assume_yes=1
    shift
fi

root=$(check_root "${1:-}")
zip=${2:-}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
if [ -n "$zip" ]; then
    [ -f "$zip" ] || die "zip not found: $zip"
    unzip -q "$zip" -d "$stage"
else
    mkdir -p "$stage/arxiv.koplugin"
    for f in $FILES; do cp "$repo/arxiv.koplugin/$f" "$stage/arxiv.koplugin/"; done
fi
for f in $FILES; do
    [ -f "$stage/arxiv.koplugin/$f" ] || die "source is missing arxiv.koplugin/$f (wrong zip layout?)"
done

target="$root/koreader/plugins/arxiv.koplugin"
echo "Source:      ${zip:-$repo/arxiv.koplugin}"
echo "Destination: $target"
backup=""
if [ -e "$target" ]; then
    backup="$root/koreader/plugins-backup-arxiv.koplugin-$(date +%Y%m%d%H%M%S)"
    [ ! -e "$backup" ] || die "backup path already exists: $backup"
    echo "Existing plugin will be backed up to: $backup"
fi
confirm "Install (KOReader must be closed)?"

if [ -n "$backup" ]; then
    # Backups live outside plugins/ so KOReader does not load two copies.
    mv "$target" "$backup"
fi
mkdir "$target"
for f in $FILES; do
    cp "$stage/arxiv.koplugin/$f" "$target/$f"
    cmp -s "$stage/arxiv.koplugin/$f" "$target/$f" || die "verification failed for $f"
done
sync
echo "Installed and verified $target"
[ -z "$backup" ] || echo "Rollback: $0 --rollback '$root' '$backup'"
echo "Now eject the device safely (this script does not unmount it), then start KOReader."
