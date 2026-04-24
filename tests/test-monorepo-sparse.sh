#!/usr/bin/env bash
# Monorepo: one remote URL, two manifest lines with sparse paths; submodulize and unsubmodulize one-shot.
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

MONO="$TMP/mono"
MOODLE="$TMP/moodle"

mkdir -p "$MONO/mods/p1" "$MONO/mods/p2"
echo a > "$MONO/mods/p1/a.txt"
echo b > "$MONO/mods/p2/b.txt"
echo junk > "$MONO/topjunk.txt"
git -C "$MONO" init -b main
git -C "$MONO" config core.autocrlf false
git -C "$MONO" add mods/p1 mods/p2 topjunk.txt
git -C "$MONO" commit -q -m "mono"

mkdir -p "$MOODLE/local/p1" "$MOODLE/local/p2"
git -C "$MOODLE" init -b master
git -C "$MOODLE" config core.autocrlf false
git -C "$MONO" archive HEAD:mods/p1 | tar -x -C "$MOODLE/local/p1"
git -C "$MONO" archive HEAD:mods/p2 | tar -x -C "$MOODLE/local/p2"
git -C "$MOODLE" add local/p1 local/p2
git -C "$MOODLE" commit -q -m "vendored from mono"

{
  printf 'local/p1|%s|main|mods/p1\n' "$MONO"
  printf 'local/p2|%s|main|mods/p2\n' "$MONO"
} >"$MOODLE/plugin-submodules.manifest"

"$CLEANDEV/submodulize.sh" --no-replay --repo "$MOODLE"

git -C "$MOODLE" ls-tree HEAD local/p1 | grep -q '^160000' || fail "expected gitlink at local/p1"
git -C "$MOODLE" ls-tree HEAD local/p2 | grep -q '^160000' || fail "expected gitlink at local/p2"

assert_file "$MOODLE/local/p1/mods/p1/a.txt"
[[ "$(cat "$MOODLE/local/p1/mods/p1/a.txt")" == a ]] || fail "sparse submodule p1 content"
assert_no_file "$MOODLE/local/p1/mods/p2/b.txt"

"$CLEANDEV/unsubmodulize.sh" --no-replay --repo "$MOODLE"

assert_file "$MOODLE/local/p1/a.txt"
assert_file "$MOODLE/local/p2/b.txt"
[[ "$(cat "$MOODLE/local/p1/a.txt")" == a ]] || fail "vendored p1 layout"
[[ "$(cat "$MOODLE/local/p2/b.txt")" == b ]] || fail "vendored p2 layout"

ok "monorepo sparse manifest: submodulize + unsubmodulize"
