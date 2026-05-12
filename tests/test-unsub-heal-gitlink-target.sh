#!/usr/bin/env bash
# If unsubmodulized accidentally points at gitlink history, unsubmodulize replay should heal it.
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

git -C "$MOODLE" init -b master
printf 'core\n' > "$MOODLE/README.md"
mkdir -p "$MOODLE/mod/foo"
git -C "$PLUGIN" archive "$C0" | tar -x -C "$MOODLE/mod/foo"
git -C "$MOODLE" add README.md mod/foo
git -C "$MOODLE" commit -q -m "vendored base"
BASE="$(git -C "$MOODLE" rev-parse HEAD)"

# Create submodulized commit with gitlink at plugin C1.
git -C "$MOODLE" checkout -q -b submodulized
git -C "$MOODLE" config -f .gitmodules submodule.mod/foo.path mod/foo
git -C "$MOODLE" config -f .gitmodules submodule.mod/foo.url "$PLUGIN"
git -C "$MOODLE" add .gitmodules
git -C "$MOODLE" rm -rf --cached mod/foo
git -C "$MOODLE" update-index --add --cacheinfo "160000,$C1,mod/foo"
git -C "$MOODLE" commit -q -m "sub at c1"
SUB_SHA="$(git -C "$MOODLE" rev-parse HEAD)"
git -C "$MOODLE" reset --hard -q HEAD
rm -rf "$MOODLE/mod/foo"

# Polluted unsub branch: points at submodulized commit (bad state we want to heal).
git -C "$MOODLE" branch -q unsubmodulized "$SUB_SHA"
git -C "$MOODLE" checkout -q unsubmodulized
printf 'mod/foo|%s|main\n' "$PLUGIN" > "$MOODLE/plugin-submodules.manifest"

"$CLEANDEV/unsubmodulize.sh" --repo "$MOODLE" --target unsubmodulized

# Target branch should no longer contain the submodulized commit.
if git -C "$MOODLE" merge-base --is-ancestor "$SUB_SHA" unsubmodulized; then
  fail "expected healed unsubmodulized to exclude polluted submodulized commit"
fi

git -C "$MOODLE" ls-tree unsubmodulized mod/foo | grep -q '^040000' || fail "expected vendored tree at mod/foo"
git -C "$MOODLE" show unsubmodulized:mod/foo/f.txt | grep -q 'v2' || fail "expected vendored tip content v2"
N="$(git -C "$MOODLE" rev-list --count "${BASE}..unsubmodulized" 2>/dev/null || echo 0)"
[[ "$N" -eq 1 ]] || fail "expected one replay commit from base, got $N"

ok "unsubmodulize heals polluted gitlink target branch"
