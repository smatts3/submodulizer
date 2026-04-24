#!/usr/bin/env bash
# Validate plugin-submodules.manifest: format, duplicate paths, duplicate URLs (monorepo rules).
# Format: path|url|branch [| sparse_paths [| in_repo_tree_path]]
#   sparse_paths — comma-separated directories inside the upstream repo (cone sparse-checkout).
#   in_repo_tree_path — optional; tree used for replay/unsub matching and archive (defaults to first sparse segment).
# Duplicate clone URLs are allowed only when every line with that URL has a non-empty sparse_paths field.
# Does not validate that URLs are reachable or that paths exist on disk.
# Portable: no associative arrays (works on macOS /bin/bash 3.2 if needed for local runs).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cleandev

MANIFEST="${1:-$CLEANDEV/plugin-submodules.manifest}"
[[ -f "$MANIFEST" ]] || fail "manifest not found: $MANIFEST"

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

line_num=0
active_count=0
seen_paths=""

path_exists_in_list() {
  local p="$1"
  local x
  while IFS= read -r x; do
    [[ "$x" == "$p" ]] && return 0
  done <<< "${seen_paths:-}"
  return 1
}

declare -a row_path=() row_url=() row_sparse=()

while IFS= read -r raw || [[ -n "$raw" ]]; do
  line_num=$((line_num + 1))
  line="${raw//$'\r'/}"
  trimmed="${line#"${line%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  [[ -z "$trimmed" ]] && continue
  [[ "$trimmed" =~ ^# ]] && continue

  if [[ "$trimmed" != *'|'* ]]; then
    fail "line $line_num: expected path|url|branch (no pipe): $trimmed"
  fi

  pipe_count=$(printf '%s' "$trimmed" | tr -cd '|' | wc -c | tr -d ' ')
  [[ "$pipe_count" -ge 2 ]] || fail "line $line_num: need at least path|url|branch: $trimmed"
  [[ "$pipe_count" -le 4 ]] || fail "line $line_num: too many '|' fields (max 4): $trimmed"

  IFS='|' read -ra parts <<< "$trimmed"
  ((${#parts[@]} >= 3 && ${#parts[@]} <= 5)) || fail "line $line_num: expected 3–5 fields: $trimmed"

  path="$(trim "${parts[0]}")"
  url="$(trim "${parts[1]}")"
  _branch="$(trim "${parts[2]}")"
  sparse=""
  tree=""
  ((${#parts[@]} >= 4)) && sparse="$(trim "${parts[3]}")"
  ((${#parts[@]} >= 5)) && tree="$(trim "${parts[4]}")"

  [[ -n "$path" ]] || fail "line $line_num: empty path"
  [[ -n "$url" ]] || fail "line $line_num: empty url for path $path"
  [[ -n "$tree" && -z "$sparse" ]] && fail "line $line_num: in-repo tree path (field 5) requires sparse paths (field 4): $trimmed"

  if path_exists_in_list "$path"; then
    fail "duplicate manifest path '$path' (line $line_num)"
  fi
  seen_paths="${seen_paths:-}${seen_paths:+$'\n'}$path"
  active_count=$((active_count + 1))

  row_path+=("$path")
  row_url+=("$url")
  row_sparse+=("$sparse")
done < "$MANIFEST"

[[ "$active_count" -gt 0 ]] || fail "no active manifest lines (only comments/empty)"

for i in "${!row_url[@]}"; do
  u="${row_url[$i]}"
  dup=0
  for j in "${!row_url[@]}"; do
    [[ "${row_url[$j]}" == "$u" ]] && dup=$((dup + 1))
  done
  if [[ "$dup" -gt 1 ]]; then
    [[ -n "${row_sparse[$i]}" ]] || fail "duplicate clone URL requires non-empty sparse paths (4th field) on every line with that URL: url='$u' (path '${row_path[$i]}', line context: manifest row index $i)"
  fi
done

ok "manifest lint: $active_count active lines, $MANIFEST"
