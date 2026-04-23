#!/usr/bin/env bash
# Unit tests for cleandev/manifest-submodulize-redundant.sh (new.sh --submodulize skip logic).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cleandev

REDUNDANT_SH="$CLEANDEV/manifest-submodulize-redundant.sh"
assert_file "$REDUNDANT_SH"

run_redundant() {
  local repo="$1"
  local man="${2:-}"
  if [[ -n "$man" ]]; then
    bash "$REDUNDANT_SH" --repo "$repo" --manifest "$man"
  else
    bash "$REDUNDANT_SH" --repo "$repo"
  fi
}

write_gitmodules() {
  local repo="$1"
  shift
  local pair
  : >"$repo/.gitmodules"
  for pair in "$@"; do
    local spath="${pair%%=*}"
    local url="${pair#*=}"
    {
      printf '[submodule "%s"]\n' "$spath"
      printf '\tpath = %s\n' "$spath"
      printf '\turl = %s\n' "$url"
    } >>"$repo/.gitmodules"
  done
}

expect_redundant() {
  local repo="$1"
  local man="${2:-}"
  if run_redundant "$repo" "$man"; then
    return 0
  fi
  fail "expected exit 0 (submodulize redundant), got 1 — repo=$repo manifest=${man:-<default>}"
}

expect_not_redundant() {
  local repo="$1"
  local man="${2:-}"
  if ! run_redundant "$repo" "$man"; then
    return 0
  fi
  fail "expected exit 1 (submodulize needed), got 0 — repo=$repo manifest=${man:-<default>}"
}

TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/manifest-submod-redundant.XXXXXX")"
trap 'rm -rf "$TMP_BASE"' EXIT

# --- all manifest paths in .gitmodules → redundant (exit 0) ---
R1="$TMP_BASE/r1"
mkdir -p "$R1"
git -C "$R1" init -q
write_gitmodules "$R1" \
  "mod/foo=https://example.com/foo.git" \
  "blocks/bar=https://example.com/bar.git"
M1="$TMP_BASE/m1.manifest"
{
  printf '# comment\n'
  printf 'mod/foo|https://example.com/foo.git|main\n'
  printf '  blocks/bar  |https://example.com/bar.git|main\n'
} >"$M1"
expect_redundant "$R1" "$M1"

# --- one path missing from .gitmodules → not redundant ---
R2="$TMP_BASE/r2"
mkdir -p "$R2"
git -C "$R2" init -q
write_gitmodules "$R2" "mod/foo=https://example.com/foo.git"
M2="$TMP_BASE/m2.manifest"
printf 'mod/foo|u|main\nmod/missing|u|main\n' >"$M2"
expect_not_redundant "$R2" "$M2"

# --- no .gitmodules → not redundant ---
R3="$TMP_BASE/r3"
mkdir -p "$R3"
git -C "$R3" init -q
M3="$TMP_BASE/m3.manifest"
printf 'mod/foo|u|main\n' >"$M3"
expect_not_redundant "$R3" "$M3"

# --- empty .gitmodules → not redundant ([ -s .gitmodules ] false) ---
R4="$TMP_BASE/r4"
mkdir -p "$R4"
git -C "$R4" init -q
: >"$R4/.gitmodules"
M4="$TMP_BASE/m4.manifest"
printf 'mod/foo|u|main\n' >"$M4"
expect_not_redundant "$R4" "$M4"

# --- manifest only comments/blank → not redundant (no -s .gitmodules match with vacuous need_submod=0) ---
R5="$TMP_BASE/r5"
mkdir -p "$R5"
git -C "$R5" init -q
write_gitmodules "$R5" "mod/foo=https://example.com/foo.git"
M5="$TMP_BASE/m5.manifest"
printf '# only comments\n\n# foo\n' >"$M5"
expect_not_redundant "$R5" "$M5"

# --- default manifest at ROOT/plugin-submodules.manifest (no --manifest flag) ---
R6="$TMP_BASE/r6"
mkdir -p "$R6"
git -C "$R6" init -q
write_gitmodules "$R6" \
  "mod/foo=https://example.com/foo.git" \
  "blocks/bar=https://example.com/bar.git"
printf 'mod/foo|https://example.com/foo.git|main\nblocks/bar|https://example.com/bar.git|main\n' >"$R6/plugin-submodules.manifest"
expect_redundant "$R6"

ok "manifest-submodulize-redundant.sh (skip vs run submodulize)"
