#!/usr/bin/env bash
# Convert vendored plugin directories (plain files in the Moodle superproject) into git submodules.
# Intended for the submodule-layout Moodle checkout: keep plugin-submodules.manifest at the superproject
# root (same repo as .gitmodules will live in). Run from inside that clone, or pass ROOT / --repo.
# Default mode is replay: builds branch submodulized with one superproject commit per plugin-repo commit.
# Use --no-replay for one-shot conversion (manifest loop only). When submodulized and unsubmodulized both
# exist and unsub is ahead of merge-base(unsub, sub), the one-shot path also replays those commits onto gitlinks.
#
# Requires: git, a clean enough working tree (commit or stash first if paths are dirty).
#
# Usage:
#   ./cleandev/submodulize.sh [ROOT] [--dry-run] [--no-commit] [--ssh] [--manifest PATH] [--repo ROOT]
#   ./cleandev/submodulize.sh --fork-point BASE ...   # replay (default)
#   ./cleandev/submodulize.sh --no-replay ...         # one-shot
#   Bare ROOT is the same as --repo (optional; may appear before or after flags).
#
# Private GitHub repos over HTTPS need credentials. Set GITHUB_TOKEN (PAT) so HTTPS URLs are rewritten
# for ls-remote / submodule add (parent repo url.insteadOf is not always applied to submodule clone).
# Or use --ssh. In Docker with no TTY you see: "could not read Username for 'https://github.com'".
#
# Requires bash (arrays, pipefail). Do not run as `sh this-script.sh`; use `bash` or execute directly.

if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s: requires bash, not sh. Example: bash "%s" ./ ...your args...\n' "${0##*/}" "$0" >&2
  exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Sorted path/blob (and submodule target) lines — ignores file mode so Windows
# vendoring (100644 vs 100755 for the same blob) still matches upstream commits.
submodulizer_tree_path_object_fingerprint() {
  local repo="$1" tree="$2"
  git -C "$repo" ls-tree -r "$tree" 2>/dev/null \
    | awk '$2 == "blob" || $2 == "commit" { print $3 "\t" $4 }' \
    | LC_ALL=C sort
}

submodulizer_find_plugin_commit_for_tree() {
  local pdir="$1" want_tree="$2" in_path="${3:-}"
  local want_repo="${4:-}"
  local c t t2 want_fp tr_fp
  if [[ -n "$(submodulizer_trim "${want_repo:-}")" ]] && git -C "$want_repo" cat-file -e "$want_tree" 2>/dev/null; then
    want_fp="$(submodulizer_tree_path_object_fingerprint "$want_repo" "$want_tree")" || want_fp=""
  else
    want_fp=""
  fi
  while IFS= read -r c; do
    if [[ -z "$(submodulizer_trim "${in_path:-}")" ]]; then
      t="$(submodulizer_plugin_tree_at_commit "$pdir" "$c" "")" || continue
      [[ "$t" == "$want_tree" ]] && { printf '%s\n' "$c"; return 0; }
      if [[ -n "$want_fp" ]]; then
        tr_fp="$(submodulizer_tree_path_object_fingerprint "$pdir" "$t")" || continue
        [[ "$tr_fp" == "$want_fp" ]] && { printf '%s\n' "$c"; return 0; }
      fi
    else
      if t="$(submodulizer_plugin_tree_at_commit "$pdir" "$c" "$in_path")" 2>/dev/null; then
        [[ "$t" == "$want_tree" ]] && { printf '%s\n' "$c"; return 0; }
        if [[ -n "$want_fp" ]]; then
          tr_fp="$(submodulizer_tree_path_object_fingerprint "$pdir" "$t")" || continue
          [[ "$tr_fp" == "$want_fp" ]] && { printf '%s\n' "$c"; return 0; }
        fi
      fi
      t2="$(submodulizer_plugin_tree_at_commit "$pdir" "$c" "")" || continue
      [[ "$t2" == "$want_tree" ]] && { printf '%s\n' "$c"; return 0; }
      if [[ -n "$want_fp" ]]; then
        tr_fp="$(submodulizer_tree_path_object_fingerprint "$pdir" "$t2")" || continue
        [[ "$tr_fp" == "$want_fp" ]] && { printf '%s\n' "$c"; return 0; }
      fi
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

MANIFEST=""
MANIFEST_EXPLICIT=false
DRY_RUN=false
NO_COMMIT=false
USE_SSH=false
REPO_ROOT=""
REPLAY=true
FORK_POINT=""
SOURCE_BRANCH=""
TARGET_BRANCH="submodulized"
REPLAY_ORDER="chronological"
FORCE_REPLAY=false
REPLAY_SOURCE_EXPLICIT=false
REPLAY_TARGET_EXPLICIT=false
REPLAY_ORDER_EXPLICIT=false
FORK_POINT_EXPLICIT=false
BOOTSTRAP=false
BOOTSTRAP_EXPLICIT=false
SYNC_UNSUB=false
NO_SYNC_FROM_UNSUB=false
declare -a PLUGIN_BASE_OVERRIDES=()

usage() {
  cat <<'EOF'
Convert vendored plugin directories in the Moodle superproject into git submodules (cleandev-style).
The manifest lists paths and clone URLs; it normally lives in the superproject root as
plugin-submodules.manifest (not under cleandev/). Moodle root defaults to the current directory’s
git superproject (git rev-parse --show-toplevel), unless you set it explicitly.

Usage:
  submodulize.sh [ROOT] [OPTIONS...]
  submodulize.sh [OPTIONS...] [ROOT]

  ROOT — optional path to the Moodle git checkout. Give it as a single bare argument (no leading -),
         anywhere among the flags; same meaning as --repo. Only one repo path: do not pass a second
         bare path, and do not put a bare path after --repo (that is rejected).

Examples:
  submodulize.sh --no-replay ~/workspace/moodle
  submodulize.sh ./ --bootstrap
  submodulize.sh ./   # same as --bootstrap when submodulized branch does not exist yet
  submodulize.sh --dry-run --no-replay ~/workspace/moodle
  submodulize.sh --fork-point abc123 --source submodulized
  submodulize.sh ./   # when unsubmodulized is ahead of merge-base(sub,unsub), syncs onto submodulized automatically
  submodulize.sh --no-sync-from-unsub ./   # manifest one-shot only; skip unsub → submodulized replay

Options:
  --dry-run       Print actions without changing the repo
  --no-commit     Stage submodule changes but do not commit (bootstrap still commits the submodule layout so unsub replay can run)
  --ssh           Use git@github.com URLs for github.com HTTPS entries
  --manifest PATH Plugin manifest (default: ROOT/plugin-submodules.manifest). Optional fields: path|url|branch|sparse_paths|in_repo_tree_path (see README). If that file sits at the repo root, one-shot/bootstrap also stages it on the submodule branch so master/unsubmodulized can keep it untracked.
  --repo ROOT     Moodle git root (explicit form of a bare ROOT; overrides an earlier bare ROOT; a bare path after --repo is an error)

Bootstrap (from vendored tree + manifest → submodulized + unsubmodulized):
  --bootstrap           Add submodules on branch submodulized, then run unsubmodulize replay to create unsubmodulized.
                        If local branch submodulized is missing, this runs automatically (same as passing --bootstrap).

Replay (default — one superproject commit per plugin-repo commit on --target):
  --no-replay           One-shot mode: add submodules per manifest (no branch replay)
  --replay              Replay mode (default; explicit if you toggled --no-replay earlier on the command line)
  --fork-point BASE     Start of replay (default: local master, else main, when omitted — see docs)
  --source BR           End state per path (gitlinks and/or vendored trees; default: submodulized, else master, else main)
  --target BR           Branch to create/update (default: submodulized)
  --order NAME          Only chronological
  --force               Replay: delete and rebuild --target from --fork-point. Omit when --target exists to only apply manifest changes (new paths → submodule add).
  --plugin-base P=S     Optional start SHA for manifest path P
  --sync-unsub          Force the unsub→submodulized sync step (even if merge-base already equals unsub tip). Normally automatic when both branches exist and unsub is ahead.
  --no-sync-from-unsub  After manifest one-shot: do not replay unsubmodulized onto submodulized (overrides automatic sync).

Requires: git, and a clean enough working tree (commit or stash if plugin paths are dirty).

Private GitHub over HTTPS: set GITHUB_TOKEN (PAT) so ls-remote / submodule add can authenticate,
or use --ssh. Without credentials in non-interactive environments you may see:
  could not read Username for 'https://github.com'
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --no-commit) NO_COMMIT=true; shift ;;
    --ssh) USE_SSH=true; shift ;;
    --no-replay) REPLAY=false; shift ;;
    --replay) REPLAY=true; shift ;;
    --bootstrap)
      BOOTSTRAP=true
      BOOTSTRAP_EXPLICIT=true
      REPLAY=false
      shift
      ;;
    --fork-point)
      FORK_POINT="${2:?}"
      FORK_POINT_EXPLICIT=true
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
    --sync-unsub)
      SYNC_UNSUB=true
      REPLAY=false
      shift
      ;;
    --no-sync-from-unsub)
      NO_SYNC_FROM_UNSUB=true
      shift
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
  if $MANIFEST_EXPLICIT; then
    echo "Manifest not found: $MANIFEST" >&2
    exit 1
  elif $SYNC_UNSUB; then
    :
  elif git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/submodulized 2>/dev/null \
    && git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/unsubmodulized 2>/dev/null; then
    :
  else
    echo "Manifest not found: $MANIFEST" >&2
    exit 1
  fi
fi

if $SYNC_UNSUB; then
  $BOOTSTRAP_EXPLICIT && {
    echo "Do not combine --sync-unsub with --bootstrap." >&2
    exit 1
  }
  $FORK_POINT_EXPLICIT && {
    echo "Do not combine --sync-unsub with --fork-point." >&2
    exit 1
  }
  $REPLAY_SOURCE_EXPLICIT && {
    echo "Do not combine --sync-unsub with --source." >&2
    exit 1
  }
  $REPLAY_TARGET_EXPLICIT && {
    echo "Do not combine --sync-unsub with --target." >&2
    exit 1
  }
  $REPLAY_ORDER_EXPLICIT && {
    echo "Do not combine --sync-unsub with --order." >&2
    exit 1
  }
  ((${#PLUGIN_BASE_OVERRIDES[@]} == 0)) || {
    echo "--plugin-base is not used with --sync-unsub." >&2
    exit 1
  }
  $FORCE_REPLAY && {
    echo "--force is not used with --sync-unsub." >&2
    exit 1
  }
  $NO_COMMIT && {
    echo "--sync-unsub requires commits on $TARGET_BRANCH (omit --no-commit)." >&2
    exit 1
  }
fi

if $NO_SYNC_FROM_UNSUB && $SYNC_UNSUB; then
  echo "Do not combine --sync-unsub with --no-sync-from-unsub." >&2
  exit 1
fi

if $BOOTSTRAP_EXPLICIT; then
  $FORK_POINT_EXPLICIT && {
    echo "Do not combine --bootstrap with --fork-point (bootstrap records the current commit as the fork)." >&2
    exit 1
  }
  $REPLAY_SOURCE_EXPLICIT && {
    echo "Do not combine --bootstrap with --source (bootstrap uses submodulized → unsubmodulized)." >&2
    exit 1
  }
  $REPLAY_TARGET_EXPLICIT && {
    echo "Do not combine --bootstrap with --target." >&2
    exit 1
  }
  $REPLAY_ORDER_EXPLICIT && {
    echo "Do not combine --bootstrap with --order." >&2
    exit 1
  }
  ((${#PLUGIN_BASE_OVERRIDES[@]} == 0)) || {
    echo "--plugin-base is not used with --bootstrap." >&2
    exit 1
  }
fi

cd "$REPO_ROOT"

if $SYNC_UNSUB; then
  git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH" || {
    echo "submodulize --sync-unsub: branch $TARGET_BRANCH does not exist yet." >&2
    exit 1
  }
  git show-ref --verify --quiet refs/heads/unsubmodulized || {
    echo "submodulize --sync-unsub: branch unsubmodulized not found." >&2
    exit 1
  }
fi

# Greenfield: no submodulized branch yet — run bootstrap (one-shot + unsub replay) instead of sub replay.
if $REPLAY && ! $FORK_POINT_EXPLICIT && ! $BOOTSTRAP_EXPLICIT && ! git show-ref --verify --quiet refs/heads/submodulized; then
  BOOTSTRAP=true
  REPLAY=false
  echo "submodulize: no local branch submodulized — bootstrap (add submodules, then build unsubmodulized)." >&2
fi

if $REPLAY; then
  [[ "$REPLAY_ORDER" == "chronological" ]] || {
    echo "Only --order chronological is supported: $REPLAY_ORDER" >&2
    exit 1
  }
elif $BOOTSTRAP; then
  :
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
    echo "--force is only valid in replay mode or bootstrap (omit --no-replay)" >&2
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

# When --fork-point is omitted in replay mode, default to local master (else main) if safe.
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
      echo "Default --fork-point $FORK_POINT (recreating $TARGET_BRANCH from ${base_ref}; use --force if the branch already exists)." >&2
    fi
  fi
fi

# When --source is omitted in replay mode: prefer submodulized, else master, else main.
if $REPLAY && ! $REPLAY_SOURCE_EXPLICIT; then
  if git show-ref --verify --quiet refs/heads/submodulized; then
    SOURCE_BRANCH=submodulized
  elif git show-ref --verify --quiet refs/heads/master; then
    SOURCE_BRANCH=master
  elif git show-ref --verify --quiet refs/heads/main; then
    SOURCE_BRANCH=main
  else
    echo "Replay: pass --source BR (no local submodulized, master, or main branch found)." >&2
    exit 1
  fi
  echo "Default --source $SOURCE_BRANCH" >&2
fi

# Moodle dev images often use sparse-checkout (cone, index.sparse, or only .git/info/sparse-checkout).
# If any of that is active, git rm / submodule add can refuse paths "outside" the cone.
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
  echo "Disabling sparse-checkout so plugin paths can be converted to submodules." >&2
  git sparse-checkout disable 2>/dev/null || true
  git config core.sparseCheckout false 2>/dev/null || true
  git config --unset-all core.sparseCheckoutCone 2>/dev/null || true
  git config index.sparse false 2>/dev/null || true
  rm -f .git/info/sparse-checkout
}

disable_sparse_checkout_if_needed

# Extra -c flags so submodule clone honors GitHub PAT (superproject local config is skipped by some git versions).
git_github_pat_c=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  git_github_pat_c+=(-c "url.https://${GITHUB_TOKEN}@github.com/.insteadOf=https://github.com/")
fi

# github.com HTTPS → SSH (git@github.com:org/repo.git) when --ssh is set.
rewrite_github_url_to_ssh() {
  local u="$1"
  if $USE_SSH && [[ "$u" == https://github.com/* ]]; then
    printf '%s\n' "git@github.com:${u#https://github.com/}"
  else
    printf '%s\n' "$u"
  fi
}

# Parent index only has gitlinks; files inside each plugin dir are the submodule checkout (not parent blobs).
# checkout to a vendored branch would replace those dirs unless submodule working trees are cleared first.
submodulize_hint_switch_from_submodule_branch() {
  cat <<'EOF' >&2
To switch to a branch with vendored plugin files (not gitlinks), clear submodule checkouts first, then checkout:
  git submodule deinit -f --all
  git checkout master   # or main / unsubmodulized
If plugin-submodules.manifest was only committed on submodulized, copy it back in after checkout (keep it untracked on vendored branches).
EOF
}

# Commit root plugin-submodules.manifest on the submodule branch only (vendored branches can keep a local untracked copy).
submodulize_stage_root_manifest() {
  [[ -f "$MANIFEST" ]] || return 0
  [[ "$(basename -- "$MANIFEST")" == "plugin-submodules.manifest" ]] || return 0
  local rtop mtop
  rtop="$(cd "$REPO_ROOT" && pwd -P 2>/dev/null)" || return 0
  mtop="$(cd "$(dirname -- "$MANIFEST")" && pwd -P 2>/dev/null)" || return 0
  [[ "$mtop" == "$rtop" ]] || return 0
  if $DRY_RUN; then
    printf '[dry-run] git add %q\n' "$MANIFEST"
    return 0
  fi
  if git check-ignore -q -- "$MANIFEST" 2>/dev/null; then
    git add -f -- "$MANIFEST" || true
  else
    git add -- "$MANIFEST" || true
  fi
}

# Replay commits on unsubmodulized (since merge-base with TARGET_BRANCH) onto TARGET_BRANCH: each commit
# may only touch paths under plugin-submodules.manifest roots. Plugin trees must match an existing plugin
# commit, or we create commits on branch unsubmodulized_sync in the plugin repo (from manifest upstream
# branch, then chained) and push origin.
submodulize_sync_from_unsubmodulized() {
  if $DRY_RUN; then
    echo "submodulize: sync from unsubmodulized — dry-run not supported; skipping." >&2
    return 0
  fi
  local UNSUB_BRANCH=unsubmodulized
  local active_br
  active_br="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
  if [[ "$active_br" != "$TARGET_BRANCH" ]]; then
    echo "submodulize: checking out $TARGET_BRANCH (sync from unsubmodulized)" >&2
    git checkout "$TARGET_BRANCH"
  fi
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    echo "submodulize: sync from unsubmodulized — working tree or index is dirty; commit or stash first." >&2
    exit 1
  fi

  declare -a S_PATHS=() S_URLS=() S_BRANCHES=() S_SPARSE=() S_TREE=()
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
    S_PATHS+=("$path")
    S_URLS+=("$(rewrite_github_url_to_ssh "$url")")
    S_BRANCHES+=("$branch")
    S_SPARSE+=("$sparse")
    S_TREE+=("$tree")
  done < "$MANIFEST"

  ((${#S_PATHS[@]} > 0)) || { echo "No manifest entries." >&2; exit 1; }

  manifest_root_for_path() {
    local f="$1" p best=""
    for p in "${S_PATHS[@]}"; do
      if [[ "$f" == "$p" || "$f" == "$p"/* ]]; then
        [[ ${#p} -gt ${#best} ]] && best="$p"
      fi
    done
    printf '%s\n' "$best"
  }

  # Create (or extend) branch unsubmodulized_sync in the plugin bare clone from vendored tree at U:r, push to origin.
  replay_vendored_into_plugin_unsub_sync_branch() {
    local pdir="$1" upstream_br="$2" U="$3" path_r="$4" want_tree="$5"
    local wtd parent_sha sync_br=unsubmodulized_sync new_h
    rm -f "$TMPD/last_plugin_replay_sha"

    GIT_TERMINAL_PROMPT=0 git -C "$pdir" fetch -q origin 2>/dev/null || true
    if git -C "$pdir" show-ref --verify --quiet "refs/heads/$sync_br"; then
      parent_sha="$(git -C "$pdir" rev-parse "$sync_br")"
    elif git -C "$pdir" show-ref --verify --quiet "refs/remotes/origin/$sync_br"; then
      parent_sha="$(git -C "$pdir" rev-parse "refs/remotes/origin/$sync_br")"
    elif git -C "$pdir" show-ref --verify --quiet "refs/heads/$upstream_br"; then
      parent_sha="$(git -C "$pdir" rev-parse "refs/heads/$upstream_br")"
    elif git -C "$pdir" show-ref --verify --quiet "refs/remotes/origin/$upstream_br"; then
      parent_sha="$(git -C "$pdir" rev-parse "refs/remotes/origin/$upstream_br")"
    elif git -C "$pdir" show-ref --verify --quiet HEAD; then
      parent_sha="$(git -C "$pdir" rev-parse HEAD)"
    fi
    [[ -n "$parent_sha" ]] || {
      echo "submodulize: sync from unsubmodulized — could not resolve parent for $sync_br in plugin repo." >&2
      return 1
    }

    wtd="$(mktemp -d "${TMPD}/pwt.XXXXXX")"
    if ! git -C "$pdir" worktree add --detach "$wtd" "$parent_sha" >/dev/null 2>&1; then
      echo "submodulize: sync from unsubmodulized — worktree add failed for plugin replay ($path_r)." >&2
      rm -rf "$wtd"
      return 1
    fi
    find "$wtd" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
    local strip_args=()
    # Some git versions prefix archive members with $path_r/; strip to plugin-root layout.
    first_mem="$(git -C "$REPO_ROOT" archive --format=tar "$U" "$path_r" | tar -t -f - 2>/dev/null | head -1 | tr -d '\r')"
    if [[ "$first_mem" == "$path_r"/* || "$first_mem" == "$path_r" ]]; then
      sc="$(tr -cd '/' <<<"$path_r" | wc -c | tr -d ' \t')"
      strip_args=(--strip-components=$((sc + 1)))
    fi
    if ! git -C "$REPO_ROOT" archive --format=tar "$U" "$path_r" | tar -x -C "$wtd" "${strip_args[@]}"; then
      echo "submodulize: sync from unsubmodulized — git archive failed for $U:$path_r." >&2
      git -C "$pdir" worktree remove -f "$wtd" 2>/dev/null || true
      return 1
    fi
    if [[ -d "$wtd/$path_r" ]]; then
      shopt -s dotglob nullglob
      for f in "$wtd/$path_r"/*; do
        [[ -e "$f" ]] && mv "$f" "$wtd/"
      done
      shopt -u dotglob nullglob
      rm -rf "$wtd/$path_r"
    fi
    git -C "$wtd" add -A
    got_tree="$(git -C "$wtd" write-tree)"
    if [[ "$got_tree" != "$want_tree" ]]; then
      echo "submodulize: sync from unsubmodulized — replay worktree tree $got_tree does not match vendored $want_tree ($path_r)." >&2
      git -C "$pdir" worktree remove -f "$wtd" >/dev/null 2>&1 || true
      return 1
    fi
    if git -C "$wtd" diff --cached --quiet; then
      git -C "$pdir" worktree remove -f "$wtd" >/dev/null 2>&1 || true
      printf '%s\n' "$parent_sha" >"$TMPD/last_plugin_replay_sha"
      return 0
    fi

    msgf="$TMPD/replay_msg_${path_r//\//_}.$U"
    {
      git -C "$REPO_ROOT" show -s --format=%B "$U"
      printf '\nReplayed-from-unsub: %s\nPlugin-path: %s\nSync-branch: %s\n' "$U" "$path_r" "$sync_br"
    } >"$msgf"
    an="$(git -C "$REPO_ROOT" show -s --format=%an "$U")"
    ae="$(git -C "$REPO_ROOT" show -s --format=%ae "$U")"
    ad="$(git -C "$REPO_ROOT" show -s --format=%ai "$U")"
    [[ -n "$an" ]] || an="submodulize-sync"
    [[ -n "$ae" ]] || ae="submodulize-sync@localhost"
    [[ -n "$ad" ]] || ad="$(date -R)"
    if ! GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" GIT_AUTHOR_DATE="$ad" \
      GIT_COMMITTER_NAME="$an" GIT_COMMITTER_EMAIL="$ae" GIT_COMMITTER_DATE="$ad" \
      git -C "$wtd" commit -q -F "$msgf" >/dev/null 2>&1; then
      echo "submodulize: sync from unsubmodulized — plugin replay commit failed ($path_r)." >&2
      git -C "$pdir" worktree remove -f "$wtd" 2>/dev/null || true
      return 1
    fi
    new_h="$(git -C "$wtd" rev-parse HEAD)"
    [[ -n "$new_h" ]] || {
      echo "submodulize: sync from unsubmodulized — plugin replay produced no commit ($path_r)." >&2
      git -C "$pdir" worktree remove -f "$wtd" 2>/dev/null || true
      return 1
    }
    git -C "$wtd" branch -f "$sync_br" "$new_h" >/dev/null 2>&1
    if ! GIT_TERMINAL_PROMPT=0 git "${git_github_pat_c[@]}" -C "$pdir" push -u origin "$sync_br" >/dev/null 2>&1; then
      echo "submodulize: warning — push origin $sync_br failed (SSH/HTTPS or GITHUB_TOKEN). Superproject points at $new_h; push the plugin repo before others submodule-update." >&2
    fi
    git -C "$pdir" worktree remove -f "$wtd" >/dev/null 2>&1 || true
    printf '%s\n' "$new_h" >"$TMPD/last_plugin_replay_sha"
    return 0
  }

  local BASE unsub_tip TMPD i url pdir U parent_u changed fn r ms mode newsha idx new_tree cur_tree nc msgf upstream_br
  BASE="$(git merge-base "$UNSUB_BRANCH" "$TARGET_BRANCH")" || {
    echo "submodulize: sync from unsubmodulized — could not compute merge-base($UNSUB_BRANCH, $TARGET_BRANCH)." >&2
    exit 1
  }
  unsub_tip="$(git rev-parse "$UNSUB_BRANCH^{commit}")"
  if [[ "$BASE" == "$unsub_tip" ]]; then
    echo "submodulize: sync from unsubmodulized — no new commits on $UNSUB_BRANCH since merge-base." >&2
    return 0
  fi

  TMPD="$(mktemp -d "${TMPDIR:-/tmp}/sub-sync-unsub.XXXXXX")"
  declare -a PDIRS=()
  for i in "${!S_PATHS[@]}"; do
    url="${S_URLS[$i]}"
    pdir="$TMPD/plugin_${i}_$(echo "${S_PATHS[$i]}" | tr '/' '_')"
    PDIRS+=("$pdir")
    if [[ ! -d "$pdir/.git" ]]; then
      GIT_TERMINAL_PROMPT=0 git "${git_github_pat_c[@]}" clone --bare "$url" "$pdir"
    fi
    GIT_TERMINAL_PROMPT=0 git -C "$pdir" fetch -q origin 2>/dev/null || true
    GIT_TERMINAL_PROMPT=0 git -C "$pdir" fetch -q "$url" "+refs/*:refs/remotes/import/*" 2>/dev/null || true
  done

  git_write_gitmodules_from_index() {
    local gm="$TMPD/gitmodules.tmp" blob _i _p _u _line _mode _sha
    rm -f "$gm"
    for _i in "${!S_PATHS[@]}"; do
      _p="${S_PATHS[_i]}"
      _u="${S_URLS[$_i]}"
      _line="$(git ls-files --stage -- "$_p" 2>/dev/null | head -n1 || true)"
      _mode="$(awk '{print $1}' <<< "$_line")"
      _sha="$(awk '{print $2}' <<< "$_line")"
      if [[ "$_mode" == "160000" ]]; then
        printf '[submodule "%s"]\n\tpath = %s\n\turl = %s\n' "$_p" "$_p" "$_u" >>"$gm"
      fi
    done
    if [[ -f "$gm" ]]; then
      blob="$(git hash-object -w "$gm")"
      git update-index --add --cacheinfo "100644,$blob,.gitmodules"
    else
      git rm --cached -f --ignore-unmatch .gitmodules 2>/dev/null || true
    fi
  }

  while IFS= read -r U; do
    [[ -z "${U:-}" ]] && continue
    if git rev-parse --verify -q "$U^2" >/dev/null 2>&1; then
      echo "submodulize: sync from unsubmodulized — skipping merge commit $(git rev-parse --short "$U")" >&2
      continue
    fi
    parent_u="$(git rev-parse "$U^")"
    changed="$(git diff-tree --no-commit-id --name-only -r "$parent_u" "$U")"

    declare -A seen_roots=()
    while IFS= read -r fn; do
      [[ -z "${fn:-}" ]] && continue
      r="$(manifest_root_for_path "$fn")"
      if [[ -z "$r" ]]; then
        echo "submodulize: sync from unsubmodulized — commit $(git rev-parse --short "$U") touches $fn (outside manifest paths)." >&2
        exit 1
      fi
      seen_roots[$r]=1
    done <<< "$changed"

    idx="$TMPD/index.${U}"
    rm -f "$idx"
    export GIT_INDEX_FILE="$idx"
    git read-tree "$(git rev-parse HEAD)"

    for r in "${!seen_roots[@]}"; do
      newsha=""
      for j in "${!S_PATHS[@]}"; do
        [[ "${S_PATHS[$j]}" == "$r" ]] || continue
        pdir="${PDIRS[$j]}"
        ms="$(git ls-tree "$U" -- "$r" 2>/dev/null | awk '{print $1 "\t" $3}' | head -n1)"
        mode="${ms%%$'\t'*}"
        if [[ "$mode" != "040000" ]]; then
          echo "submodulize: sync from unsubmodulized — at $U path $r is not a vendored directory (mode $mode)." >&2
          exit 1
        fi
        want_tr="$(git rev-parse "$U:$r" 2>/dev/null)"
        upstream_br="${S_BRANCHES[$j]}"
        if newsha="$(submodulizer_find_plugin_commit_for_tree "$pdir" "$want_tr" "${S_TREE[$j]}" "$REPO_ROOT")"; then
          :
        elif replay_vendored_into_plugin_unsub_sync_branch "$pdir" "$upstream_br" "$U" "$r" "$want_tr"; then
          newsha="$(tr -d '\r\n' <"$TMPD/last_plugin_replay_sha")"
          echo "submodulize: sync from unsubmodulized — replayed $U:$r to plugin branch unsubmodulized_sync ($(git rev-parse --short "$newsha"))." >&2
        else
          exit 1
        fi
        break
      done
      [[ -n "$newsha" ]] || continue
      git rm -rf --cached --ignore-unmatch -q -- "$r" 2>/dev/null || true
      git update-index --add --cacheinfo "160000,$newsha,$r"
    done

    git_write_gitmodules_from_index

    new_tree="$(git write-tree)"
    cur_tree="$(git rev-parse 'HEAD^{tree}')"
    if [[ "$new_tree" == "$cur_tree" ]]; then
      echo "submodulize: sync from unsubmodulized — $(git rev-parse --short "$U") → no gitlink change (skip)" >&2
      unset GIT_INDEX_FILE
      rm -f "$idx"
      continue
    fi

    msgf="$TMPD/commitmsg.$U.txt"
    {
      git show -s --format=%B "$U"
      printf '\nSynced-from-unsub: %s\n' "$U"
    } >"$msgf"
    nc="$(git commit-tree "$new_tree" -p HEAD -F "$msgf")"
    git update-ref "refs/heads/$TARGET_BRANCH" "$nc"
    git reset --hard -q "$nc"
    echo "submodulize: sync from unsubmodulized — applied $(git rev-parse --short "$U") → $TARGET_BRANCH $(git rev-parse --short "$nc")" >&2

    unset GIT_INDEX_FILE
    rm -f "$idx"
  done < <(git rev-list --reverse "${BASE}..${UNSUB_BRANCH}")

  unset GIT_INDEX_FILE
  rm -rf "$TMPD"
}

run() {
  if $DRY_RUN; then
    printf '[dry-run] %q\n' "$@"
  else
    "$@"
  fi
}

submodulize_one_shot_apply_manifest() {
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
    url="$(rewrite_github_url_to_ssh "$url")"

    ((++manifest_entries)) || true

    if [[ -f .gitmodules ]] && git config -f .gitmodules --get-regexp path 2>/dev/null | awk '{print $2}' | grep -Fxq "$path"; then
      echo "Already a submodule (per .gitmodules): $path — skipping"
      continue
    fi

    if [[ -d "$path/.git" ]] || [[ -f "$path/.git" ]]; then
      echo "Path already looks like a nested git repo: $path" >&2
      echo "  Remove or convert it manually, or run unsubmodulize first." >&2
      exit 1
    fi

    if [[ -e "$path" ]] && ! $DRY_RUN; then
      if ! git diff --quiet -- "$path" 2>/dev/null || ! git diff --cached --quiet -- "$path" 2>/dev/null; then
        echo "Uncommitted changes under $path — commit or stash first." >&2
        exit 1
      fi
    fi

    echo "Submodulizing: $path ← $url (branch $branch)${sparse:+ (sparse: $sparse)}"

    parent="$(dirname "$path")"
    if [[ "$parent" != "." ]]; then
      run mkdir -p "$parent"
    fi

    if [[ -n "$(git ls-files -- "$path" 2>/dev/null)" ]]; then
      if $DRY_RUN; then
        printf '[dry-run] git rm -rf [--sparse] -- %q\n' "$path"
      else
        git rm -rf --sparse -- "$path" 2>/dev/null || git rm -rf -- "$path"
      fi
    elif [[ -e "$path" ]]; then
      run rm -rf -- "$path"
    fi

    if $DRY_RUN; then
      printf '[dry-run] git submodule add -f (-b %q if exists on remote, else default branch) -- %q %q\n' "$branch" "$url" "$path"
      [[ -n "$sparse" ]] && printf '[dry-run] sparse-checkout in submodule %q: %q\n' "$path" "$sparse"
    else
      submod_args=(-f)
      if [[ -n "$branch" ]] && GIT_TERMINAL_PROMPT=0 git "${git_github_pat_c[@]}" ls-remote --heads "$url" "refs/heads/$branch" 2>/dev/null | grep -q .; then
        submod_args+=(-b "$branch")
      else
        [[ -n "$branch" ]] && echo "Remote has no branch '$branch' for $path; using repository default branch." >&2
      fi
      if ! GIT_TERMINAL_PROMPT=0 git "${git_github_pat_c[@]}" -c core.sparseCheckout=false -c index.sparse=false submodule add "${submod_args[@]}" -- "$url" "$path"; then
        echo "submodulize: failed to add submodule $path ← $url" >&2
        echo "  If the repo is private: configure HTTPS credentials, or re-run with --ssh (needs GitHub SSH access)." >&2
        echo "  After a failed add you may need: git submodule deinit -f -- $path 2>/dev/null; rm -rf .git/modules/$path $path" >&2
        exit 1
      fi
      if [[ -n "$sparse" ]]; then
        submodulizer_sparse_apply_in_worktree "$REPO_ROOT" "$path" "$sparse" || exit 1
      fi
    fi
  done < "$MANIFEST"

  if [[ "$manifest_entries" -eq 0 ]]; then
    echo "No entries in manifest." >&2
    exit 1
  fi

  if $DRY_RUN; then
    echo "Dry run complete."
    submodulize_stage_root_manifest
    $BOOTSTRAP && echo "Bootstrap: would commit on submodulized, then run unsubmodulize replay (omit --dry-run)." >&2
    exit 0
  fi

  submodulize_stage_root_manifest

  if ! $NO_COMMIT; then
    if git diff --cached --quiet 2>/dev/null; then
      echo "Nothing staged; skipping commit."
    else
      git commit -m "chore: add plugin submodules per plugin-submodules.manifest"
    fi
  fi

  if $BOOTSTRAP; then
    :
  else
    echo "Done. Submodule layout is ready (clean repo)."
    submodulize_hint_switch_from_submodule_branch
  fi
}

submodulize_bootstrap_pipeline() {
  local vend_tip unsub_args
  vend_tip="$(git rev-parse HEAD)"
  echo "Bootstrap: vendored fork-point for unsub replay: $vend_tip" >&2

  if git show-ref --verify --quiet refs/heads/submodulized && ! $FORCE_REPLAY; then
    echo "Branch submodulized already exists. Use --force to replace it, delete the branch, or run without bootstrap." >&2
    exit 1
  fi
  $FORCE_REPLAY && git branch -D submodulized 2>/dev/null || true

  git checkout -B submodulized

  # Unsub replay reads commit trees on --source; submodule adds must be committed so
  # submodulized records 160000 gitlinks, not only the pre-submodule vendored tree.
  local _saved_no_commit=false
  if $NO_COMMIT; then
    _saved_no_commit=true
    echo "submodulize: bootstrap commits submodule layout on submodulized (required for unsub replay); ignoring --no-commit for this step." >&2
    NO_COMMIT=false
  fi
  submodulize_one_shot_apply_manifest
  if $_saved_no_commit; then
    NO_COMMIT=true
  fi

  if $DRY_RUN; then
    exit 0
  fi

  unsub_args=(--repo "$REPO_ROOT" --fork-point "$vend_tip" --source submodulized --target unsubmodulized)
  $FORCE_REPLAY && unsub_args+=(--force)

  bash "$SCRIPT_DIR/unsubmodulize.sh" "${unsub_args[@]}"
  echo "Bootstrap complete: submodulized (submodules) and unsubmodulized (vendored replay) are ready." >&2
  submodulize_hint_switch_from_submodule_branch
}

submodulize_replay_mode() {
  git rev-parse --verify "$FORK_POINT^{commit}" >/dev/null
  git rev-parse --verify "$SOURCE_BRANCH^{commit}" >/dev/null

  if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH" && ! $FORCE_REPLAY; then
    echo "Branch $TARGET_BRANCH exists; pass --force" >&2
    exit 1
  fi

  ls_path_mode_sha() {
    git ls-tree "$1" -- "$2" 2>/dev/null | awk '{print $1 "\t" $3}' | head -n1
  }

  plugin_base_override_for() {
    local want="$1" entry
    for entry in "${PLUGIN_BASE_OVERRIDES[@]:-}"; do
      [[ "${entry%%=*}" == "$want" ]] && { echo "${entry#*=}"; return 0; }
    done
    return 1
  }

  declare -a M_PATHS=() M_URLS=() M_BRANCHES=() M_SPARSE=() M_TREE=()

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
    [[ -z "$url" ]] && { echo "Manifest: missing URL for $path" >&2; exit 1; }
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

  [[ ${#M_PATHS[@]} -gt 0 ]] || { echo "No manifest entries." >&2; exit 1; }

  SOURCE_TIP="$(git rev-parse "$SOURCE_BRANCH^{commit}")"
  TMPD="$(mktemp -d "${TMPDIR:-/tmp}/sub-replay.XXXXXX")"
  trap 'rm -rf "$TMPD"' EXIT

  declare -a EVENT_LINES=()

  for i in "${!M_PATHS[@]}"; do
    P="${M_PATHS[$i]}"
    URL="$(rewrite_github_url_to_ssh "${M_URLS[$i]}")"
    PDIR="$TMPD/plugin_${i}_$(echo "$P" | tr '/' '_')"

    ms="$(ls_path_mode_sha "$FORK_POINT" "$P")"
    mode="${ms%%$'\t'*}"
    from_sha="${ms#*$'\t'}"

    ms2="$(ls_path_mode_sha "$SOURCE_TIP" "$P")"
    to_sha="${ms2#*$'\t'}"
    mode2="${ms2%%$'\t'*}"

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
      to_sha="$(submodulizer_find_plugin_commit_for_tree "$PDIR" "$tr_end" "${M_TREE[$i]}" "$REPO_ROOT")" || {
        echo "Could not match plugin commit to vendored tree at $SOURCE_BRANCH:$P" >&2
        exit 1
      }
    else
      echo "Path $P: source tip must be gitlink or vendored directory for end SHA" >&2
      exit 1
    fi

    if ! plugin_base_override_for "$P" >/dev/null; then
      if [[ "$mode" == "160000" && -n "$from_sha" ]]; then
        :
      elif [[ "$mode" == "040000" ]]; then
        tr_sha="$(git rev-parse "$FORK_POINT:$P" 2>/dev/null || true)"
        if [[ -z "$tr_sha" ]]; then
          echo "No tree at $FORK_POINT:$P" >&2
          exit 1
        fi
        from_sha="$(submodulizer_find_plugin_commit_for_tree "$PDIR" "$tr_sha" "${M_TREE[$i]}" "$REPO_ROOT")" || {
          echo "Could not find plugin commit matching tree at $FORK_POINT:$P" >&2
          exit 1
        }
      else
        echo "Path $P at fork-point must be gitlink or directory; use --plugin-base ${P}=SHA" >&2
        exit 1
      fi
    else
      from_sha="$(plugin_base_override_for "$P")"
    fi

    GIT_TERMINAL_PROMPT=0 git -C "$PDIR" cat-file -e "${from_sha}^{commit}" 2>/dev/null || {
      echo "Missing plugin object $from_sha for $P" >&2
      exit 1
    }
    GIT_TERMINAL_PROMPT=0 git -C "$PDIR" cat-file -e "${to_sha}^{commit}" 2>/dev/null || {
      echo "Missing plugin object $to_sha for $P" >&2
      exit 1
    }

    mapfile -t PCOMMITS < <(GIT_TERMINAL_PROMPT=0 git -C "$PDIR" rev-list --first-parent --reverse "${from_sha}..${to_sha}")
    [[ ${#PCOMMITS[@]} -eq 0 ]] && continue

    for c in "${PCOMMITS[@]}"; do
      ct="$(git -C "$PDIR" show -s --format=%ct "$c")"
      EVENT_LINES+=("${ct}"$'\t'"${P}"$'\t'"${c}"$'\t'"${PDIR}"$'\t'"${M_URLS[$i]}")
    done
  done

  [[ ${#EVENT_LINES[@]} -gt 0 ]] || { echo "No plugin commits to replay." >&2; exit 0; }

  IFS=$'\n'
  sorted="$(printf '%s\n' "${EVENT_LINES[@]}" | LC_ALL=C sort -t $'\t' -k1,1n -k2,2 -k3,3)"
  unset IFS

  if $DRY_RUN; then
    echo "Planned ${#EVENT_LINES[@]} commits on $TARGET_BRANCH (from $FORK_POINT)"
    while IFS=$'\t' read -r ct p sha pdir url; do
      [[ -z "${ct:-}" ]] && continue
      echo "  $ct  $p  $sha  ($(git -C "$pdir" show -s --format=%s "$sha"))"
    done <<< "$sorted"
    exit 0
  fi

  $FORCE_REPLAY && git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH" && git branch -D "$TARGET_BRANCH" 2>/dev/null || true
  git worktree prune 2>/dev/null || true

  WT="$TMPD/wt"
  rm -rf "$WT"

  manifest_url_for_path() {
    local want="$1" _i
    for _i in "${!M_PATHS[@]}"; do
      if [[ "${M_PATHS[$_i]}" == "$want" ]]; then
        echo "${M_URLS[$_i]}"
        return 0
      fi
    done
    return 1
  }

  rebuild_gitmodules() {
    rm -f "$WT/.gitmodules"
    git -C "$WT" ls-files -s | while read -r mode sha _st path; do
      [[ "$mode" == "160000" ]] || continue
      u="$(manifest_url_for_path "$path")" || continue
      printf '[submodule "%s"]\n\tpath = %s\n\turl = %s\n' "$path" "$path" "$u" >>"$WT/.gitmodules"
    done
  }

  GIT_TERMINAL_PROMPT=0 git "${git_github_pat_c[@]}" worktree add -B "$TARGET_BRANCH" "$WT" "$FORK_POINT" --force

  while IFS=$'\t' read -r ct P csha pdir url; do
    [[ -z "${ct:-}" ]] && continue
    git -C "$WT" reset --hard -q HEAD
    git -C "$WT" rm -rf --cached --ignore-unmatch "$P" 2>/dev/null || true
    rm -rf "${WT:?}/${P}"
    git -C "$WT" update-index --add --cacheinfo "160000,$csha,$P"
    rebuild_gitmodules
    git -C "$WT" add -f .gitmodules 2>/dev/null || true

    an="$(git -C "$pdir" show -s --format=%an "$csha")"
    ae="$(git -C "$pdir" show -s --format=%ae "$csha")"
    adate="$(git -C "$pdir" show -s --format=%ai "$csha")"
    body="$(git -C "$pdir" show -s --format=%B "$csha")"
    {
      printf '%s\n\n' "$body"
      printf 'Replayed-from: %s\n' "$csha"
      printf 'Plugin-path: %s\n' "$P"
      printf 'gitlink: submodulize.sh (replay)\n'
    } >"$TMPD/commitmsg.txt"

    GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" GIT_AUTHOR_DATE="$adate" \
      GIT_COMMITTER_NAME="$an" GIT_COMMITTER_EMAIL="$ae" GIT_COMMITTER_DATE="$adate" \
      git -C "$WT" commit -F "$TMPD/commitmsg.txt"
  done <<< "$sorted"

  git -C "$REPO_ROOT" worktree remove -f "$WT" 2>/dev/null || true
  echo "Done. Branch $TARGET_BRANCH -> $(git rev-parse "$TARGET_BRANCH")"
}

if $BOOTSTRAP; then
  submodulize_bootstrap_pipeline
  exit 0
fi

# Default "submodulize ./" on an existing --target branch: extend layout from manifest (new submodule paths)
# instead of requiring --force. Full replay rebuild still needs explicit --fork-point/--source/--target intent + --force.
if $REPLAY && ! $FORCE_REPLAY && git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
  if ! $FORK_POINT_EXPLICIT && ! $REPLAY_SOURCE_EXPLICIT && ! $REPLAY_TARGET_EXPLICIT && ((${#PLUGIN_BASE_OVERRIDES[@]} == 0)); then
    echo "submodulize: branch $TARGET_BRANCH exists — applying manifest updates (same as --no-replay). Use --force to replay-recreate $TARGET_BRANCH from --fork-point." >&2
    REPLAY=false
    active_br="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
    if [[ "$active_br" != "$TARGET_BRANCH" ]]; then
      echo "submodulize: checking out $TARGET_BRANCH" >&2
      git checkout "$TARGET_BRANCH"
    fi
  fi
fi

if $REPLAY; then
  submodulize_replay_mode
  exit 0
fi

# After manifest one-shot: replay unsubmodulized → submodulized when unsub is ahead (or when --sync-unsub).
RUN_SYNC_FROM_UNSUB=false
if ! $NO_SYNC_FROM_UNSUB && ! $NO_COMMIT; then
  if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH" && git show-ref --verify --quiet refs/heads/unsubmodulized; then
    if $SYNC_UNSUB; then
      RUN_SYNC_FROM_UNSUB=true
    else
      _mb="$(git merge-base unsubmodulized "$TARGET_BRANCH" 2>/dev/null || true)"
      _ut="$(git rev-parse unsubmodulized^{commit} 2>/dev/null || true)"
      if [[ -n "$_mb" && -n "$_ut" && "$_mb" != "$_ut" ]]; then
        RUN_SYNC_FROM_UNSUB=true
      fi
    fi
  fi
fi

if $RUN_SYNC_FROM_UNSUB && ! $SYNC_UNSUB; then
  echo "submodulize: unsubmodulized is ahead of merge-base with $TARGET_BRANCH — syncing plugin gitlinks." >&2
fi

if $RUN_SYNC_FROM_UNSUB; then
  sb="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
  if [[ "$sb" != "$TARGET_BRANCH" ]]; then
    echo "submodulize: checking out $TARGET_BRANCH (sync from unsubmodulized)" >&2
    git checkout "$TARGET_BRANCH"
  fi
  if [[ ! -f "$MANIFEST" ]]; then
    if git cat-file -e "$TARGET_BRANCH:plugin-submodules.manifest" 2>/dev/null; then
      git show "$TARGET_BRANCH:plugin-submodules.manifest" >"$MANIFEST"
      echo "submodulize: wrote plugin-submodules.manifest from $TARGET_BRANCH (was missing at repo root)." >&2
    else
      echo "Manifest not found: $MANIFEST (and not in $TARGET_BRANCH:plugin-submodules.manifest)" >&2
      exit 1
    fi
  fi
fi

submodulize_one_shot_apply_manifest

if $RUN_SYNC_FROM_UNSUB; then
  submodulize_sync_from_unsubmodulized
fi
exit 0
