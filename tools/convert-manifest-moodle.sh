#!/usr/bin/env bash
# Generate a starter submodulizer-moodle.json from submodulizer.json by running
# `git ls-remote` against each non-disabled plugin URL to capture the current
# branch tip SHA and recording it as `current: true` with today's date.
#
# The resulting file is immediately consumable by submodulize.sh: each plugin
# is pinned to whatever its branch tip was at generation time. Update entries
# (or add new ones with later dates) to bump pins later.
#
# Plugins whose ls-remote fails (private without credentials, network error,
# missing branch, etc.) are logged to stderr and skipped — they won't appear
# in the output, which means submodulize.sh will fall back to the branch-tip
# behavior for them.
#
# Usage:
#   tools/convert-manifest-moodle.sh --in PATH --out PATH [--date YYYY-MM-DD]
#
#   --in PATH    Source manifest. Accepts submodulizer.json (preferred) or a
#                legacy pipe-delimited plugin-submodules.manifest (auto-converted
#                in memory via tools/convert-manifest.sh).
#   --out PATH   Destination submodulizer-moodle.json.
#   --date STR   Date string to record on each entry (default: today, %Y-%m-%d).
#
# Requires: jq, git, network access. Honors GITHUB_TOKEN like submodulize.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IN=""
OUT=""
DATE_STR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in)   IN="${2:?}"; shift 2 ;;
    --out)  OUT="${2:?}"; shift 2 ;;
    --date) DATE_STR="${2:?}"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "convert-manifest-moodle: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$IN" || ! -f "$IN" ]]; then
  echo "convert-manifest-moodle: missing or unreadable --in PATH: ${IN:-<unset>}" >&2
  exit 1
fi
if [[ -z "$OUT" ]]; then
  echo "convert-manifest-moodle: --out PATH is required" >&2
  exit 1
fi
for cmd in jq git; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "convert-manifest-moodle: required tool '$cmd' not found on PATH" >&2
    exit 1
  }
done
[[ -n "$DATE_STR" ]] || DATE_STR="$(date +%Y-%m-%d)"

# Same GITHUB_TOKEN handling as submodulize.sh: rewrite https://github.com/
# URLs to embed the PAT for ls-remote auth.
declare -a git_github_pat_c=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  git_github_pat_c+=(-c "url.https://${GITHUB_TOKEN}@github.com/.insteadOf=https://github.com/")
fi

# Detect input format and normalize to JSON in a temp file.
TMPF=""
JSON_IN="$IN"
if ! jq empty "$IN" >/dev/null 2>&1; then
  echo "convert-manifest-moodle: --in is not JSON; converting via tools/convert-manifest.sh" >&2
  TMPF="$(mktemp "${TMPDIR:-/tmp}/convert-manifest-moodle.XXXXXX.json")"
  bash "$SCRIPT_DIR/convert-manifest.sh" --in "$IN" --out "$TMPF" >&2
  JSON_IN="$TMPF"
fi
trap '[[ -n "$TMPF" && -f "$TMPF" ]] && rm -f "$TMPF"' EXIT

# Classify a clone URL into (sourcetype, source) per the schema in README-moodle.md.
# Echoes "sourcetype<TAB>source" on stdout.
classify_url() {
  local url="$1" host owner_repo stripped
  if [[ "$url" =~ ^git@([^:]+):(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    owner_repo="${BASH_REMATCH[2]}"
  elif [[ "$url" =~ ^https?://([^/]+)/(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    owner_repo="${BASH_REMATCH[2]}"
  else
    printf 'url\t%s\n' "$url"
    return 0
  fi
  stripped="${owner_repo%.git}"
  case "$host" in
    github.com|www.github.com) printf 'github\t%s\n' "$stripped" ;;
    gitlab.com|www.gitlab.com) printf 'gitlab\t%s\n' "$stripped" ;;
    bitbucket.org|www.bitbucket.org) printf 'bitbucket\t%s\n' "$stripped" ;;
    *) printf 'url\t%s\n' "$url" ;;
  esac
}

# Extract one TSV row per non-disabled plugin: path<TAB>url<TAB>branch.
# Branch falls back to defaults.branch (or "main").
mapfile_in_tsv() {
  jq -r '
    (.defaults.branch // "main") as $defbr
    | .plugins[]
    | select(.disabled != true)
    | "\(.path // "")\t\(.url // "")\t\(.branch // $defbr)"
  ' "$JSON_IN" | tr -d '\r'
}

# Resolve the branch tip SHA for ($url, $branch). Falls back to remote HEAD.
# Echoes the SHA on stdout, or non-zero exit on failure.
resolve_branch_tip() {
  local url="$1" branch="$2" out sha
  if [[ -n "$branch" ]]; then
    out="$(GIT_TERMINAL_PROMPT=0 git "${git_github_pat_c[@]}" ls-remote --heads -- "$url" "refs/heads/$branch" 2>/dev/null || true)"
    sha="$(awk 'NR==1 {print $1}' <<<"$out" | tr -d '\r')"
    if [[ -n "$sha" && "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      printf '%s\n' "$sha"
      return 0
    fi
  fi
  # Fall back to remote HEAD.
  out="$(GIT_TERMINAL_PROMPT=0 git "${git_github_pat_c[@]}" ls-remote --symref -- "$url" HEAD 2>/dev/null || true)"
  sha="$(awk '$2=="HEAD" {print $1}' <<<"$out" | tr -d '\r')"
  if [[ -n "$sha" && "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' "$sha"
    return 0
  fi
  return 1
}

NDJSON="$(mktemp "${TMPDIR:-/tmp}/convert-manifest-moodle-nd.XXXXXX.ndjson")"
trap '[[ -n "$TMPF" && -f "$TMPF" ]] && rm -f "$TMPF"; [[ -f "$NDJSON" ]] && rm -f "$NDJSON"' EXIT

n_total=0
n_ok=0
n_skip=0
while IFS=$'\t' read -r path url branch; do
  [[ -z "$path" ]] && continue
  n_total=$((n_total + 1))
  if [[ -z "$url" ]]; then
    echo "convert-manifest-moodle: [$n_total] $path: empty url; skipping" >&2
    n_skip=$((n_skip + 1))
    continue
  fi
  classification="$(classify_url "$url")"
  sourcetype="${classification%%$'\t'*}"
  source="${classification#*$'\t'}"
  if ! sha="$(resolve_branch_tip "$url" "$branch")"; then
    echo "convert-manifest-moodle: [$n_total] $path: ls-remote failed for $url (branch=$branch); skipping" >&2
    n_skip=$((n_skip + 1))
    continue
  fi
  echo "convert-manifest-moodle: [$n_total] $path -> $sha" >&2
  jq -n -c \
    --arg path "$path" \
    --arg date "$DATE_STR" \
    --arg source "$source" \
    --arg sourcetype "$sourcetype" \
    --arg commithash "$sha" \
    '{($path): {versions: [
      {
        date: $date,
        source: $source,
        sourcetype: $sourcetype,
        commithash: $commithash,
        current: true
      }
    ]}}' >>"$NDJSON"
  n_ok=$((n_ok + 1))
done < <(mapfile_in_tsv)

mkdir -p -- "$(dirname -- "$OUT")"
jq -s 'reduce .[] as $p ({}; . + $p) | {plugins: .}' "$NDJSON" >"$OUT"

echo "convert-manifest-moodle: wrote $OUT (${n_ok}/${n_total} plugins, ${n_skip} skipped)" >&2
