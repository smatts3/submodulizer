#!/usr/bin/env bash
# Convert legacy pipe-delimited plugin-submodules.manifest to submodulizer.json.
#
# Section header comments in the input file set the "group" field on subsequent
# entries:
#   "# --- One repo per path ... ---" -> group: standard
#   "# --- Monorepos ... ---"          -> group: monorepo
#   "# --- No submodule clone ... ---" -> group: no_clone (no parseable lines)
#   "# --- Legacy plugins ... ---"     -> group: legacy
# Lines starting with '#' that don't match a header are skipped — including the
# textual "broken upstream" notes in the no_clone section. Add those manually to
# the output JSON as disabled entries if you want them preserved.
#
# Usage:
#   tools/convert-manifest.sh --in PATH --out PATH
#
# Requires: jq.

set -euo pipefail

IN=""
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in)  IN="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "convert-manifest: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$IN" || ! -f "$IN" ]]; then
  echo "convert-manifest: missing or unreadable --in PATH: ${IN:-<unset>}" >&2
  exit 1
fi
if [[ -z "$OUT" ]]; then
  echo "convert-manifest: --out PATH is required" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "convert-manifest: jq is required (install with 'apt install jq' / 'brew install jq')" >&2
  exit 1
fi

DEFAULT_BRANCH="main"

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

split_csv() {
  local csv="$1"
  local rest="${csv},"
  local seg
  while [[ -n "$rest" ]]; do
    seg="${rest%%,*}"
    rest="${rest#"$seg"}"
    rest="${rest#,}"
    seg="$(trim "$seg")"
    [[ -n "$seg" ]] && printf '%s\n' "$seg"
  done
}

build_entry_json() {
  local path="$1" url="$2" branch="$3" sparse="$4" tree="$5" group="$6"
  local -a sparse_arr=()
  if [[ -n "$sparse" ]]; then
    while IFS= read -r seg; do
      sparse_arr+=("$seg")
    done < <(split_csv "$sparse")
  fi
  local -a jq_args=(-n -c --arg path "$path" --arg url "$url" --arg group "$group")
  local filter='{path: $path, url: $url}'
  if [[ -n "$branch" && "$branch" != "$DEFAULT_BRANCH" ]]; then
    jq_args+=(--arg branch "$branch")
    filter+=' + {branch: $branch}'
  fi
  if ((${#sparse_arr[@]} > 0)); then
    local -a refs=()
    local i
    for i in "${!sparse_arr[@]}"; do
      jq_args+=(--arg "sparse${i}" "${sparse_arr[$i]}")
      refs+=("\$sparse${i}")
    done
    local joined
    joined="$(IFS=,; echo "${refs[*]}")"
    filter+=" + {sparse_paths: [${joined}]}"
  fi
  if [[ -n "$tree" ]]; then
    jq_args+=(--arg tree "$tree")
    filter+=' + {tree: $tree}'
  fi
  filter+=' + {group: $group}'
  jq "${jq_args[@]}" "$filter"
}

TMPF="$(mktemp "${TMPDIR:-/tmp}/convert-manifest.XXXXXX.ndjson")"
trap 'rm -f -- "$TMPF"' EXIT

CURRENT_GROUP="standard"
LINE_NO=0
while IFS= read -r raw || [[ -n "$raw" ]]; do
  LINE_NO=$((LINE_NO + 1))
  raw="${raw//$'\r'/}"
  lo="$(trim "$raw")"
  [[ -z "$lo" ]] && continue
  if [[ "$lo" == "#"* ]]; then
    case "$lo" in
      *"One repo per path"*)  CURRENT_GROUP="standard" ;;
      *"Monorepos"*)           CURRENT_GROUP="monorepo" ;;
      *"No submodule clone"*)  CURRENT_GROUP="no_clone" ;;
      *"Legacy plugins"*)      CURRENT_GROUP="legacy" ;;
    esac
    continue
  fi
  IFS='|' read -r f1 f2 f3 f4 f5 <<< "$lo"
  path="$(trim "${f1:-}")"
  url="$(trim "${f2:-}")"
  branch="$(trim "${f3:-}")"
  sparse="$(trim "${f4:-}")"
  tree="$(trim "${f5:-}")"
  [[ -z "$path" ]] && continue
  if [[ -z "$url" ]]; then
    echo "convert-manifest: line $LINE_NO: missing url for path $path; skipping" >&2
    continue
  fi
  build_entry_json "$path" "$url" "$branch" "$sparse" "$tree" "$CURRENT_GROUP" >>"$TMPF"
done < "$IN"

mkdir -p -- "$(dirname -- "$OUT")"
jq -s --arg defbr "$DEFAULT_BRANCH" '
  {
    version: 1,
    defaults: { branch: $defbr },
    plugins: .
  }
' "$TMPF" >"$OUT"

count="$(jq '.plugins | length' "$OUT")"
echo "convert-manifest: wrote $OUT ($count plugins)" >&2
