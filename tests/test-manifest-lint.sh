#!/usr/bin/env bash
# Validate plugin-submodules.manifest: format, duplicate paths, monorepo-style duplicate URLs.
# Limitation: two active lines with the same URL but different branches still count as duplicate URL (intentional).
# Does not validate that URLs are reachable or that paths exist on disk.
# Portable: no associative arrays (works on macOS /bin/bash 3.2 if needed for local runs).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cleandev

MANIFEST="${1:-$CLEANDEV/plugin-submodules.manifest}"
[[ -f "$MANIFEST" ]] || fail "manifest not found: $MANIFEST"

line_num=0
active_count=0
seen_paths=""

url_exists() {
  local u="$1"
  local entry
  while IFS= read -r entry; do
    [[ "$entry" == "$u" ]] && return 0
  done <<< "${url_list:-}"
  return 1
}

url_record() {
  local u="$1"
  url_list="${url_list:-}${url_list:+$'\n'}$u"
}

path_exists_in_list() {
  local p="$1"
  local x
  while IFS= read -r x; do
    [[ "$x" == "$p" ]] && return 0
  done <<< "${seen_paths:-}"
  return 1
}

url_list=""

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

  path="${trimmed%%|*}"
  rest="${trimmed#*|}"
  url="${rest%%|*}"
  # Optional third field (branch) is ignored here; scripts default it.

  path="${path#"${path%%[![:space:]]*}"}"
  path="${path%"${path##*[![:space:]]}"}"
  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"

  [[ -n "$path" ]] || fail "line $line_num: empty path"
  [[ -n "$url" ]] || fail "line $line_num: empty url for path $path"

  pipe_count=$(printf '%s' "$trimmed" | tr -cd '|' | wc -c | tr -d ' ')
  [[ "$pipe_count" -le 2 ]] || fail "line $line_num: too many '|' fields (max 2): $trimmed"

  if path_exists_in_list "$path"; then
    fail "duplicate manifest path '$path' (line $line_num)"
  fi
  seen_paths="${seen_paths:-}${seen_paths:+$'\n'}$path"
  active_count=$((active_count + 1))

  if url_exists "$url"; then
    fail "monorepo-style duplicate clone URL for two active paths (submodulize cannot map 1:1): url='$url' (line $line_num)"
  fi
  url_record "$url"
done < "$MANIFEST"

[[ "$active_count" -gt 0 ]] || fail "no active manifest lines (only comments/empty)"

ok "manifest lint: $active_count active lines, $MANIFEST"
