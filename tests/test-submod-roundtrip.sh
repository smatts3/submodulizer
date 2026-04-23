#!/usr/bin/env bash
# Vendored plugin -> submodulize -> unsubmodulize round-trip in isolated temp repos (no network).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cleandev

TMP=$(mktemp -d)
export HOME="$TMP/_home"
mkdir -p "$HOME"
# Submodule clone resolves sibling paths via file://; allow only inside this test process.
git config --global protocol.file.allow always
trap 'rm -rf "$TMP"' EXIT

PLUGIN="$TMP/plugin-upstream"
MOODLE="$TMP/moodle"
mkdir -p "$PLUGIN"
git -C "$PLUGIN" init -b main
echo "plug=1" > "$PLUGIN/version.txt"
git -C "$PLUGIN" add version.txt
git -C "$PLUGIN" commit -q -m "init plugin"

mkdir -p "$MOODLE/mod/testplugin"
git -C "$MOODLE" init -b develop
echo "vendored-only" > "$MOODLE/mod/testplugin/local.txt"
git -C "$MOODLE" add mod/testplugin
git -C "$MOODLE" commit -q -m "vendored plugin"

printf '%s\n' 'mod/testplugin|../plugin-upstream|main' > "$MOODLE/plugin-submodules.manifest"

# --- dry-run must not convert ---
"$CLEANDEV/submodulize.sh" --no-replay --repo "$MOODLE" --dry-run
assert_file "$MOODLE/mod/testplugin/local.txt"
assert_no_file "$MOODLE/.gitmodules"
assert_no_file "$MOODLE/.git/modules/mod/testplugin"

# --- submodulize ---
"$CLEANDEV/submodulize.sh" --no-replay --repo "$MOODLE" --no-commit
assert_file "$MOODLE/.gitmodules"
assert_file "$MOODLE/mod/testplugin/version.txt"
assert_no_file "$MOODLE/mod/testplugin/local.txt"
[[ -f "$MOODLE/mod/testplugin/.git" || -d "$MOODLE/mod/testplugin/.git" ]] || fail "expected submodule gitlink"
git -C "$MOODLE" submodule status --recursive | grep -q 'mod/testplugin' || fail "expected mod/testplugin in submodule status"

# --- unsubmodulize ---
"$CLEANDEV/unsubmodulize.sh" --no-replay --repo "$MOODLE" --no-commit
assert_file "$MOODLE/mod/testplugin/version.txt"
assert_no_file "$MOODLE/mod/testplugin/.git"
# Git may leave an empty .gitmodules; ensure no submodule entries remain.
if [[ -f "$MOODLE/.gitmodules" ]] && git -C "$MOODLE" config -f .gitmodules --get-regexp path 2>/dev/null | grep -q .; then
  fail "expected no [submodule] entries in .gitmodules after unsubmodulize"
fi
# unsubmodulize stages vendored files; ensure superproject tracks them (not just loose files on disk).
git -C "$MOODLE" ls-files --error-unmatch mod/testplugin/version.txt >/dev/null 2>&1 \
  || fail "expected mod/testplugin/version.txt in git index after unsubmodulize"
! git -C "$MOODLE" submodule status 2>/dev/null | grep -q 'mod/testplugin' \
  || fail "expected mod/testplugin not to remain a submodule after unsubmodulize"

ok "submodulize <-> unsubmodulize round-trip (default ROOT/plugin-submodules.manifest)"
