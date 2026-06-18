#!/usr/bin/env bash
# Validate submodulizer.json: schema (delegated to the helper), duplicate paths,
# duplicate URLs (monorepo rules), and absence of stray fields.
#
# The helper in submodulize.sh enforces strict per-entry validation already
# (unknown keys, wrong types, missing path/url, tree-without-sparse). This test
# adds cross-row checks that don't belong inside the per-entry loop.
#
# Duplicate clone URLs are allowed only when every entry with that URL has a
# non-empty sparse_paths array.
#
# Does not check that URLs are reachable or that paths exist on disk.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cleandev

MANIFEST="${1:-$CLEANDEV/submodulizer.json}"
[[ -f "$MANIFEST" ]] || fail "manifest not found: $MANIFEST"
command -v jq >/dev/null 2>&1 || fail "jq is required"

# 1) Schema validation: reuse the helper from submodulize.sh so the test stays
#    in lockstep with what the real tooling accepts.
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/manifest-lint.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

awk '
  /^submodulizer_trim\(\)/ { capture=1 }
  capture { print }
  capture && /^}$/ { count++; if (count >= 7) exit }
' "$CLEANDEV/submodulize.sh" >"$TMPD/helpers.sh"
# shellcheck disable=SC1091
source "$TMPD/helpers.sh"

declare -a M_PATHS=() M_URLS=() M_BRANCHES=() M_SPARSE=() M_TREE=()
submodulizer_load_manifest "$MANIFEST" || fail "schema validation failed for $MANIFEST"

active_count="${#M_PATHS[@]}"
[[ "$active_count" -gt 0 ]] || fail "no enabled entries in $MANIFEST"

# 2) Duplicate path check.
dup_paths="$(jq -r '
  [.plugins[] | select(.disabled != true) | .path]
  | group_by(.)
  | map(select(length > 1) | .[0])
  | .[]
' "$MANIFEST")"
if [[ -n "$dup_paths" ]]; then
  while IFS= read -r p; do
    fail "duplicate manifest path: $p"
  done <<<"$dup_paths"
fi

# 3) Duplicate URL → require non-empty sparse_paths on every entry with that URL.
bad_dups="$(jq -r '
  [.plugins[] | select(.disabled != true) | {url, path, sparse: (.sparse_paths // [])}]
  | group_by(.url)
  | map(select(length > 1))
  | .[]
  | select(any(.[]; .sparse | length == 0))
  | .[]
  | "\(.url)\t\(.path)\t\(.sparse | length)"
' "$MANIFEST")"
if [[ -n "$bad_dups" ]]; then
  echo "$bad_dups" >&2
  fail "duplicate clone URL requires non-empty sparse_paths on every entry sharing that URL"
fi

# 4) Sanity check the top-level metadata that the helper allows but doesn't
#    require: version, if present, must be 1; defaults.branch, if present, must
#    be a non-empty string.
jq -e '
  (has("version") and .version != 1 | not) and
  ((.defaults.branch // "main") | type == "string" and length > 0)
' "$MANIFEST" >/dev/null || fail "top-level metadata invalid: version must be 1 (if set) and defaults.branch must be a non-empty string"

ok "manifest lint: $active_count active entries, $MANIFEST"
