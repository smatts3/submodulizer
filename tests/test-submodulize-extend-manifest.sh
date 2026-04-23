#!/usr/bin/env bash
# With submodulized present, default submodulize (replay) applies manifest without --force; new paths become submodules.
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

PLUGIN1="$TMP/plugin1"
PLUGIN2="$TMP/plugin2"
MOODLE="$TMP/moodle"

mkdir -p "$PLUGIN1"
git -C "$PLUGIN1" init -b main
git -C "$PLUGIN1" config core.autocrlf false
echo "one" > "$PLUGIN1/a.txt"
git -C "$PLUGIN1" add a.txt
git -C "$PLUGIN1" commit -q -m "p1"

mkdir -p "$PLUGIN2"
git -C "$PLUGIN2" init -b main
git -C "$PLUGIN2" config core.autocrlf false
echo "two" > "$PLUGIN2/b.txt"
git -C "$PLUGIN2" add b.txt
git -C "$PLUGIN2" commit -q -m "p2"

mkdir -p "$MOODLE/mod/p1"
git -C "$MOODLE" init -b master
git -C "$MOODLE" config core.autocrlf false
git -C "$PLUGIN1" archive HEAD | tar -x -C "$MOODLE/mod/p1"
git -C "$MOODLE" add mod/p1
git -C "$MOODLE" commit -q -m "vendored p1"

printf '%s\n' "mod/p1|../plugin1|main" > "$MOODLE/plugin-submodules.manifest"

"$CLEANDEV/submodulize.sh" --repo "$MOODLE"

# Second run: no new manifest lines — should not require --force (one-shot no-op / skips).
"$CLEANDEV/submodulize.sh" --repo "$MOODLE"

git -C "$MOODLE" checkout -q submodulized
mkdir -p "$MOODLE/mod/p2"
git -C "$PLUGIN2" archive HEAD | tar -x -C "$MOODLE/mod/p2"
git -C "$MOODLE" add mod/p2
git -C "$MOODLE" commit -q -m "vendored p2 for submod"

{
  echo "mod/p1|../plugin1|main"
  echo "mod/p2|../plugin2|main"
} > "$MOODLE/plugin-submodules.manifest"

"$CLEANDEV/submodulize.sh" --repo "$MOODLE"

git -C "$MOODLE" ls-tree submodulized mod/p2 | grep -q '^160000' || fail "expected gitlink at mod/p2 after manifest extend"

ok "submodulize extends submodulized from manifest without --force"
