#!/usr/bin/env bash
# After submodulize, when there are no upstream plugin changes, unsubmodulize must NOT include
# the "add plugin submodules" layout commit on unsubmodulized. unsubmodulized must point at the
# pre-submodulize vendored ancestor.
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

git -C "$MOODLE" init -b develop
printf 'core\n' > "$MOODLE/README.md"
mkdir -p "$MOODLE/mod/foo"
git -C "$PLUGIN" archive HEAD | tar -x -C "$MOODLE/mod/foo"
git -C "$MOODLE" add README.md mod/foo
git -C "$MOODLE" commit -q -m "vendored base"
VENDORED_TIP="$(git -C "$MOODLE" rev-parse HEAD)"

printf 'mod/foo|%s|main\n' "$PLUGIN" > "$MOODLE/plugin-submodules.manifest"

# Bootstrap creates submodulized (layout commit) and unsubmodulized.
"$CLEANDEV/submodulize.sh" --repo "$MOODLE"

SUB_TIP="$(git -C "$MOODLE" rev-parse submodulized)"
UNSUB_TIP="$(git -C "$MOODLE" rev-parse unsubmodulized)"

[[ "$UNSUB_TIP" != "$SUB_TIP" ]] || fail "unsubmodulized must not equal submodulized (would carry layout commit)"
if git -C "$MOODLE" merge-base --is-ancestor "$SUB_TIP" "$UNSUB_TIP"; then
  fail "submodulized layout commit must not be ancestor of unsubmodulized"
fi
[[ "$UNSUB_TIP" == "$VENDORED_TIP" ]] || fail "expected unsubmodulized at pre-submodulize vendored tip; got $UNSUB_TIP"

git -C "$MOODLE" ls-tree unsubmodulized mod/foo | grep -q '^040000' || fail "unsubmodulized must keep mod/foo as a vendored directory"
if git -C "$MOODLE" log -1 --format=%s unsubmodulized | grep -qi 'add plugin submodules'; then
  fail "unsubmodulized must not contain the submodulize layout commit subject"
fi

ok "no-op unsubmodulize keeps unsubmodulized free of submodulize layout commit (bootstrap)"

# --- Standalone unsubmodulize run (cron-style): same expectation ---
TMP2="$TMP/round2"
mkdir -p "$TMP2"
PLUGIN2="$TMP2/plugin"
MOODLE2="$TMP2/moodle"
mkdir -p "$PLUGIN2" "$MOODLE2"

git -C "$PLUGIN2" init -b main
echo "v1" > "$PLUGIN2/f.txt"
git -C "$PLUGIN2" add f.txt
git -C "$PLUGIN2" commit -q -m "p1"
PC1="$(git -C "$PLUGIN2" rev-parse HEAD)"

git -C "$MOODLE2" init -b develop
printf 'core\n' > "$MOODLE2/README.md"
mkdir -p "$MOODLE2/mod/foo"
git -C "$PLUGIN2" archive "$PC1" | tar -x -C "$MOODLE2/mod/foo"
git -C "$MOODLE2" add README.md mod/foo
git -C "$MOODLE2" commit -q -m "vendored base"
VENDORED2="$(git -C "$MOODLE2" rev-parse HEAD)"

# Hand-build submodulized with a layout commit (simulates a prior submodulize run).
git -C "$MOODLE2" checkout -q -b submodulized
git -C "$MOODLE2" config -f .gitmodules submodule.mod/foo.path mod/foo
git -C "$MOODLE2" config -f .gitmodules submodule.mod/foo.url "$PLUGIN2"
git -C "$MOODLE2" add .gitmodules
git -C "$MOODLE2" rm -rf --cached mod/foo
git -C "$MOODLE2" update-index --add --cacheinfo "160000,$PC1,mod/foo"
git -C "$MOODLE2" commit -q -m "chore: add plugin submodules per plugin-submodules.manifest"
LAYOUT_SHA="$(git -C "$MOODLE2" rev-parse HEAD)"
git -C "$MOODLE2" reset --hard -q HEAD
rm -rf "$MOODLE2/mod/foo"

printf 'mod/foo|%s|main\n' "$PLUGIN2" > "$MOODLE2/plugin-submodules.manifest"

# Run unsubmodulize while checked out on submodulized (the user's scenario).
"$CLEANDEV/unsubmodulize.sh" --repo "$MOODLE2" --target unsubmodulized

UNSUB2="$(git -C "$MOODLE2" rev-parse unsubmodulized)"
[[ "$UNSUB2" != "$LAYOUT_SHA" ]] || fail "unsubmodulized must not point at submodulize layout commit"
if git -C "$MOODLE2" merge-base --is-ancestor "$LAYOUT_SHA" "$UNSUB2"; then
  fail "submodulize layout commit must not be ancestor of unsubmodulized (cron flow)"
fi
[[ "$UNSUB2" == "$VENDORED2" ]] || fail "expected unsubmodulized at pre-submodulize vendored tip; got $UNSUB2"
git -C "$MOODLE2" ls-tree unsubmodulized mod/foo | grep -q '^040000' || fail "unsubmodulized must keep mod/foo as a vendored directory (cron flow)"

ok "no-op unsubmodulize keeps unsubmodulized free of submodulize layout commit (standalone)"
