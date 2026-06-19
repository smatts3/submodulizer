#!/usr/bin/env bash
# Validate submodulizer-moodle.json: schema, path linkage to submodulizer.json,
# at-most-one current=true per plugin, current=true is resolvable.
#
# The submodulizer_load_moodle_versions helper in submodulize.sh does the
# heavy lifting; this test wraps it for use against the repo's actual files.
# Does not perform remote fetches — those happen at submodulize-time. If the
# real manifest doesn't exist, this test is a no-op (the file is optional).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cleandev

MAIN_MANIFEST="${1:-$CLEANDEV/submodulizer.json}"
MOODLE_VERSIONS="${2:-$CLEANDEV/submodulizer-moodle.json}"

[[ -f "$MAIN_MANIFEST" ]] || fail "main manifest not found: $MAIN_MANIFEST"
if [[ ! -f "$MOODLE_VERSIONS" ]]; then
  ok "moodle-versions lint: no $MOODLE_VERSIONS (file is optional)"
  exit 0
fi
command -v jq >/dev/null 2>&1 || fail "jq is required"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/moodle-versions-lint.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

awk '
  /^submodulizer_trim\(\)/ { capture=1 }
  capture { print }
  capture && /^}$/ { count++; if (count >= 5) exit }
' "$CLEANDEV/submodulize.sh" >"$TMPD/helpers.sh"
# shellcheck disable=SC1091
source "$TMPD/helpers.sh"

declare -a MV_PATHS=() MV_DATES=() MV_SOURCES=() MV_SOURCETYPES=() MV_VERSIONS=() MV_COMMITHASHES=() MV_CURRENT=()
submodulizer_load_moodle_versions "$MOODLE_VERSIONS" "$MAIN_MANIFEST" || fail "schema validation failed for $MOODLE_VERSIONS"

plugin_count="$(jq '.plugins | length' "$MOODLE_VERSIONS")"
entry_count="${#MV_PATHS[@]}"

ok "moodle-versions lint: $plugin_count plugin(s), $entry_count entries, $MOODLE_VERSIONS"
