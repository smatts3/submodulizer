#!/usr/bin/env bash
# Auto sync: when unsubmodulized is ahead of merge-base with submodulized, submodulize replays onto gitlinks.
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

M0="$(git -C "$MOODLE" rev-parse HEAD)"

git -C "$MOODLE" checkout -q -b submodulized
printf 'mod/foo|%s|main\n' "$PLUGIN" > "$MOODLE/plugin-submodules.manifest"
git -C "$MOODLE" config -f .gitmodules submodule.mod/foo.path mod/foo
git -C "$MOODLE" config -f .gitmodules submodule.mod/foo.url "$PLUGIN"
git -C "$MOODLE" add .gitmodules plugin-submodules.manifest
git -C "$MOODLE" rm -rf --cached mod/foo
git -C "$MOODLE" update-index --add --cacheinfo "160000,$C0,mod/foo"
git -C "$MOODLE" commit -q -m "sub at c0"
# Manual gitlink commit can leave vendored files on disk (untracked); remove before branch hops.
git -C "$MOODLE" reset --hard -q HEAD
rm -rf "$MOODLE/mod/foo"

git -C "$MOODLE" branch -q unsubmodulized "$M0"

git -C "$MOODLE" checkout -q unsubmodulized
find "$MOODLE/mod/foo" -mindepth 1 -delete
git -C "$PLUGIN" archive "$C1" | tar -x -C "$MOODLE/mod/foo"
git -C "$MOODLE" add mod/foo
git -C "$MOODLE" commit -q -m "vendor bump to c1"

# Stay on unsubmodulized; default one-shot path checks out submodulized and syncs when unsub is ahead.
"$CLEANDEV/submodulize.sh" --repo "$MOODLE"

link="$(git -C "$MOODLE" ls-tree submodulized mod/foo | awk '{print $3}')"
[[ "$link" == "$C1" ]] || fail "expected gitlink $C1 on submodulized, got ${link:-empty}"

git -C "$MOODLE" log -1 --format=%B submodulized | grep -q '^Synced-from-unsub:' || fail "expected Synced-from-unsub footer"

ok "submodulize auto sync from unsubmodulized (fixture)"

# --- opt-out: same vendor bump but --no-sync-from-unsub leaves gitlink at C0 ---
TMP2=$(mktemp -d)
export HOME="$TMP2/_home"
mkdir -p "$HOME"
git config --global protocol.file.allow always
trap 'rm -rf "$TMP" "$TMP2"' EXIT

PLUGIN2="$TMP2/plugin"
MOODLE2="$TMP2/moodle"
mkdir -p "$PLUGIN2" "$MOODLE2"

git -C "$PLUGIN2" init -b main
echo "v1" > "$PLUGIN2/f.txt"
git -C "$PLUGIN2" add f.txt
git -C "$PLUGIN2" commit -q -m "p1"
echo "v2" >> "$PLUGIN2/f.txt"
git -C "$PLUGIN2" commit -q -am "p2"
C0b="$(git -C "$PLUGIN2" rev-parse HEAD~1)"
C1b="$(git -C "$PLUGIN2" rev-parse HEAD)"

git -C "$MOODLE2" init -b main
printf 'core\n' > "$MOODLE2/README.md"
mkdir -p "$MOODLE2/mod/foo"
git -C "$PLUGIN2" archive "$C0b" | tar -x -C "$MOODLE2/mod/foo"
git -C "$MOODLE2" add README.md mod/foo
git -C "$MOODLE2" commit -q -m "vendored base"
M0b="$(git -C "$MOODLE2" rev-parse HEAD)"

git -C "$MOODLE2" checkout -q -b submodulized
printf 'mod/foo|%s|main\n' "$PLUGIN2" > "$MOODLE2/plugin-submodules.manifest"
git -C "$MOODLE2" config -f .gitmodules submodule.mod/foo.path mod/foo
git -C "$MOODLE2" config -f .gitmodules submodule.mod/foo.url "$PLUGIN2"
git -C "$MOODLE2" add .gitmodules plugin-submodules.manifest
git -C "$MOODLE2" rm -rf --cached mod/foo
git -C "$MOODLE2" update-index --add --cacheinfo "160000,$C0b,mod/foo"
git -C "$MOODLE2" commit -q -m "sub at c0"
git -C "$MOODLE2" reset --hard -q HEAD
rm -rf "$MOODLE2/mod/foo"

git -C "$MOODLE2" branch -q unsubmodulized "$M0b"
git -C "$MOODLE2" checkout -q unsubmodulized
find "$MOODLE2/mod/foo" -mindepth 1 -delete
git -C "$PLUGIN2" archive "$C1b" | tar -x -C "$MOODLE2/mod/foo"
git -C "$MOODLE2" add mod/foo
git -C "$MOODLE2" commit -q -m "vendor bump to c1"

"$CLEANDEV/submodulize.sh" --repo "$MOODLE2" --no-sync-from-unsub

linkb="$(git -C "$MOODLE2" ls-tree submodulized mod/foo | awk '{print $3}')"
[[ "$linkb" == "$C0b" ]] || fail "expected gitlink unchanged at $C0b with --no-sync-from-unsub, got ${linkb:-empty}"

ok "submodulize --no-sync-from-unsub skips sync (fixture)"
