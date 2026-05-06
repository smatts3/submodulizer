#!/usr/bin/env bash
# Replay mode (default): unsubmodulize + submodulize on temp repos (file:// plugin, no network).
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
echo "v1" > "$PLUGIN/f.txt"
git -C "$PLUGIN" add f.txt
git -C "$PLUGIN" commit -q -m "p1"
echo "v2" >> "$PLUGIN/f.txt"
git -C "$PLUGIN" commit -q -am "p2"

C0="$(git -C "$PLUGIN" rev-parse HEAD~1)"
C1="$(git -C "$PLUGIN" rev-parse HEAD)"

git -C "$MOODLE" init -b main
printf 'core\n' > "$MOODLE/README.md"
mkdir -p "$MOODLE/mod/foo"
git -C "$PLUGIN" archive "$C0" | tar -x -C "$MOODLE/mod/foo"
git -C "$MOODLE" add README.md mod/foo
git -C "$MOODLE" commit -q -m "vendored base"

BASE="$(git -C "$MOODLE" rev-parse HEAD)"

git -C "$MOODLE" config -f .gitmodules submodule.mod/foo.path mod/foo
git -C "$MOODLE" config -f .gitmodules submodule.mod/foo.url "$PLUGIN"
git -C "$MOODLE" add .gitmodules
git -C "$MOODLE" rm -rf --cached mod/foo
git -C "$MOODLE" update-index --add --cacheinfo "160000,$C0,mod/foo"
git -C "$MOODLE" commit -q -m "sub at c0"

git -C "$MOODLE" checkout -q -b submodulized
git -C "$MOODLE" update-index --add --cacheinfo "160000,$C1,mod/foo"
git -C "$MOODLE" commit -q -m "sub at c1"

MANIFEST="$MOODLE/plugin-submodules.manifest"
printf 'mod/foo|%s|main\n' "$PLUGIN" > "$MANIFEST"

# --- unsub replay: one commit (c1) in plugin range c0..c1 (explicit plugin base avoids CRLF tree mismatch) ---
"$CLEANDEV/unsubmodulize.sh" --repo "$MOODLE" --fork-point "$BASE" --source submodulized \
  --target unsubmodulized --force --plugin-base "mod/foo=$C0"

N="$(git -C "$MOODLE" rev-list --count "${BASE}..unsubmodulized" 2>/dev/null || echo 0)"
[[ "$N" -eq 1 ]] || fail "expected 1 commit on unsubmodulized past BASE, got $N"
git -C "$MOODLE" ls-tree -r unsubmodulized --name-only | grep -q '^mod/foo/f.txt$' || fail "expected vendored file path"
git -C "$MOODLE" show unsubmodulized:mod/foo/f.txt | grep -q v2 || fail "expected v2 in tree"

# --- sub replay from vendored BASE: match tree at BASE to plugin c0 ---
git -C "$MOODLE" checkout -q main
"$CLEANDEV/submodulize.sh" --repo "$MOODLE" --fork-point "$BASE" --source submodulized \
  --target sub2 --force --plugin-base "mod/foo=$C0"

N2="$(git -C "$MOODLE" rev-list --count "${BASE}..sub2" 2>/dev/null || echo 0)"
[[ "$N2" -eq 1 ]] || fail "expected 1 commit on sub2 past BASE, got $N2"
git -C "$MOODLE" ls-tree sub2 mod/foo | grep -q 160000 || fail "expected gitlink at mod/foo"

ok "unsubmodulize + submodulize replay (fixture)"
