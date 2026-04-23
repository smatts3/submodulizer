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
