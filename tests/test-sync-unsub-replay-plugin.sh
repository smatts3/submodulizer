#!/usr/bin/env bash
# Vendored plugin tree not present in plugin history → commits on unsubmodulized_sync + gitlink update.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cleandev

TMP=$(mktemp -d)
export HOME="$TMP/_home"
mkdir -p "$HOME"
git config --global protocol.file.allow always
trap 'rm -rf "$TMP"' EXIT

PLUGIN="$TMP/plugin"
MOODLE="$TMP/moodle"
mkdir -p "$PLUGIN" "$MOODLE"

git -C "$PLUGIN" init -b main
echo "only-upstream" > "$PLUGIN/f.txt"
git -C "$PLUGIN" add f.txt
git -C "$PLUGIN" commit -q -m "sole plugin commit"
UP="$(git -C "$PLUGIN" rev-parse HEAD)"

git -C "$MOODLE" init -b main
printf 'core\n' > "$MOODLE/README.md"
mkdir -p "$MOODLE/mod/foo"
git -C "$PLUGIN" archive "$UP" | tar -x -C "$MOODLE/mod/foo"
git -C "$MOODLE" add README.md mod/foo
git -C "$MOODLE" commit -q -m "vendored base"
M0="$(git -C "$MOODLE" rev-parse HEAD)"

git -C "$MOODLE" checkout -q -b submodulized
printf 'mod/foo|%s|main\n' "$PLUGIN" > "$MOODLE/plugin-submodules.manifest"
git -C "$MOODLE" config -f .gitmodules submodule.mod/foo.path mod/foo
git -C "$MOODLE" config -f .gitmodules submodule.mod/foo.url "$PLUGIN"
git -C "$MOODLE" add .gitmodules plugin-submodules.manifest
git -C "$MOODLE" rm -rf --cached mod/foo
git -C "$MOODLE" update-index --add --cacheinfo "160000,$UP,mod/foo"
git -C "$MOODLE" commit -q -m "sub at upstream tip"
git -C "$MOODLE" reset --hard -q HEAD
rm -rf "$MOODLE/mod/foo"

git -C "$MOODLE" branch -q unsubmodulized "$M0"
git -C "$MOODLE" checkout -q unsubmodulized
echo "extra-from-unsub" > "$MOODLE/mod/foo/EXTRA.txt"
git -C "$MOODLE" add mod/foo/EXTRA.txt
git -C "$MOODLE" commit -q -m "vendor-only change (no plugin commit yet)"

"$CLEANDEV/submodulize.sh" --repo "$MOODLE"

git -C "$PLUGIN" show-ref --verify --quiet refs/heads/unsubmodulized_sync || fail "expected plugin branch unsubmodulized_sync"

link="$(git -C "$MOODLE" ls-tree submodulized mod/foo | awk '{print $3}')"
[[ "$link" == "$(git -C "$PLUGIN" rev-parse unsubmodulized_sync)" ]] || fail "gitlink should match plugin unsubmodulized_sync tip"
git -C "$PLUGIN" ls-tree -r "$link" --name-only | grep -Fxq EXTRA.txt || fail "EXTRA.txt missing in plugin commit at gitlink"

ok "sync replays vendored-only change to plugin unsubmodulized_sync (fixture)"
