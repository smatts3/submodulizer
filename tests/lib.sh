#!/usr/bin/env bash
# Shared helpers for cleandev/tests. Sourced by test-*.sh; do not run directly.
# shellcheck shell=bash

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() {
  echo "ok: $*"
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file missing: $1"
}

assert_dir() {
  [[ -d "$1" ]] || fail "expected directory missing: $1"
}

assert_no_file() {
  [[ ! -e "$1" ]] || fail "expected missing path exists: $1"
}

# CLEANDEV must be set by run.sh
require_cleandev() {
  [[ -n "${CLEANDEV:-}" && -d "$CLEANDEV" ]] || fail "CLEANDEV not set or not a directory"
}

# write_submodulizer_json OUTPUT 'path|url|branch[|sparse[|tree]]' ...
#
# Convenience for tests: build a minimal submodulizer.json from pipe-delimited
# lines, reusing the legacy-format converter so tests stay terse. Pass one
# pipe-delimited string per plugin; '#' lines and blanks are skipped. Branch
# defaults to "main" when empty.
write_submodulizer_json() {
  local out="${1:?write_submodulizer_json: missing output path}"
  shift
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/submodulizer-test.XXXXXX.manifest")"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$tmp"
  done
  bash "$CLEANDEV/tools/convert-manifest.sh" --in "$tmp" --out "$out" >/dev/null
  rm -f -- "$tmp"
}
