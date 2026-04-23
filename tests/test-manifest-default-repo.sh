#!/usr/bin/env bash
# Default manifest path: ROOT/plugin-submodules.manifest when --manifest is omitted.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cleandev

TMP=$(mktemp -d)
export HOME="$TMP/_home"
mkdir -p "$HOME"
trap 'rm -rf "$TMP"' EXIT

MOODLE="$TMP/moodle"
mkdir -p "$MOODLE"
git -C "$MOODLE" init -b develop -q
echo "core" >"$MOODLE/README.txt"
git -C "$MOODLE" add README.txt
git -C "$MOODLE" commit -q -m "init"

# No plugin-submodules.manifest at repo root → scripts fail
if "$CLEANDEV/submodulize.sh" --repo "$MOODLE" --dry-run 2>/dev/null; then
  fail "expected submodulize to fail when default manifest is missing"
fi
if "$CLEANDEV/unsubmodulize.sh" --repo "$MOODLE" --dry-run 2>/dev/null; then
  fail "expected unsubmodulize to fail when default manifest is missing"
fi

set +e
sub_out=$("$CLEANDEV/submodulize.sh" --repo "$MOODLE" --dry-run 2>&1)
sub_ec=$?
red_out=$(bash "$CLEANDEV/manifest-submodulize-redundant.sh" --repo "$MOODLE" 2>&1)
red_ec=$?
set -e
[[ "$sub_ec" -ne 0 ]] || fail "expected submodulize nonzero exit"
[[ "$red_ec" -ne 0 ]] || fail "expected manifest-submodulize-redundant nonzero exit"
echo "$sub_out" | grep -Fq "Manifest not found" || fail "expected submodulize stderr to mention Manifest not found"
echo "$red_out" | grep -Fq "Manifest not found" || fail "expected redundant stderr to mention Manifest not found"

ok "default manifest path requires ROOT/plugin-submodules.manifest when --manifest omitted"
