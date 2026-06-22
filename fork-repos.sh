#!/usr/bin/env bash
# Fork third-party plugin repos referenced by submodulizer.json into the target
# owner (default smatts3), choosing visibility based on the upstream and only
# forking what we are legally allowed to redistribute.
#
# For every plugin whose upstream owner is NOT in the keep list (default:
# lsuonline, smatts3), this inspects the upstream and decides:
#
#   * upstream is PRIVATE                -> create a PRIVATE copy ("private fork")
#   * upstream is PUBLIC + approved OSS  -> create a PUBLIC copy ("public fork")
#     license (GPL/MIT/Apache/BSD/...)
#   * upstream is PUBLIC with NO         -> ASSUME GPL (these are Moodle plugins,
#     detectable license file               which must be GPLv3+; GitHub just
#                                           can't detect a top-level LICENSE) and
#                                           create a PUBLIC copy. Each is listed
#                                           in the report as forked-under-assumed-GPL.
#   * upstream is PUBLIC with an          -> SKIP and REPORT. We (LSU, a
#     unrecognized/custom license, or       government organization) cannot
#     a license we can't verify             confirm we may redistribute a fork.
#
# When GitHub reports NOASSERTION (it could not match the LICENSE file — common
# for markdown-formatted GNU licenses or SPDX-expression files), the script
# reads the actual license file and recovers the real SPDX id before deciding,
# so genuinely GPL/Apache/MIT/BSD plugins are not falsely flagged.
#
# Fork mechanism (per --fork-mode, default "object"):
#   * PUBLIC GitHub upstream that allows forking -> a real GitHub fork object
#     (POST /forks): shows "forked from", joins the fork network, supports
#     Sync/PR upstream. All branches (no default_branch_only).
#   * everything else (codeberg or other non-GitHub host, forking disabled on
#     the upstream, OR a PRIVATE fork) -> a full mirror copy (git clone --mirror
#     + push --mirror) into a new repo. Required because GitHub cannot fork a
#     public repo as private and cannot fork non-GitHub repos.
#   * --fork-mode mirror forces the mirror mechanism for everything.
# Both mechanisms preserve full history, upstream authorship and the LICENSE
# file, and both rewrite the manifest the same way.
#
# Upstreams are deduplicated by URL, so monorepos referenced by several plugin
# entries are copied once and every entry that used that URL is rewritten.
#
# Idempotent: once an entry points at the target owner it is in the keep list,
# so re-running skips it. If the target repo already exists it is reused (and
# re-mirrored unless --no-update).
#
# IMPORTANT: the license check is a programmatic heuristic based on the license
# GitHub detects (SPDX id), not legal advice. Anything that is not clearly an
# approved open-source license is reported for a human to review, never forked
# automatically.
#
# Requires: bash, git, curl, jq, and a GitHub token in GITHUB_TOKEN (or GH_TOKEN)
# that belongs to / can create repos under the target owner. The token needs the
# classic "repo" scope (or an equivalent fine-grained token with repo
# administration + contents write on the target owner).
#
# Usage:
#   ./privatize-repos.sh [--dry-run] [--manifest PATH] [--target-owner NAME]
#                        [--keep-owners a,b,c] [--no-update] [--yes] [-h]
#
#   -n, --dry-run        Classify every upstream and print the plan + legal
#                        report, but create nothing, push nothing, and edit
#                        nothing. With a token it does full classification;
#                        without a token it can only list candidates.
#       --manifest PATH  Manifest file (default: ./submodulizer.json).
#       --target-owner   GitHub owner to create the forks under (default smatts3).
#       --keep-owners    Comma-separated owners to leave untouched
#                        (default: lsuonline,smatts3 — target owner always kept).
#       --no-update      If the target repo already exists, do not re-mirror it.
#       --fork-mode M    object (default): real GitHub fork objects for public
#                        GitHub repos, mirror copy otherwise. mirror: always copy.
#       --yes            Skip the interactive confirmation before writing.
#   -h, --help           This help.

if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s: requires bash, not sh. Example: bash "%s" --dry-run\n' "${0##*/}" "$0" >&2
  exit 1
fi

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / args
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/submodulizer.json"
TARGET_OWNER="smatts3"
KEEP_OWNERS_CSV="lsuonline,smatts3"
DRY_RUN=false
NO_UPDATE=false
ASSUME_YES=false
FORK_MODE=object        # object = use GitHub fork API for public GitHub repos; mirror = always copy

GITHUB_API="${GITHUB_API:-https://api.github.com}"
GITHUB_HOST="${GITHUB_HOST:-github.com}"

die() { printf 'privatize-repos: %s\n' "$*" >&2; exit 1; }
warn() { printf 'privatize-repos: warning — %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

usage() { sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=true; shift ;;
    --manifest) MANIFEST="${2:?--manifest needs a path}"; shift 2 ;;
    --target-owner) TARGET_OWNER="${2:?--target-owner needs a value}"; shift 2 ;;
    --keep-owners) KEEP_OWNERS_CSV="${2:?--keep-owners needs a value}"; shift 2 ;;
    --no-update) NO_UPDATE=true; shift ;;
    --fork-mode) FORK_MODE="${2:?--fork-mode needs object|mirror}"; shift 2 ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

case "$FORK_MODE" in object|mirror) ;; *) die "--fork-mode must be 'object' or 'mirror' (got '$FORK_MODE')" ;; esac

# Token: accept GITHUB_TOKEN or GH_TOKEN.
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

# Always keep the target owner, plus whatever the user listed (lowercased).
declare -A KEEP_OWNERS=()
add_keep() { local o; o="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; [[ -n "$o" ]] && KEEP_OWNERS["$o"]=1; }
IFS=',' read -r -a _keep_arr <<< "$KEEP_OWNERS_CSV"
for o in "${_keep_arr[@]}"; do add_keep "$o"; done
add_keep "$TARGET_OWNER"

# ---------------------------------------------------------------------------
# License policy: SPDX ids we treat as "legally OK to fork & self-host".
# These are OSI/FSF licenses that grant redistribution + derivative works.
# Anything not matched here (no license, NOASSERTION/custom, non-commercial or
# no-derivatives variants, etc.) is reported for manual legal review.
# ---------------------------------------------------------------------------
# True for a single approved SPDX id.
is_allowed_spdx_single() {
  local up; up="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  case "$up" in
    GPL-*|LGPL-*|AGPL-*) return 0 ;;                       # all GNU copyleft
    MIT|MIT-0|X11) return 0 ;;
    APACHE-2.0) return 0 ;;
    BSD-2-CLAUSE*|BSD-3-CLAUSE*|BSD-4-CLAUSE*|0BSD) return 0 ;;
    ISC|ZLIB|BSL-1.0|NCSA|VIM|POSTGRESQL|UNLICENSE|WTFPL) return 0 ;;
    MPL-1.1|MPL-2.0|EPL-1.0|EPL-2.0|CDDL-1.0) return 0 ;;
    ARTISTIC-1.0|ARTISTIC-2.0) return 0 ;;
    CC0-1.0) return 0 ;;
    CC-BY-4.0|CC-BY-3.0|CC-BY-SA-4.0|CC-BY-SA-3.0) return 0 ;; # share/adapt OK
    OFL-1.1) return 0 ;;
    *) return 1 ;;
  esac
}

# True for an SPDX id OR an SPDX expression. For "A OR B" any approved token is
# enough (we may pick it); for "A AND B" every token must be approved.
is_allowed_license() {
  local expr="$1" up tok
  is_allowed_spdx_single "$expr" && return 0
  up="$(printf '%s' "$expr" | tr '[:lower:]' '[:upper:]' | sed 's/[()]/ /g')"
  if [[ "$up" == *" OR "* ]]; then
    for tok in $up; do
      [[ "$tok" == OR || "$tok" == AND || "$tok" == WITH ]] && continue
      is_allowed_spdx_single "$tok" && return 0
    done
    return 1
  fi
  if [[ "$up" == *" AND "* ]]; then
    local saw=0
    for tok in $up; do
      [[ "$tok" == OR || "$tok" == AND || "$tok" == WITH ]] && continue
      is_allowed_spdx_single "$tok" || return 1
      saw=1
    done
    [[ $saw -eq 1 ]] && return 0
  fi
  return 1
}

# Map raw license-file text to an SPDX id (or expression) when GitHub couldn't.
# Handles markdown-formatted GNU licenses and short SPDX-expression files, which
# are the reasons real Moodle-plugin licenses get reported as NOASSERTION.
detect_license_text() {
  local t="$1" head oneline
  # Match the license TITLE (top of the file), not body references — the full
  # GPLv3 text mentions the Affero GPL in section 13, which would false-positive.
  head="$(printf '%s' "$t" | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -6)"
  if grep -qi "GENERAL PUBLIC LICENSE" <<<"$head"; then
    if grep -qi "AFFERO" <<<"$head"; then echo "AGPL-3.0"; return; fi
    if grep -qi "LESSER" <<<"$head"; then echo "LGPL-3.0"; return; fi
    if grep -qiE "Version 2" <<<"$head" && ! grep -qiE "Version 3" <<<"$head"; then echo "GPL-2.0"; else echo "GPL-3.0"; fi
    return
  fi
  grep -qi "Apache License" <<<"$head" && grep -qiE "Version 2" <<<"$head" && { echo "Apache-2.0"; return; }
  grep -qi "Mozilla Public License" <<<"$head" && { echo "MPL-2.0"; return; }
  grep -qi "Permission is hereby granted, free of charge" <<<"$t" && { echo "MIT"; return; }
  grep -qi "Redistribution and use in source and binary forms" <<<"$t" && { echo "BSD-3-Clause"; return; }
  # Short SPDX-expression file, e.g. "Apache-2.0 OR GPL-2.0-only".
  oneline="$(printf '%s' "$t" | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -1)"
  if [[ -n "$oneline" ]] && printf '%s' "$oneline" \
      | grep -qiE '^[A-Za-z0-9.+-]+([[:space:]]+(OR|AND|WITH)[[:space:]]+[A-Za-z0-9.+-]+)+$'; then
    echo "$oneline"; return
  fi
  echo ""
}

# Fetch a repo's license file from GitHub and detect its real SPDX id.
detect_github_license() {
  local owner="$1" repo="$2" txt
  txt="$(curl -sS -m 30 \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github.raw" \
    "$GITHUB_API/repos/$owner/$repo/license" 2>/dev/null)" || txt=""
  detect_license_text "$txt"
}

# ---------------------------------------------------------------------------
# URL parsing
# ---------------------------------------------------------------------------
# Echo "host<TAB>owner<TAB>repo" for an https/ssh git URL, or nothing if it
# cannot be parsed. repo has any trailing ".git" removed.
parse_url() {
  local u="$1" host rest owner repo
  case "$u" in
    https://*|http://*)
      rest="${u#*://}" ; host="${rest%%/*}" ; rest="${rest#*/}" ;;
    git@*:*)
      rest="${u#git@}" ; host="${rest%%:*}" ; rest="${rest#*:}" ;;
    ssh://git@*)
      rest="${u#ssh://git@}" ; host="${rest%%/*}" ; rest="${rest#*/}" ;;
    *) return 0 ;;
  esac
  owner="${rest%%/*}"
  repo="${rest#*/}"
  repo="${repo%.git}"
  repo="${repo%/}"
  [[ -z "$host" || -z "$owner" || -z "$repo" || "$owner" == "$rest" ]] && return 0
  printf '%s\t%s\t%s\n' "$host" "$owner" "$repo"
}

# ---------------------------------------------------------------------------
# GitHub REST helpers (curl). Set HTTP_STATUS and API_BODY globals.
# ---------------------------------------------------------------------------
HTTP_STATUS=""
API_BODY=""
api() { # method path [json-body]
  local method="$1" path="$2" body="${3:-}" resp
  local -a args=(
    -sS -m 60 -X "$method"
    -H "Authorization: Bearer $TOKEN"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
    -w $'\n%{http_code}'
  )
  [[ -n "$body" ]] && args+=(-d "$body")
  resp="$(curl "${args[@]}" "$GITHUB_API$path")" || { HTTP_STATUS="000"; API_BODY=""; return 0; }
  HTTP_STATUS="${resp##*$'\n'}"
  API_BODY="${resp%$'\n'*}"
}

# ---------------------------------------------------------------------------
# Preflight — "make sure you can do this" before touching anything.
# ---------------------------------------------------------------------------
CREATE_PATH=""        # API path used to create repos (set by preflight)
TARGET_ORG=""         # non-empty when the target owner is an organization
preflight() {
  info "== Preflight =="

  for bin in git curl jq; do
    command -v "$bin" >/dev/null 2>&1 || die "required tool not found: $bin"
  done
  info "tools: git, curl, jq present"

  [[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"
  jq -e . "$MANIFEST" >/dev/null 2>&1 || die "manifest is not valid JSON: $MANIFEST"
  info "manifest: $MANIFEST (valid JSON)"

  if [[ -z "$TOKEN" ]]; then
    if $DRY_RUN; then
      warn "no GITHUB_TOKEN/GH_TOKEN set — dry run can only list candidates; it cannot read upstream visibility/licenses or classify them. Set a token to get the real plan and legal report."
      return 0
    fi
    die "no GITHUB_TOKEN/GH_TOKEN set; cannot read licenses, create, or push repos."
  fi

  # Who is the token?
  api GET /user
  if [[ "$HTTP_STATUS" != "200" ]]; then
    local msg="token check failed (GET /user -> HTTP $HTTP_STATUS)"
    $DRY_RUN && { warn "$msg"; return 0; }
    die "$msg"
  fi
  local login; login="$(printf '%s' "$API_BODY" | jq -r '.login // empty')"
  info "authenticated as: $login"

  # Decide where to create repos under the target owner.
  api GET "/users/$TARGET_OWNER"
  local owner_type=""
  [[ "$HTTP_STATUS" == "200" ]] && owner_type="$(printf '%s' "$API_BODY" | jq -r '.type // empty')"
  case "$owner_type" in
    Organization)
      CREATE_PATH="/orgs/$TARGET_OWNER/repos"
      TARGET_ORG="$TARGET_OWNER"
      info "target owner '$TARGET_OWNER' is an organization; new repos via $CREATE_PATH"
      ;;
    User)
      if [[ "$login" != "$TARGET_OWNER" ]]; then
        local msg="target owner '$TARGET_OWNER' is a personal account but you are authenticated as '$login'; you cannot create repos under another user."
        $DRY_RUN && { warn "$msg"; return 0; }
        die "$msg"
      fi
      CREATE_PATH="/user/repos"
      info "target owner '$TARGET_OWNER' is your user; new repos via $CREATE_PATH"
      ;;
    *)
      local msg="could not determine type of target owner '$TARGET_OWNER' (HTTP $HTTP_STATUS)"
      $DRY_RUN && { warn "$msg"; return 0; }
      die "$msg"
      ;;
  esac

  # Best-effort scope check for classic tokens.
  local scopes
  scopes="$(curl -sS -m 30 -o /dev/null -D - \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$GITHUB_API/user" 2>/dev/null | tr -d '\r' \
    | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}')" || scopes=""
  if [[ -n "$scopes" ]]; then
    if printf '%s' "$scopes" | grep -qE '(^|[, ])repo([, ]|$)'; then
      info "token scopes: $scopes (repo OK)"
    else
      warn "token scopes '$scopes' do not include 'repo'; creating private repos / pushing may fail."
    fi
  else
    info "token scopes: (none reported — likely a fine-grained token; cannot verify, will rely on live calls)"
  fi

  info "preflight OK"
}

# ---------------------------------------------------------------------------
# Build the work list from the manifest (dedup by URL, skip keep owners).
# ---------------------------------------------------------------------------
declare -a SRC_URLS=() SRC_OWNERS=() SRC_REPOS=() SRC_HOSTS=() SRC_NAMES=()
declare -A SEEN_URL=()

build_worklist() {
  local url host owner repo
  while IFS= read -r url; do
    url="${url%$'\r'}"   # jq on Git-for-Windows/MSYS emits CRLF
    [[ -z "$url" ]] && continue
    [[ -n "${SEEN_URL[$url]:-}" ]] && continue
    SEEN_URL["$url"]=1

    local parsed; parsed="$(parse_url "$url")"
    if [[ -z "$parsed" ]]; then
      warn "skipping unparseable URL: $url"
      continue
    fi
    IFS=$'\t' read -r host owner repo <<< "$parsed"

    local owner_lc; owner_lc="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"
    [[ -n "${KEEP_OWNERS[$owner_lc]:-}" ]] && continue

    SRC_URLS+=("$url")
    SRC_HOSTS+=("$host")
    SRC_OWNERS+=("$owner")
    SRC_REPOS+=("$repo")
  done < <(jq -r '.plugins[]? | select(.disabled != true) | .url // empty' "$MANIFEST")

  # Resolve target repo names, disambiguating basename collisions across owners.
  local i
  declare -A name_count=()
  for ((i=0; i<${#SRC_REPOS[@]}; i++)); do
    name_count["${SRC_REPOS[$i]}"]=$(( ${name_count["${SRC_REPOS[$i]}"]:-0} + 1 ))
  done
  for ((i=0; i<${#SRC_REPOS[@]}; i++)); do
    local name="${SRC_REPOS[$i]}"
    if (( ${name_count[$name]} > 1 )); then
      name="${SRC_OWNERS[$i]}-${SRC_REPOS[$i]}"
    fi
    SRC_NAMES+=("$name")
  done
}

# ---------------------------------------------------------------------------
# Inspect an upstream: set SRC_PRIVATE (true/false/""), SRC_SPDX, SRC_META_STATE
# (one of: ok | unverifiable | notoken | inaccessible:<code>).
# ---------------------------------------------------------------------------
SRC_PRIVATE="" SRC_SPDX="" SRC_META_STATE="" SRC_ALLOW_FORK=""
fetch_source_meta() {
  local host="$1" owner="$2" repo="$3"
  SRC_PRIVATE=""; SRC_SPDX=""; SRC_META_STATE=""; SRC_ALLOW_FORK="false"
  case "$host" in
    github.com)
      if [[ -z "$TOKEN" ]]; then SRC_META_STATE="notoken"; return 0; fi
      api GET "/repos/$owner/$repo"
      if [[ "$HTTP_STATUS" == "200" ]]; then
        SRC_PRIVATE="$(printf '%s' "$API_BODY" | jq -r '.private')"
        SRC_ALLOW_FORK="$(printf '%s' "$API_BODY" | jq -r '.allow_forking // true')"
        SRC_SPDX="$(printf '%s' "$API_BODY" | jq -r '.license.spdx_id // ""')"
        # GitHub reports NOASSERTION for licenses it can't match (e.g. a
        # markdown-formatted GNU license or an SPDX-expression file). Read the
        # actual license file to recover the real id before flagging it.
        if [[ "$SRC_SPDX" == "NOASSERTION" ]]; then
          local detected; detected="$(detect_github_license "$owner" "$repo")"
          [[ -n "$detected" ]] && SRC_SPDX="$detected"
        fi
        SRC_META_STATE="ok"
      else
        SRC_META_STATE="inaccessible:$HTTP_STATUS"
      fi
      ;;
    codeberg.org)
      # Gitea API exposes visibility but not a reliable SPDX license id. Codeberg
      # entries here are Moodle plugins (GPLv3+ by policy), so treat a successful
      # lookup as "ok" with an empty license: a public repo then flows into the
      # assume-GPL path, a private one into a private fork.
      local resp code body
      resp="$(curl -sS -m 30 -w $'\n%{http_code}' \
        "https://codeberg.org/api/v1/repos/$owner/$repo" 2>/dev/null)" || resp=$'\n000'
      code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
      if [[ "$code" == "200" ]]; then
        SRC_PRIVATE="$(printf '%s' "$body" | jq -r '.private')"
        SRC_SPDX=""              # not verifiable via API; assume GPL when public
        SRC_META_STATE="ok"
      else
        SRC_META_STATE="inaccessible:$code"
      fi
      ;;
    *)
      SRC_META_STATE="unverifiable"
      ;;
  esac
}

# Decide what to do with an inspected upstream. Echoes one token:
#   FORK_PUBLIC | ASSUME_GPL | FORK_PRIVATE | REVIEW | UNVERIFIABLE
#   | INACCESSIBLE | UNKNOWN
classify() {
  case "$SRC_META_STATE" in
    notoken)        printf 'UNKNOWN\n' ;;
    inaccessible:*) printf 'INACCESSIBLE\n' ;;
    ok)
      if [[ "$SRC_PRIVATE" == "true" ]]; then
        printf 'FORK_PRIVATE\n'
      elif [[ -z "$SRC_SPDX" || "$SRC_SPDX" == "null" ]]; then
        # No detectable license file. These are Moodle plugins (GPLv3+ by policy),
        # so assume GPL and fork publicly, recording the assumption in the report.
        printf 'ASSUME_GPL\n'
      elif is_allowed_license "$SRC_SPDX"; then
        printf 'FORK_PUBLIC\n'
      else
        printf 'REVIEW\n'
      fi
      ;;
    unverifiable)
      if [[ "$SRC_PRIVATE" == "true" ]]; then printf 'FORK_PRIVATE\n'
      else printf 'UNVERIFIABLE\n'; fi
      ;;
    *) printf 'UNKNOWN\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# Manifest rewrite: every entry whose url == $1 gets url := $2.
# ---------------------------------------------------------------------------
update_manifest_url() {
  local old="$1" new="$2" tmp
  tmp="$(mktemp "${MANIFEST}.XXXXXX")"
  jq --arg old "$old" --arg new "$new" \
    '.plugins |= map(if .url == $old then .url = $new else . end)' \
    "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"
}

# ---------------------------------------------------------------------------
# Mechanism dispatch + the two implementations (fork object / mirror copy).
# ---------------------------------------------------------------------------

# Echo "fork-object" when a real GitHub fork applies, else "mirror".
fork_mechanism() {
  local host="$1" private="$2"
  if [[ "$private" != "true" && "$host" == "github.com" \
        && "$FORK_MODE" == "object" && "${SRC_ALLOW_FORK:-true}" == "true" ]]; then
    echo "fork-object"
  else
    echo "mirror"
  fi
}

# Create a real GitHub fork object under the target owner (async). Rewrites the
# manifest on success. Returns 1 on failure (caller may not fall back).
do_fork_object() {
  local owner="$1" repo="$2" name="$3" src_url="$4"
  local target_full="$TARGET_OWNER/$name"
  local new_url="https://$GITHUB_HOST/$target_full.git"

  api GET "/repos/$target_full"
  if [[ "$HTTP_STATUS" == "200" ]]; then
    info "  reusing existing $target_full"
    update_manifest_url "$src_url" "$new_url"
    return 0
  fi

  info "  forking $owner/$repo -> $target_full (GitHub fork object)"
  local payload
  if [[ -n "$TARGET_ORG" ]]; then
    payload="$(jq -n --arg name "$name" --arg org "$TARGET_ORG" '{name: $name, organization: $org}')"
  else
    payload="$(jq -n --arg name "$name" '{name: $name}')"
  fi
  api POST "/repos/$owner/$repo/forks" "$payload"
  if [[ "$HTTP_STATUS" != "202" && "$HTTP_STATUS" != "200" ]]; then
    warn "fork API failed for $owner/$repo (HTTP $HTTP_STATUS): $(printf '%s' "$API_BODY" | jq -r '.message // empty')"
    return 1
  fi
  info "  fork requested (async; GitHub is populating $target_full)"
  update_manifest_url "$src_url" "$new_url"
  info "  updated submodulizer.json"
  return 0
}

# Decide the mechanism and run it.
apply_fork() {
  local host="$1" owner="$2" repo="$3" src_url="$4" name="$5" private="$6"
  if [[ "$(fork_mechanism "$host" "$private")" == "fork-object" ]]; then
    do_fork_object "$owner" "$repo" "$name" "$src_url"
  else
    do_fork_mirror "$src_url" "$name" "$private"
  fi
}

# Create (if needed) + mirror one upstream into the target owner with the given
# visibility. Returns 0 on success (and rewrites the manifest), 1 on failure.
do_fork_mirror() {
  local src_url="$1" name="$2" private="$3"   # private = true|false
  local target_full="$TARGET_OWNER/$name"
  local new_url="https://$GITHUB_HOST/$target_full.git"
  local vis_word; [[ "$private" == "true" ]] && vis_word="PRIVATE" || vis_word="PUBLIC"

  local exists=false
  api GET "/repos/$target_full"
  [[ "$HTTP_STATUS" == "200" ]] && exists=true

  if $exists; then
    info "  reusing existing $target_full"
    if $NO_UPDATE; then
      info "  skipping re-mirror (--no-update)"
      update_manifest_url "$src_url" "$new_url"
      return 0
    fi
  else
    info "  creating $vis_word repo $target_full"
    local payload
    payload="$(jq -n --arg name "$name" --argjson priv "$private" \
      '{name: $name, private: $priv, has_issues: false, has_wiki: false}')"
    api POST "$CREATE_PATH" "$payload"
    if [[ "$HTTP_STATUS" != "201" ]]; then
      warn "failed to create $target_full (HTTP $HTTP_STATUS): $(printf '%s' "$API_BODY" | jq -r '.message // empty')"
      return 1
    fi
  fi

  local tmpdir push_url rc=0
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/privatize.XXXXXX")"
  push_url="https://x-access-token:${TOKEN}@${GITHUB_HOST}/${target_full}.git"

  # Push branches + tags only (not --mirror): some hosts (Gitea/codeberg) expose
  # read-only refs/pull/* that GitHub rejects as "hidden refs", which would fail
  # an all-refs mirror push. --prune --force keeps the copy in sync on re-runs.
  if ! git clone --mirror "$src_url" "$tmpdir/repo.git" >/dev/null 2>&1; then
    warn "clone failed for $src_url"
    rc=1
  elif ! git -C "$tmpdir/repo.git" push --prune --force "$push_url" \
        'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' >/dev/null 2>&1; then
    warn "mirror push to $target_full failed"
    rc=1
  fi
  rm -rf "$tmpdir"
  [[ $rc -ne 0 ]] && return 1

  info "  mirrored $src_url -> $target_full"
  update_manifest_url "$src_url" "$new_url"
  info "  updated submodulizer.json"
  return 0
}

# ---------------------------------------------------------------------------
# Report buckets. R_ASSUMED_GPL is an audit trail of repos forked without a
# detectable license (assumed GPL); the rest are things we did NOT fork.
# ---------------------------------------------------------------------------
declare -a R_ASSUMED_GPL=() R_REVIEW=() R_UNVERIFIABLE=() R_INACCESSIBLE=() R_UNKNOWN=()

print_report() {
  info ""
  info "================ LEGAL REVIEW REPORT ================"
  local any=false
  if ((${#R_ASSUMED_GPL[@]})); then
    info ""
    info "FORKED UNDER ASSUMED GPL — no license file detected upstream; treated as"
    info "GPLv3+ because Moodle plugins must be GPL. Confirm if any of these are"
    info "actually under different terms:"
    printf '  - %s\n' "${R_ASSUMED_GPL[@]}"
  fi
  if ((${#R_REVIEW[@]})); then
    any=true
    info ""
    info "NEEDS LEGAL REVIEW — unrecognized / non-approved license (custom terms,"
    info "or not on the auto-approve open-source allowlist):"
    printf '  - %s\n' "${R_REVIEW[@]}"
  fi
  if ((${#R_UNVERIFIABLE[@]})); then
    any=true
    info ""
    info "COULD NOT VERIFY license (non-GitHub host without machine-readable"
    info "license metadata — confirm the license manually before forking):"
    printf '  - %s\n' "${R_UNVERIFIABLE[@]}"
  fi
  if ((${#R_INACCESSIBLE[@]})); then
    any=true
    info ""
    info "INACCESSIBLE (could not read the upstream — bad URL, deleted, or no"
    info "access with this token):"
    printf '  - %s\n' "${R_INACCESSIBLE[@]}"
  fi
  if ((${#R_UNKNOWN[@]})); then
    any=true
    info ""
    info "UNCLASSIFIED (no token in dry run — could not inspect):"
    printf '  - %s\n' "${R_UNKNOWN[@]}"
  fi
  $any || info "Nothing flagged — every candidate upstream is forkable."
  info ""
  info "Note: classification is based on the license GitHub detects (SPDX id) and"
  info "is a heuristic, not legal advice. Review flagged items before forking."
  info "===================================================="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  $DRY_RUN && info "(dry run — no changes will be made)"
  preflight

  build_worklist
  local total="${#SRC_URLS[@]}"
  if (( total == 0 )); then
    info "Nothing to do: every plugin upstream is already owned by: ${!KEEP_OWNERS[*]}"
    return 0
  fi

  info ""
  info "== $total candidate upstream repo(s) (owner not in: ${!KEEP_OWNERS[*]}) =="

  if ! $DRY_RUN && ! $ASSUME_YES; then
    printf 'Inspect and fork up to %d repo(s) under %s, rewriting %s? [y/N] ' \
      "$total" "$TARGET_OWNER" "$MANIFEST"
    local reply; read -r reply
    case "$reply" in y|Y|yes|YES) ;; *) die "aborted by user" ;; esac
  fi

  local i pub=0 priv=0 skip=0 fail=0
  for ((i=0; i<total; i++)); do
    local host="${SRC_HOSTS[$i]}" owner="${SRC_OWNERS[$i]}" repo="${SRC_REPOS[$i]}"
    local url="${SRC_URLS[$i]}" name="${SRC_NAMES[$i]}"
    local label="$owner/$repo"

    fetch_source_meta "$host" "$owner" "$repo"
    local decision; decision="$(classify)"
    local lic="${SRC_SPDX:-none}"

    printf '[%d/%d] %s (vis=%s, license=%s) -> %s\n' \
      "$((i+1))" "$total" "$label" "${SRC_PRIVATE:-?}" "$lic" "$decision"

    case "$decision" in
      FORK_PUBLIC|ASSUME_GPL|FORK_PRIVATE)
        local vis=false; [[ "$decision" == "FORK_PRIVATE" ]] && vis=true
        if [[ "$decision" == "ASSUME_GPL" ]]; then
          if [[ "$host" == "github.com" ]]; then R_ASSUMED_GPL+=("$label"); else R_ASSUMED_GPL+=("$label ($host, license unverifiable)"); fi
        fi
        local mech visword gpl_note=""
        mech="$(fork_mechanism "$host" "$vis")"
        [[ "$vis" == "true" ]] && visword="PRIVATE" || visword="PUBLIC"
        [[ "$decision" == "ASSUME_GPL" ]] && gpl_note=" (no upstream license; assuming GPL)"
        if $DRY_RUN; then
          info "  would create $visword $TARGET_OWNER/$name via $mech$gpl_note"
          if [[ "$vis" == "true" ]]; then priv=$((priv+1)); else pub=$((pub+1)); fi
        elif apply_fork "$host" "$owner" "$repo" "$url" "$name" "$vis"; then
          if [[ "$vis" == "true" ]]; then priv=$((priv+1)); else pub=$((pub+1)); fi
        else
          fail=$((fail+1))
        fi
        ;;
      REVIEW)       R_REVIEW+=("$label (license: $lic)"); skip=$((skip+1)) ;;
      UNVERIFIABLE) R_UNVERIFIABLE+=("$label ($host)"); skip=$((skip+1)) ;;
      INACCESSIBLE) R_INACCESSIBLE+=("$label (HTTP ${SRC_META_STATE#inaccessible:})"); skip=$((skip+1)) ;;
      UNKNOWN|*)    R_UNKNOWN+=("$label ($host)"); skip=$((skip+1)) ;;
    esac
  done

  info ""
  if $DRY_RUN; then
    info "== Dry-run summary: $pub public fork(s), $priv private fork(s), $skip skipped of $total =="
  else
    info "== Summary: $pub public fork(s), $priv private fork(s), $skip skipped, $fail failed of $total =="
  fi

  print_report

  $DRY_RUN && info "Re-run without --dry-run to apply (forks the approved repos; skipped ones are left untouched)."
  (( fail > 0 )) && return 1
  return 0
}

main "$@"
