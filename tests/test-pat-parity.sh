#!/usr/bin/env bash
# Regression guard: source still contains the PAT git -c wiring (substring match).
# This does not prove HTTPS auth works at runtime; integration with GitHub needs manual/CI secrets tests.
# shellcheck disable=SC2016  # grep -F patterns intentionally contain literal ${git_github_pat_c[@]}
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cleandev

SUB="$CLEANDEV/submodulize.sh"
UNS="$CLEANDEV/unsubmodulize.sh"

grep -Fq 'git_github_pat_c=()' "$SUB" || fail "submodulize: missing git_github_pat_c init"
grep -Fq 'git "${git_github_pat_c[@]}" ls-remote' "$SUB" || fail "submodulize: ls-remote missing PAT -c array"
grep -Fq 'git "${git_github_pat_c[@]}" -c core.sparseCheckout=false' "$SUB" || fail "submodulize: submodule add missing PAT -c array"

grep -Fq 'git_github_pat_c=()' "$UNS" || fail "unsubmodulize: missing git_github_pat_c init"
grep -Fq 'git "${git_github_pat_c[@]}" ls-remote' "$UNS" || fail "unsubmodulize: ls-remote missing PAT -c array"
grep -Fq 'git "${git_github_pat_c[@]}" clone' "$UNS" || fail "unsubmodulize: clone missing PAT -c array"

ok "PAT -c parity present in submodulize.sh and unsubmodulize.sh"
