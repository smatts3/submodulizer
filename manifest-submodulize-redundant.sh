#!/usr/bin/env bash
# Exit 0 if running submodulize.sh would be a no-op: every active manifest path is already listed
# in .gitmodules and .gitmodules is non-empty. Exit 1 otherwise (submodulize should run).
# Used by new.sh --submodulize and cleandev/tests.
# Default manifest: ROOT/plugin-submodules.manifest (same as submodulize.sh).
#
# Usage: ./cleandev/manifest-submodulize-redundant.sh --repo ROOT [--manifest PATH]
set -euo pipefail

REPO_ROOT=""
MANIFEST=""
MANIFEST_EXPLICIT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_ROOT="${2:?}"
      shift 2
      ;;
    --manifest)
      MANIFEST="${2:?}"
      MANIFEST_EXPLICIT=true
      shift 2
      ;;
    -h|--help)
      sed -n '1,13p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

[[ -n "$REPO_ROOT" ]] || {
  echo "Usage: $0 --repo ROOT [--manifest PATH]" >&2
  echo "  Default manifest: ROOT/plugin-submodules.manifest" >&2
  exit 2
}

if ! $MANIFEST_EXPLICIT; then
  MANIFEST="${REPO_ROOT%/}/plugin-submodules.manifest"
fi

[[ -f "$MANIFEST" ]] || {
  echo "Manifest not found: $MANIFEST" >&2
  exit 2
}

cd "$REPO_ROOT"

need_submod=0
active=0
while IFS="|" read -r p _rest || [[ -n "${p:-}" ]]; do
  case "${p#[[:space:]]}" in
    ""|\#*) continue ;;
  esac
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  case "$p" in
    ""|\#*) continue ;;
  esac
  active=$((active + 1))
  if ! git config -f .gitmodules --get-regexp path 2>/dev/null | awk '{print $2}' | grep -Fxq "$p"; then
    need_submod=1
    break
  fi
done < "$MANIFEST"

if [[ "$active" -eq 0 ]]; then
  exit 1
fi
if [[ "$need_submod" -eq 0 && -s .gitmodules ]]; then
  exit 0
fi
exit 1
