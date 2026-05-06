#!/usr/bin/env bash
# Incremental unsub replay: default --source submodulized; no --force when unsubmodulized exists.
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
git -C "$PLUGIN" config core.autocrlf false
echo "v1" > "$PLUGIN/f.txt"
git -C "$PLUGIN" add f.txt
git -C "$PLUGIN" commit -q -m "p1"
echo "v2" >> "$PLUGIN/f.txt"
git -C "$PLUGIN" commit -q -am "p2"
echo "v3" >> "$PLUGIN/f.txt"
git -C "$PLUGIN" commit -q -am "p3"

C0="$(git -C "$PLUGIN" rev-parse HEAD~2)"
C1="$(git -C "$PLUGIN" rev-parse HEAD~1)"
C2="$(git -C "$PLUGIN" rev-parse HEAD)"

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

# Initial build (force ok); submodulized tip is still C1 so replay is c0..c1 only.
"$CLEANDEV/unsubmodulize.sh" --repo "$MOODLE" --fork-point "$BASE" --source submodulized \
  --target unsubmodulized --force --plugin-base "mod/foo=$C0"

N1="$(git -C "$MOODLE" rev-list --count "${BASE}..unsubmodulized" 2>/dev/null || echo 0)"
[[ "$N1" -eq 1 ]] || fail "expected 1 replay commit past BASE after first unsub, got $N1"
git -C "$MOODLE" show "unsubmodulized:mod/foo/f.txt" | grep -q v2 || fail "expected v2 after first unsub"
if git -C "$MOODLE" show "unsubmodulized:mod/foo/f.txt" | grep -q v3; then
  fail "did not expect v3 after first unsub (only c0..c1 replayed)"
fi

# Advance submodulized to C2, then incremental unsub (no --force).
git -C "$MOODLE" checkout -q submodulized
git -C "$MOODLE" update-index --add --cacheinfo "160000,$C2,mod/foo"
git -C "$MOODLE" commit -q -m "sub at c2"

"$CLEANDEV/unsubmodulize.sh" --repo "$MOODLE" --fork-point "$BASE" --source submodulized \
  --target unsubmodulized

N2="$(git -C "$MOODLE" rev-list --count "${BASE}..unsubmodulized" 2>/dev/null || echo 0)"
[[ "$N2" -eq 2 ]] || fail "expected 2 replay commits past BASE after incremental unsub, got $N2"
git -C "$MOODLE" show "unsubmodulized:mod/foo/f.txt" | grep -q v3 || fail "expected v3 after incremental unsub"

# Idempotent
"$CLEANDEV/unsubmodulize.sh" --repo "$MOODLE" --fork-point "$BASE" --source submodulized \
  --target unsubmodulized

N3="$(git -C "$MOODLE" rev-list --count "${BASE}..unsubmodulized" 2>/dev/null || echo 0)"
[[ "$N3" -eq 2 ]] || fail "expected still 2 commits past BASE when already up to date, got $N3"

ok "unsubmodulize incremental replay without --force"
