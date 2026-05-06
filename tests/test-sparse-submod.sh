#!/usr/bin/env bash
# submodulize still works when the superproject had sparse-checkout enabled.
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
mkdir -p "$PLUGIN" "$MOODLE"
git -C "$PLUGIN" init -b main
echo "p" > "$PLUGIN/a.txt"
git -C "$PLUGIN" add a.txt
git -C "$PLUGIN" commit -q -m "i"

git -C "$MOODLE" init -b develop
echo "core" > "$MOODLE/README.txt"
mkdir -p "$MOODLE/mod/testplugin"
echo "v" > "$MOODLE/mod/testplugin/x.txt"
git -C "$MOODLE" add README.txt mod/testplugin
git -C "$MOODLE" commit -q -m "init"

# Cone mode expects directory paths; include whole `mod/` so `mod/testplugin` is on disk.
git -C "$MOODLE" sparse-checkout init --cone
git -C "$MOODLE" sparse-checkout set mod

printf '%s\n' 'mod/testplugin|../plugin-upstream|main' > "$MOODLE/plugin-submodules.manifest"

"$CLEANDEV/submodulize.sh" --no-replay --repo "$MOODLE" --no-commit

assert_file "$MOODLE/mod/testplugin/a.txt"
# submodulize disables the same flags it clears in disable_sparse_checkout_if_needed()
[[ "$(git -C "$MOODLE" config --bool core.sparseCheckout 2>/dev/null || echo false)" != "true" ]] \
  || fail "expected core.sparseCheckout not true after submodulize"
[[ "$(git -C "$MOODLE" config --bool index.sparse 2>/dev/null || echo false)" != "true" ]] \
  || fail "expected index.sparse not true after submodulize"

ok "submodulize with prior sparse-checkout"
