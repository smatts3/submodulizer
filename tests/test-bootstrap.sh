#!/usr/bin/env bash
# Bootstrap: submodulize.sh with no submodulized branch → one-shot + unsub replay (file:// plugin, no network).
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

PLUGIN="$TMP/plugin-upstream"
MOODLE="$TMP/moodle"
mkdir -p "$PLUGIN"
git -C "$PLUGIN" init -b main
git -C "$PLUGIN" config core.autocrlf false
echo "plug=1" > "$PLUGIN/version.txt"
git -C "$PLUGIN" add version.txt
git -C "$PLUGIN" commit -q -m "init plugin"

mkdir -p "$MOODLE/mod/testplugin"
git -C "$MOODLE" init -b master
git -C "$MOODLE" config core.autocrlf false
# Unpack from plugin so tree/blob IDs match plugin commits (avoids CRLF tree mismatch on Windows).
git -C "$PLUGIN" archive HEAD | tar -x -C "$MOODLE/mod/testplugin"
git -C "$MOODLE" add mod/testplugin
git -C "$MOODLE" commit -q -m "vendored plugin"

printf '%s\n' 'mod/testplugin|../plugin-upstream|main' > "$MOODLE/plugin-submodules.manifest"

# No local submodulized branch → auto-bootstrap (same as explicit --bootstrap)
"$CLEANDEV/submodulize.sh" --repo "$MOODLE" --no-commit

git -C "$MOODLE" show-ref --verify --quiet refs/heads/submodulized || fail "expected submodulized branch"
git -C "$MOODLE" show-ref --verify --quiet refs/heads/unsubmodulized || fail "expected unsubmodulized branch"
git -C "$MOODLE" ls-tree submodulized mod/testplugin | grep -q '^160000' || fail "expected gitlink (submodule) at mod/testplugin on submodulized"
git -C "$MOODLE" ls-tree -r submodulized --name-only | grep -q '^plugin-submodules.manifest$' || fail "expected tracked plugin-submodules.manifest on submodulized"
git -C "$MOODLE" ls-tree -r unsubmodulized --name-only | grep -q '^mod/testplugin/version.txt$' || fail "expected vendored file on unsubmodulized"
if git -C "$MOODLE" ls-tree -r unsubmodulized --name-only | grep -q '^plugin-submodules.manifest$'; then
  fail "did not expect plugin-submodules.manifest on unsubmodulized"
fi

ok "submodulize bootstrap (auto when submodulized missing)"
