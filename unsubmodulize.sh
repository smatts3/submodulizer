#!/usr/bin/env bash
# Replace git submodules with plain tracked directories (vendored plugins), matching lsuce-moodle
# develop style. For the submodule-layout Moodle superproject: manifest and .gitmodules live in that
# repo; this script reads plugin-submodules.manifest at the superproject root unless --manifest is set.
# Clones each plugin repo at the given branch, drops nested .git, and adds files to the parent.
# Run from inside the clone, or pass the clone path as ROOT / --repo.
# Default mode is replay: builds branch unsubmodulized with one superproject commit per plugin-repo commit.
# Use --no-replay for one-shot conversion (manifest loop only).
#
# Usage:
#   ./cleandev/unsubmodulize.sh [ROOT] [--dry-run] [--no-commit] [--ssh] [--manifest PATH] [--repo ROOT]
#   ./cleandev/unsubmodulize.sh --fork-point BASE ...   # replay (default)
#   ./cleandev/unsubmodulize.sh --no-replay ...         # one-shot
#   Bare ROOT is the same as --repo (optional; may appear before or after flags).
#
# Private GitHub repos over HTTPS: set GITHUB_TOKEN (PAT) so ls-remote / clone use
#   -c url.https://TOKEN@github.com/.insteadOf=https://github.com/
# (same as submodulize.sh). Or use --ssh.
#
# Requires bash (arrays, pipefail). Do not run as `sh this-script.sh`; use `bash` or execute directly.

if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s: requires bash, not sh. Example: bash "%s" ./ ...your args...\n' "${0##*/}" "$0" >&2
  exit 1
fi

set -euo pipefail

# Manifest / monorepo helpers (sparse checkout, tree match, archive extract).
submodulizer_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

submodulizer_sparse_default_tree_path() {
  local csv="$1" first
  first="${csv%%,*}"
  submodulizer_trim "$first"
}

submodulizer_plugin_tree_at_commit() {
  local pdir="$1" commit="$2" in_path="${3:-}"
  if [[ -z "$(submodulizer_trim "$in_path")" ]]; then
    git -C "$pdir" rev-parse "${commit}^{tree}" 2>/dev/null || return 1
  else
    git -C "$pdir" rev-parse "${commit}:${in_path}" 2>/dev/null || return 1
  fi
}

submodulizer_find_plugin_commit_for_tree() {
  local pdir="$1" want_tree="$2" in_path="${3:-}"
  local c t t2
  while IFS= read -r c; do
    if [[ -z "$(submodulizer_trim "${in_path:-}")" ]]; then
      t="$(submodulizer_plugin_tree_at_commit "$pdir" "$c" "")" || continue
      [[ "$t" == "$want_tree" ]] && { printf '%s\n' "$c"; return 0; }
    else
      if t="$(submodulizer_plugin_tree_at_commit "$pdir" "$c" "$in_path")" 2>/dev/null; then
        [[ "$t" == "$want_tree" ]] && { printf '%s\n' "$c"; return 0; }
      fi
      t2="$(submodulizer_plugin_tree_at_commit "$pdir" "$c" "")" || continue
      [[ "$t2" == "$want_tree" ]] && { printf '%s\n' "$c"; return 0; }
    fi
  done < <(git -C "$pdir" rev-list --first-parent --reverse --all)
  return 1
}

submodulizer_sparse_apply_in_worktree() {
  local root="${1:?}" rel="${2:?}" csv="$3"
  csv="$(submodulizer_trim "$csv")"
  [[ -n "$csv" ]] || return 0
  local sm="$root/$rel"
  [[ -e "$sm/.git" ]] || {
    echo "submodulizer_sparse_apply_in_worktree: not a git worktree: $sm" >&2
    return 1
  }
  local -a cones=()
  local seg rest="$csv,"
  while [[ -n "$rest" ]]; do
    seg="${rest%%,*}"
    rest="${rest#"$seg"}"
    rest="${rest#,}"
    seg="$(submodulizer_trim "$seg")"
    [[ -n "$seg" ]] && cones+=("$seg")
  done
  ((${#cones[@]} > 0)) || return 0
  if git -C "$sm" sparse-checkout init --cone 2>/dev/null; then
    git -C "$sm" sparse-checkout set -- "${cones[@]}"
  else
    git -C "$sm" sparse-checkout init 2>/dev/null || true
    git -C "$sm" sparse-checkout set -- "${cones[@]}"
  fi
}

submodulizer_tar_strip_components_for_path() {
  local in_path="$1"
  local n
  n="$(tr -cd / <<<"$in_path" | wc -c | tr -d ' \t')"
  echo "$((n + 1))"
}

submodulizer_git_archive_to_dir() {
  local pdir="$1" commit="$2" in_path="$3" dest="$4"
  mkdir -p "$dest"
  shopt -s dotglob nullglob 2>/dev/null || true
  rm -rf "${dest:?}/"*
  shopt -u dotglob nullglob 2>/dev/null || true
  if [[ -z "$(submodulizer_trim "${in_path:-}")" ]]; then
    git -C "$pdir" archive --format=tar "$commit" | tar -x -C "$dest"
  else
    local strip
    strip="$(submodulizer_tar_strip_components_for_path "$in_path")"
    git -C "$pdir" archive --format=tar "$commit" "$in_path" | tar -x -C "$dest" --strip-components="$strip"
  fi
}

MANIFEST=""
MANIFEST_EXPLICIT=false
DRY_RUN=false
NO_COMMIT=false
USE_SSH=false
REPO_ROOT=""
REPLAY=true
FORK_POINT=""
SOURCE_BRANCH=""
TARGET_BRANCH="unsubmodulized"
REPLAY_ORDER="chronological"
FORCE_REPLAY=false
REPLAY_SOURCE_EXPLICIT=false
REPLAY_TARGET_EXPLICIT=false
REPLAY_ORDER_EXPLICIT=false
declare -a PLUGIN_BASE_OVERRIDES=()

usage() {
  cat <<'EOF'
Replace git submodules listed in the manifest with plain tracked directories (vendored plugins).
For each entry: clones the plugin at the manifest branch, removes nested .git, deinits the submodule,
and stages the tree in the parent Moodle superproject (cleandev-style). The manifest normally lives
at the superproject root as plugin-submodules.manifest.

Moodle root defaults to the current directory’s git superproject (git rev-parse --show-toplevel), unless you set it explicitly.

Usage:
  unsubmodulize.sh [ROOT] [OPTIONS...]
  unsubmodulize.sh [OPTIONS...] [ROOT]

  ROOT — optional path to the Moodle git checkout. Give it as a single bare argument (no leading -),
         anywhere among the flags; same meaning as --repo. Only one repo path: do not pass a second
         bare path, and do not put a bare path after --repo (that is rejected).

Examples:
  unsubmodulize.sh --no-replay ~/workspace/moodle
  unsubmodulize.sh --dry-run --no-replay ~/workspace/moodle
  unsubmodulize.sh --fork-point abc123 --target unsubmodulized

Options:
  --dry-run       Print what would happen without changing the repo
  --no-commit     Stage vendored trees but do not commit
  --ssh           Use git@github.com URLs for github.com HTTPS entries
  --manifest PATH Plugin manifest (default: ROOT/plugin-submodules.manifest); optional 4th/5th fields for monorepo sparse (see README)
  --repo ROOT     Moodle git root (explicit form of a bare ROOT; overrides an earlier bare ROOT; a bare path after --repo is an error)

Replay (default — one superproject commit per plugin-repo commit on --target):
  --no-replay           One-shot mode: convert submodules per manifest (no branch replay)
  --replay              Replay mode (default; explicit if you toggled --no-replay earlier on the command line)
  --fork-point BASE     Superproject where replay starts (default: local master, else main, when omitted — see docs)
  --source BR           Submodule/vendored tip to replay from (default: submodulized, else unsubmodulized, else master, else main)
  --target BR           Branch to create/update (default: unsubmodulized)
  --order NAME          Only chronological (committer date, then path, then SHA)
  --force               Replay only: delete and rebuild --target from --fork-point (omit for incremental update when --target exists)
  --plugin-base P=S     Optional start SHA for manifest path P (e.g. when BASE has no gitlink)

Requires: git, and clean submodule working trees for paths being converted (no uncommitted changes inside submodules).

Private GitHub over HTTPS: set GITHUB_TOKEN (PAT) so ls-remote / clone can authenticate (same pattern as submodulize.sh),
or use --ssh.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --no-commit) NO_COMMIT=true; shift ;;
    --ssh) USE_SSH=true; shift ;;
    --no-replay) REPLAY=false; shift ;;
    --replay) REPLAY=true; shift ;;
    --fork-point)
      FORK_POINT="${2:?}"
      shift 2
      ;;
    --source)
      SOURCE_BRANCH="${2:?}"
      REPLAY_SOURCE_EXPLICIT=true
      shift 2
      ;;
    --target)
      TARGET_BRANCH="${2:?}"
      REPLAY_TARGET_EXPLICIT=true
      shift 2
      ;;
    --order)
      REPLAY_ORDER="${2:?}"
      REPLAY_ORDER_EXPLICIT=true
      shift 2
      ;;
    --force)
      FORCE_REPLAY=true
      shift
      ;;
    --plugin-base)
      PLUGIN_BASE_OVERRIDES+=("${2:?}")
      shift 2
      ;;
    --manifest)
      MANIFEST="${2:?}"
      MANIFEST_EXPLICIT=true
      shift 2
      ;;
    --repo)
      REPO_ROOT="${2:?}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -n "$REPO_ROOT" ]]; then
        echo "Unexpected argument: $1 (repo already set via --repo or positional path)" >&2
        exit 1
      fi
      REPO_ROOT="$1"
      shift
      ;;
  esac
done

if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "Not inside a git repository. Pass the Moodle root as a bare path or use --repo /path/to/moodle" >&2
    exit 1
  }
fi

if ! $MANIFEST_EXPLICIT; then
  MANIFEST="${REPO_ROOT%/}/plugin-submodules.manifest"
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "Manifest not found: $MANIFEST" >&2
  exit 1
fi

if $REPLAY; then
  [[ "$REPLAY_ORDER" == "chronological" ]] || {
    echo "Unsupported --order (only chronological): $REPLAY_ORDER" >&2
    exit 1
  }
else
  [[ -z "$FORK_POINT" ]] || {
    echo "--fork-point is only used in replay mode (omit --no-replay)" >&2
    exit 1
  }
  ((${#PLUGIN_BASE_OVERRIDES[@]} == 0)) || {
    echo "--plugin-base is only valid in replay mode (omit --no-replay)" >&2
    exit 1
  }
  $FORCE_REPLAY && {
    echo "--force is only valid in replay mode (omit --no-replay)" >&2
    exit 1
  }
  $REPLAY_SOURCE_EXPLICIT && {
    echo "--source is only valid in replay mode (omit --no-replay)" >&2
    exit 1
  }
  $REPLAY_TARGET_EXPLICIT && {
    echo "--target is only valid in replay mode (omit --no-replay)" >&2
    exit 1
  }
  $REPLAY_ORDER_EXPLICIT && {
    echo "--order is only valid in replay mode (omit --no-replay)" >&2
    exit 1
  }
fi

cd "$REPO_ROOT"

# When --fork-point is omitted in replay mode, default to local master (else main) if safe; see resolve below.
if $REPLAY && [[ -z "$FORK_POINT" ]]; then
  base_ref=""
  if git show-ref --verify --quiet refs/heads/master; then
    base_ref=master
  elif git show-ref --verify --quiet refs/heads/main; then
    base_ref=main
  else
    echo "Replay needs --fork-point (no local master or main branch to use as default)." >&2
    exit 1
  fi
  head_sha="$(git rev-parse HEAD)"
  master_sha="$(git rev-parse "${base_ref}^{commit}")"
  target_exists=false
  git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH" && target_exists=true
  if ! $target_exists; then
    FORK_POINT="$base_ref"
    echo "Default --fork-point $FORK_POINT ($TARGET_BRANCH does not exist yet)." >&2
  else
    target_sha="$(git rev-parse "$TARGET_BRANCH^{commit}")"
    if [[ "$head_sha" == "$master_sha" ]] || [[ "$head_sha" == "$target_sha" ]]; then
      FORK_POINT="$base_ref"
      echo "Default --fork-point $FORK_POINT (HEAD is ${base_ref} or $TARGET_BRANCH)." >&2
    else
      FORK_POINT="$base_ref"
      echo "Default --fork-point $FORK_POINT ($TARGET_BRANCH exists: incremental replay without --force, or --force to rebuild from ${base_ref})." >&2
    fi
  fi
fi

# When --source is omitted in replay mode: prefer submodulized (gitlink tip) for replaying into unsubmodulized.
if $REPLAY && ! $REPLAY_SOURCE_EXPLICIT; then
  if git show-ref --verify --quiet refs/heads/submodulized; then
    SOURCE_BRANCH=submodulized
  elif git show-ref --verify --quiet "refs/heads/unsubmodulized"; then
    SOURCE_BRANCH=unsubmodulized
  elif git show-ref --verify --quiet refs/heads/master; then
    SOURCE_BRANCH=master
  elif git show-ref --verify --quiet refs/heads/main; then
    SOURCE_BRANCH=main
  else
    echo "Replay: pass --source BR (no local submodulized, unsubmodulized, master, or main branch found)." >&2
    exit 1
  fi
  echo "Default --source $SOURCE_BRANCH" >&2
fi

disable_sparse_checkout_if_needed() {
  $DRY_RUN && return 0
  local active=
  [[ -f .git/info/sparse-checkout ]] && active=1
  [[ "$(git config --bool core.sparseCheckout 2>/dev/null)" == "true" ]] && active=1
  [[ "$(git config --bool index.sparse 2>/dev/null)" == "true" ]] && active=1
  if [[ -z "$active" ]] && command -v git >/dev/null; then
    local listed
    listed="$(git sparse-checkout list 2>/dev/null | head -n 1 || true)"
    [[ -n "${listed// }" ]] && active=1
  fi
  [[ -z "$active" ]] && return 0
  echo "Disabling sparse-checkout so plugin paths can be vendored." >&2
  git sparse-checkout disable 2>/dev/null || true
  git config core.sparseCheckout false 2>/dev/null || true
  git config --unset-all core.sparseCheckoutCone 2>/dev/null || true
  git config index.sparse false 2>/dev/null || true
  rm -f .git/info/sparse-checkout
}

disable_sparse_checkout_if_needed

# Extra -c flags so clone honors GitHub PAT (superproject local url.insteadOf is not always used here).
git_github_pat_c=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  git_github_pat_c+=(-c "url.https://${GITHUB_TOKEN}@github.com/.insteadOf=https://github.com/")
fi

rewrite_github_url_to_ssh() {
  local u="$1"
  if $USE_SSH && [[ "$u" == https://github.com/* ]]; then
    printf '%s\n' "git@github.com:${u#https://github.com/}"
  else
    printf '%s\n' "$u"
  fi
}

unsubmodulize_replay_mode() {
  git rev-parse --verify "$FORK_POINT^{commit}" >/dev/null
  git rev-parse --verify "$SOURCE_BRANCH^{commit}" >/dev/null

  ls_path_mode_sha() {
    local commit="$1" path="$2"
    git ls-tree "$commit" -- "$path" 2>/dev/null | awk '{print $1 "\t" $3}' | head -n1
  }

  plugin_base_override_for() {
    local want="$1"
    local entry
    for entry in "${PLUGIN_BASE_OVERRIDES[@]:-}"; do
      if [[ "${entry%%=*}" == "$want" ]]; then
        printf '%s\n' "${entry#*=}"
        return 0
      fi
    done
    return 1
  }

  declare -a M_PATHS=()
  declare -a M_URLS=()
  declare -a M_BRANCHES=()
  declare -a M_SPARSE=()
  declare -a M_TREE=()

  while IFS='|' read -r raw_path raw_url raw_branch raw_sparse raw_tree || [[ -n "${raw_path:-}" ]]; do
    path="${raw_path#"${raw_path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"
    url="${raw_url#"${raw_url%%[![:space:]]*}"}"
    url="${url%"${url##*[![:space:]]}"}"
    branch="${raw_branch#"${raw_branch%%[![:space:]]*}"}"
    branch="${branch%"${branch##*[![:space:]]}"}"
    sparse="$(submodulizer_trim "${raw_sparse:-}")"
    tree="$(submodulizer_trim "${raw_tree:-}")"
    [[ -z "$path" || "$path" =~ ^# ]] && continue
    [[ -z "$url" ]] && { echo "Manifest: missing URL for path $path" >&2; exit 1; }
    [[ -z "$branch" ]] && branch="main"
    if [[ -n "$tree" && -z "$sparse" ]]; then
      echo "Manifest: in-repo tree path (5th field) requires sparse paths (4th field): $path" >&2
      exit 1
    fi
    if [[ -z "$tree" && -n "$sparse" ]]; then
      tree="$(submodulizer_sparse_default_tree_path "$sparse")"
    fi
    M_PATHS+=("$path")
    M_URLS+=("$url")
    M_BRANCHES+=("$branch")
    M_SPARSE+=("$sparse")
    M_TREE+=("$tree")
  done < "$MANIFEST"

  if [[ ${#M_PATHS[@]} -eq 0 ]]; then
    echo "No manifest entries." >&2
    exit 1
  fi

  SOURCE_TIP="$(git rev-parse "$SOURCE_BRANCH^{commit}")"

  INCREMENTAL=false
  FROM_REF="$FORK_POINT"
  if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH" && ! $FORCE_REPLAY; then
    INCREMENTAL=true
    FROM_REF="$(git rev-parse "$TARGET_BRANCH^{commit}")"
    for _xi in "${!M_PATHS[@]}"; do
      _xp="${M_PATHS[_xi]}"
      _ms="$(ls_path_mode_sha "$FROM_REF" "$_xp")"
      _mode="${_ms%%$'\t'*}"
      if [[ "$_mode" != "040000" ]]; then
        echo "unsubmodulize: $TARGET_BRANCH at $_xp is not a vendored directory (tree mode $_mode)." >&2
        echo "  Use --force to delete $TARGET_BRANCH and rebuild from --fork-point $FORK_POINT." >&2
        exit 1
      fi
    done
    echo "unsubmodulize: incremental update of $TARGET_BRANCH from $(git rev-parse --short "$FROM_REF") toward $SOURCE_BRANCH." >&2
  fi

  TMPD="$(mktemp -d "${TMPDIR:-/tmp}/unsub-replay.XXXXXX")"
  trap 'rm -rf "$TMPD"' EXIT

  declare -a EVENT_LINES=()

  for i in "${!M_PATHS[@]}"; do
    P="${M_PATHS[$i]}"
    URL="${M_URLS[$i]}"
    URL="$(rewrite_github_url_to_ssh "$URL")"

    ms="$(ls_path_mode_sha "$FROM_REF" "$P")"
    mode="${ms%%$'\t'*}"
    from_sha="${ms#*$'\t'}"

    ms2="$(ls_path_mode_sha "$SOURCE_TIP" "$P")"
    mode2="${ms2%%$'\t'*}"
    to_sha="${ms2#*$'\t'}"

    PDIR="$TMPD/plugin_${i}_$(echo "$P" | tr '/' '_')"
    if [[ ! -d "$PDIR/.git" ]]; then
      GIT_TERMINAL_PROMPT=0 git "${git_github_pat_c[@]}" clone --bare "$URL" "$PDIR"
    fi

    GIT_TERMINAL_PROMPT=0 git -C "$PDIR" fetch -q origin 2>/dev/null || true
    GIT_TERMINAL_PROMPT=0 git -C "$PDIR" fetch -q "$URL" "+refs/*:refs/remotes/import/*" 2>/dev/null || true

    if [[ "$mode2" == "160000" && -n "$to_sha" ]]; then
      :
    elif [[ "$mode2" == "040000" ]]; then
      tr_end="$(git rev-parse "$SOURCE_TIP:$P" 2>/dev/null || true)"
      if [[ -z "$tr_end" ]]; then
        echo "No tree at $SOURCE_BRANCH:$P (source tip)" >&2
        exit 1
      fi
      to_sha="$(submodulizer_find_plugin_commit_for_tree "$PDIR" "$tr_end" "${M_TREE[$i]}")" || {
        echo "Could not match plugin commit to vendored tree at $SOURCE_BRANCH:$P" >&2
        exit 1
      }
    else
      echo "Path $P at $SOURCE_BRANCH tip must be gitlink or vendored directory — cannot determine end SHA" >&2
      exit 1
    fi

    if plugin_base_override_for "$P" >/dev/null; then
      from_sha="$(plugin_base_override_for "$P")"
    elif [[ "$mode" == "160000" && -n "$from_sha" ]]; then
      :
    elif [[ "$mode" == "040000" ]]; then
      tr_sha="$(git rev-parse "$FROM_REF:$P" 2>/dev/null || true)"
      if [[ -z "$tr_sha" ]]; then
        echo "No tree at $FROM_REF:$P" >&2
        exit 1
      fi
      from_sha="$(submodulizer_find_plugin_commit_for_tree "$PDIR" "$tr_sha" "${M_TREE[$i]}")" || {
        echo "Could not find plugin commit matching tree at $FROM_REF:$P" >&2
        exit 1
      }
    else
      echo "Path $P at replay base $FROM_REF must be gitlink or vendored directory; use --plugin-base ${P}=SHA" >&2
      exit 1
    fi

    if ! GIT_TERMINAL_PROMPT=0 git -C "$PDIR" cat-file -e "${from_sha}^{commit}" 2>/dev/null; then
      echo "Plugin object $from_sha not found for path $P (fetch the remote?)" >&2
      exit 1
    fi
    if ! GIT_TERMINAL_PROMPT=0 git -C "$PDIR" cat-file -e "${to_sha}^{commit}" 2>/dev/null; then
      echo "Plugin object $to_sha not found for path $P" >&2
      exit 1
    fi

    mapfile -t PCOMMITS < <(GIT_TERMINAL_PROMPT=0 git -C "$PDIR" rev-list --first-parent --reverse "${from_sha}..${to_sha}")

    if [[ ${#PCOMMITS[@]} -eq 0 ]]; then
      echo "No plugin commits in range ${from_sha}..${to_sha} for $P (already at tip?)" >&2
      continue
    fi

    for c in "${PCOMMITS[@]}"; do
      ct="$(git -C "$PDIR" show -s --format=%ct "$c")"
      EVENT_LINES+=("${ct}"$'\t'"${P}"$'\t'"${c}"$'\t'"${PDIR}"$'\t'"${M_TREE[$i]}")
    done
  done

  if [[ ${#EVENT_LINES[@]} -eq 0 ]]; then
    echo "No plugin commits to replay." >&2
    if $DRY_RUN; then
      if $INCREMENTAL; then
        echo "Planned: no new commits ($TARGET_BRANCH already matches $SOURCE_BRANCH submodule tips)." >&2
      else
        echo "Planned: branch $TARGET_BRANCH at $FORK_POINT (fork already matches submodule plugin SHAs)" >&2
      fi
      exit 0
    fi
    if $INCREMENTAL; then
      echo "Branch $TARGET_BRANCH is already up to date with $SOURCE_BRANCH." >&2
      exit 0
    fi
    if $FORCE_REPLAY && git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
      git branch -D "$TARGET_BRANCH" 2>/dev/null || true
    fi
    git branch "$TARGET_BRANCH" "$FORK_POINT"
    echo "Done. Branch $TARGET_BRANCH -> $(git rev-parse "$TARGET_BRANCH")"
    exit 0
  fi

  IFS=$'\n'
  sorted="$(printf '%s\n' "${EVENT_LINES[@]}" | LC_ALL=C sort -t $'\t' -k1,1n -k2,2 -k3,3)"
  unset IFS

  if $DRY_RUN; then
    if $INCREMENTAL; then
      echo "Planned ${#EVENT_LINES[@]} incremental commit(s) on $TARGET_BRANCH ($(git rev-parse --short "$FROM_REF") → $SOURCE_BRANCH)" >&2
    else
      echo "Planned ${#EVENT_LINES[@]} commits on $TARGET_BRANCH (from $FORK_POINT)" >&2
    fi
    while IFS=$'\t' read -r ct p sha pdir _tree; do
      [[ -z "${ct:-}" ]] && continue
      echo "  $ct  $p  $sha  ($(git -C "$pdir" show -s --format=%s "$sha"))"
    done <<< "$sorted"
    exit 0
  fi

  if $FORCE_REPLAY && git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
    git branch -D "$TARGET_BRANCH" 2>/dev/null || true
  fi
  git worktree prune 2>/dev/null || true

  WT="$TMPD/wt"
  rm -rf "$WT"
  REPLAY_ROOT="$FORK_POINT"
  REPLAY_ROOT_REV="$(git rev-parse "$FORK_POINT^{commit}")"
  if $INCREMENTAL; then
    REPLAY_ROOT="$FROM_REF"
    REPLAY_ROOT_REV="$(git rev-parse "$FROM_REF^{commit}")"
  fi

  materialize_commit_at() {
    local commit="$1" dest="$2"
    rm -rf "${dest:?}/"*
    mkdir -p "$dest"
    git archive --format=tar "$commit" | tar -x -C "$dest"
    local _i _P _ms _mode _sha _PDIR
    for _i in "${!M_PATHS[@]}"; do
      _P="${M_PATHS[$_i]}"
      _ms="$(ls_path_mode_sha "$commit" "$_P")"
      _mode="${_ms%%$'\t'*}"
      _sha="${_ms#*$'\t'}"
      if [[ "$_mode" == "160000" && -n "$_sha" ]]; then
        _PDIR="$TMPD/plugin_${_i}_$(echo "$_P" | tr '/' '_')"
        rm -rf "$dest/$_P"
        mkdir -p "$dest/$_P"
        submodulizer_git_archive_to_dir "$_PDIR" "$_sha" "${M_TREE[$_i]}" "$dest/$_P"
      fi
    done
    rm -f "$dest/.gitmodules"
  }

  fill_worktree_from_parent() {
    local parent="$1" dest="$2"
    if [[ "$(git rev-parse "$parent^{commit}")" == "$REPLAY_ROOT_REV" ]]; then
      materialize_commit_at "$REPLAY_ROOT" "$dest"
    else
      rm -rf "${dest:?}/"*
      mkdir -p "$dest"
      git archive --format=tar "$parent" | tar -x -C "$dest"
    fi
  }

  if $INCREMENTAL; then
    GIT_TERMINAL_PROMPT=0 git "${git_github_pat_c[@]}" worktree add -f "$WT" "$TARGET_BRANCH"
  else
    GIT_TERMINAL_PROMPT=0 git "${git_github_pat_c[@]}" worktree add -B "$TARGET_BRANCH" "$WT" "$FORK_POINT" --force
  fi

  while IFS=$'\t' read -r ct P csha pdir in_tree; do
    [[ -z "${ct:-}" ]] && continue
    cur="$(git -C "$WT" rev-parse HEAD)"
    fill_worktree_from_parent "$cur" "$WT"
    rm -rf "${WT:?}/${P}"
    mkdir -p "${WT}/${P}"
    submodulizer_git_archive_to_dir "$pdir" "$csha" "$in_tree" "${WT}/${P}"
    rm -f "$WT/.gitmodules"

    an="$(git -C "$pdir" show -s --format=%an "$csha")"
    ae="$(git -C "$pdir" show -s --format=%ae "$csha")"
    adate="$(git -C "$pdir" show -s --format=%ai "$csha")"
    body="$(git -C "$pdir" show -s --format=%B "$csha")"
    {
      printf '%s\n\n' "$body"
      printf 'Replayed-from: %s\n' "$csha"
      printf 'Plugin-path: %s\n' "$P"
    } >"$TMPD/commitmsg.txt"

    git -C "$WT" add -A
    GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" GIT_AUTHOR_DATE="$adate" \
      GIT_COMMITTER_NAME="$an" GIT_COMMITTER_EMAIL="$ae" GIT_COMMITTER_DATE="$adate" \
      git -C "$WT" commit -F "$TMPD/commitmsg.txt"
  done <<< "$sorted"

  git -C "$REPO_ROOT" worktree remove -f "$WT" 2>/dev/null || true
  echo "Done. Branch $TARGET_BRANCH -> $(git rev-parse "$TARGET_BRANCH")"
}

if $REPLAY; then
  unsubmodulize_replay_mode
  exit 0
fi

manifest_entries=0
while IFS='|' read -r raw_path raw_url raw_branch raw_sparse raw_tree || [[ -n "${raw_path:-}" ]]; do
  path="${raw_path#"${raw_path%%[![:space:]]*}"}"
  path="${path%"${path##*[![:space:]]}"}"
  url="${raw_url#"${raw_url%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"
  branch="${raw_branch#"${raw_branch%%[![:space:]]*}"}"
  branch="${branch%"${branch##*[![:space:]]}"}"
  sparse="$(submodulizer_trim "${raw_sparse:-}")"
  tree="$(submodulizer_trim "${raw_tree:-}")"

  [[ -z "$path" || "$path" =~ ^# ]] && continue
  [[ -z "$url" ]] && { echo "Manifest: missing URL for path $path" >&2; exit 1; }
  [[ -z "$branch" ]] && branch="main"
  if [[ -n "$tree" && -z "$sparse" ]]; then
    echo "Manifest: in-repo tree path (5th field) requires sparse paths (4th field): $path" >&2
    exit 1
  fi
  if [[ -z "$tree" && -n "$sparse" ]]; then
    tree="$(submodulizer_sparse_default_tree_path "$sparse")"
  fi
  url="$(rewrite_github_url_to_ssh "$url")"

  ((++manifest_entries)) || true

  if [[ ! -f .gitmodules ]] || ! git config -f .gitmodules --get-regexp path 2>/dev/null | awk '{print $2}' | grep -Fxq "$path"; then
    echo "Not listed as submodule in .gitmodules: $path — skipping (already vendored or unknown)"
    continue
  fi

  if ! $DRY_RUN; then
    if [[ -d "$path" ]] && (cd "$path" && git status --porcelain 2>/dev/null | grep -q .); then
      echo "Submodule $path has local changes — commit/push inside submodule or stash first." >&2
      exit 1
    fi
  fi

  echo "Unsubmodulizing: $path (from $url @ $branch)${sparse:+ sparse=$sparse}"

  if $DRY_RUN; then
    printf '[dry-run] would: clone %s @ %s → %s, deinit submodule, rm .git, git add\n' "$url" "$branch" "$path"
    continue
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/unsubmodulize.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  if [[ -n "$branch" ]] && GIT_TERMINAL_PROMPT=0 git "${git_github_pat_c[@]}" ls-remote --heads "$url" "refs/heads/$branch" 2>/dev/null | grep -q .; then
    GIT_TERMINAL_PROMPT=0 git "${git_github_pat_c[@]}" clone --depth 1 -b "$branch" -- "$url" "$tmp/clone"
  else
    [[ -n "$branch" ]] && echo "Remote has no branch '$branch' for $path; cloning default branch." >&2
    GIT_TERMINAL_PROMPT=0 git "${git_github_pat_c[@]}" clone --depth 1 -- "$url" "$tmp/clone"
  fi
  if [[ -n "$sparse" ]]; then
    submodulizer_sparse_apply_in_worktree "$tmp" "clone" "$sparse" || exit 1
  fi
  git submodule deinit -f -- "$path"
  git rm -f --sparse -- "$path" 2>/dev/null || git rm -f -- "$path"
  mod_gitdir="$(git rev-parse --git-path "modules/$path")"
  if [[ -n "$mod_gitdir" && -e "$mod_gitdir" ]]; then
    rm -rf -- "$mod_gitdir"
  fi
  parent="$(dirname "$path")"
  [[ "$parent" != "." ]] && mkdir -p "$parent"
  rm -rf -- "$path"
  mkdir -p "$path"
  head_sha="$(git -C "$tmp/clone" rev-parse HEAD)"
  submodulizer_git_archive_to_dir "$tmp/clone" "$head_sha" "$tree" "$path"
  rm -rf -- "$path/.git"
  trap - EXIT
  rm -rf "$tmp"

  git -c core.sparseCheckout=false -c index.sparse=false add -- "$path"
done < "$MANIFEST"

if [[ "$manifest_entries" -eq 0 ]]; then
  echo "No entries in manifest." >&2
  exit 1
fi

if $DRY_RUN; then
  echo "Dry run complete."
  exit 0
fi

if ! $NO_COMMIT; then
  if git diff --cached --quiet 2>/dev/null; then
    echo "Nothing staged; skipping commit."
  else
    git commit -m "chore: vendor plugin trees (remove submodules per manifest)"
  fi
fi

echo "Done. Plugin directories are plain files (dirty / upstream Moodle style)."
