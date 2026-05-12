#!/usr/bin/env bash
#
# Cron wrapper for submodulizer workflows.
# - Runs submodulize on the Moodle clone
# - Pushes submodulized branch if it changed
# - Creates a PR (if none already open for the same head/base)
# - Runs unsubmodulize on the Moodle clone
# - Pushes unsubmodulized branch if it changed
# - Creates a PR (if none already open for the same head/base)
#
# Assumptions from request:
#   HOME=/home/smatts3
#   submodulizer repo at ~/submodulizer
#   moodle clone at ~/lsuce-moodle
#
# Optional environment overrides:
#   HOME_DIR                   default: /home/smatts3
#   SUBMODULIZER_DIR           default: $HOME_DIR/submodulizer
#   MOODLE_DIR                 default: $HOME_DIR/lsuce-moodle
#   SUBMODULIZED_BRANCH        default: submodulized
#   UNSUBMODULIZED_BRANCH      default: unsubmodulized
#   SUBMODULIZED_PR_BASE       default: remote default branch
#   UNSUBMODULIZED_PR_BASE     default: remote default branch
#   GIT_REMOTE                 default: origin
#   LOG_DIR                    default: $HOME_DIR/.cache/submodulizer
#   DRY_RUN                    default: false (set to 1/true/yes)

set -euo pipefail

HOME_DIR="${HOME_DIR:-/home/smatts3}"
SUBMODULIZER_DIR="${SUBMODULIZER_DIR:-$HOME_DIR/submodulizer}"
MOODLE_DIR="${MOODLE_DIR:-$HOME_DIR/lsuce-moodle}"
SUBMODULIZED_BRANCH="${SUBMODULIZED_BRANCH:-submodulized}"
UNSUBMODULIZED_BRANCH="${UNSUBMODULIZED_BRANCH:-unsubmodulized}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
LOG_DIR="${LOG_DIR:-$HOME_DIR/.cache/submodulizer}"
DRY_RUN="${DRY_RUN:-false}"

usage() {
  cat <<'EOF'
Usage: cron-submodulizer-sync.sh [--dry-run|-n] [--help|-h]

Options:
  -n, --dry-run   Run submodulize/unsubmodulize in dry-run mode and skip push/PR.
  -h, --help      Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ "$DRY_RUN" =~ ^(1|true|yes)$ ]]; then
  DRY_RUN=true
else
  DRY_RUN=false
fi

mkdir -p "$LOG_DIR"
LOCK_FILE="$LOG_DIR/cron-submodulizer.lock"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another cron-submodulizer run is active; exiting."
  exit 0
fi

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "Missing required command: $cmd"
    exit 1
  fi
}

require_cmd git
require_cmd gh
require_cmd bash
require_cmd flock

if [[ ! -d "$SUBMODULIZER_DIR/.git" ]]; then
  log "Submodulizer repo not found at: $SUBMODULIZER_DIR"
  exit 1
fi

if [[ ! -d "$MOODLE_DIR/.git" ]]; then
  log "Moodle repo not found at: $MOODLE_DIR"
  exit 1
fi

GH_USER="$(gh api user --jq .login 2>/dev/null || true)"
if [[ "$GH_USER" != "smatts3" ]]; then
  log "GitHub auth mismatch. Expected gh user smatts3, got: ${GH_USER:-<none>}"
  log "Run: gh auth login (as smatts3), then re-run cron."
  exit 1
fi

cd "$MOODLE_DIR"

# Keep cron safe: never run on a dirty working tree.
if [[ -n "$(git status --porcelain)" ]]; then
  log "Working tree is dirty in $MOODLE_DIR. Commit/stash manually before cron."
  exit 1
fi

git fetch "$GIT_REMOTE" --prune

REMOTE_HEAD="$(git symbolic-ref --quiet --short "refs/remotes/$GIT_REMOTE/HEAD" 2>/dev/null || true)"
if [[ -z "$REMOTE_HEAD" ]]; then
  if git show-ref --verify --quiet "refs/remotes/$GIT_REMOTE/main"; then
    DEFAULT_BRANCH="main"
  elif git show-ref --verify --quiet "refs/remotes/$GIT_REMOTE/master"; then
    DEFAULT_BRANCH="master"
  else
    log "Could not determine remote default branch."
    exit 1
  fi
else
  DEFAULT_BRANCH="${REMOTE_HEAD#"$GIT_REMOTE/"}"
fi

SUBMODULIZED_PR_BASE="${SUBMODULIZED_PR_BASE:-$DEFAULT_BRANCH}"
UNSUBMODULIZED_PR_BASE="${UNSUBMODULIZED_PR_BASE:-$DEFAULT_BRANCH}"

sync_local_branch_from_remote() {
  local branch="$1"
  if $DRY_RUN; then
    if git show-ref --verify --quiet "refs/remotes/$GIT_REMOTE/$branch"; then
      log "[dry-run] Would reset local $branch to $GIT_REMOTE/$branch"
    else
      log "[dry-run] Would create/reset local $branch from $GIT_REMOTE/$DEFAULT_BRANCH"
    fi
    return 0
  fi
  if git show-ref --verify --quiet "refs/remotes/$GIT_REMOTE/$branch"; then
    git checkout -B "$branch" "$GIT_REMOTE/$branch"
  else
    git checkout -B "$branch" "$GIT_REMOTE/$DEFAULT_BRANCH"
  fi
}

create_pr_if_needed() {
  local head_branch="$1"
  local base_branch="$2"
  local title="$3"
  local body="$4"

  if [[ "$head_branch" == "$base_branch" ]]; then
    log "Skipping PR for $head_branch -> $base_branch (same branch)."
    return 0
  fi

  local existing
  existing="$(gh pr list --head "$head_branch" --base "$base_branch" --state open --json url --jq '.[0].url' 2>/dev/null || true)"
  if [[ -n "$existing" && "$existing" != "null" ]]; then
    log "PR already open: $existing"
    return 0
  fi

  # Only open a PR when head is ahead of base.
  if [[ "$(git rev-list --count "$base_branch..$head_branch")" -eq 0 ]]; then
    log "No commits to PR from $head_branch into $base_branch."
    return 0
  fi

  local pr_url
  pr_url="$(gh pr create --head "$head_branch" --base "$base_branch" --title "$title" --body "$body" 2>/dev/null || true)"
  if [[ -n "$pr_url" ]]; then
    log "Opened PR: $pr_url"
  else
    log "Failed to create PR for $head_branch -> $base_branch."
  fi
}

push_if_branch_advanced() {
  local branch="$1"
  local before_sha="$2"
  local after_sha

  if $DRY_RUN; then
    log "[dry-run] Skipping push check for $branch."
    return 1
  fi

  after_sha="$(git rev-parse "$branch")"
  if [[ "$after_sha" == "$before_sha" ]]; then
    log "No new commits on $branch."
    return 1
  fi

  git push "$GIT_REMOTE" "$branch"
  log "Pushed $branch: $before_sha -> $after_sha"
  return 0
}

run_submodulize_phase() {
  local before script_args=()
  sync_local_branch_from_remote "$SUBMODULIZED_BRANCH"
  before="$(git rev-parse "$SUBMODULIZED_BRANCH" 2>/dev/null || git rev-parse "$GIT_REMOTE/$SUBMODULIZED_BRANCH")"

  log "Running submodulize on $SUBMODULIZED_BRANCH"
  script_args=(--repo "$MOODLE_DIR" --target "$SUBMODULIZED_BRANCH")
  $DRY_RUN && script_args+=(--dry-run)
  bash "$SUBMODULIZER_DIR/submodulize.sh" "${script_args[@]}"

  if push_if_branch_advanced "$SUBMODULIZED_BRANCH" "$before"; then
    create_pr_if_needed \
      "$SUBMODULIZED_BRANCH" \
      "$SUBMODULIZED_PR_BASE" \
      "Automated submodulize update ($(date -u +%F))" \
      "Automated cron update from \`submodulize.sh\` run on \`$MOODLE_DIR\`."
  fi
}

run_unsubmodulize_phase() {
  local before script_args=()
  sync_local_branch_from_remote "$UNSUBMODULIZED_BRANCH"
  before="$(git rev-parse "$UNSUBMODULIZED_BRANCH" 2>/dev/null || git rev-parse "$GIT_REMOTE/$UNSUBMODULIZED_BRANCH")"

  log "Running unsubmodulize on $UNSUBMODULIZED_BRANCH"
  script_args=(--repo "$MOODLE_DIR" --target "$UNSUBMODULIZED_BRANCH")
  $DRY_RUN && script_args+=(--dry-run)
  bash "$SUBMODULIZER_DIR/unsubmodulize.sh" "${script_args[@]}"

  if push_if_branch_advanced "$UNSUBMODULIZED_BRANCH" "$before"; then
    create_pr_if_needed \
      "$UNSUBMODULIZED_BRANCH" \
      "$UNSUBMODULIZED_PR_BASE" \
      "Automated unsubmodulize update ($(date -u +%F))" \
      "Automated cron update from \`unsubmodulize.sh\` run on \`$MOODLE_DIR\`."
  fi
}

log "Starting cron-submodulizer sync${DRY_RUN:+ (dry-run=$DRY_RUN)}"
run_submodulize_phase
run_unsubmodulize_phase
log "Completed cron-submodulizer sync"
