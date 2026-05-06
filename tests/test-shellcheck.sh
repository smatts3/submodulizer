#!/usr/bin/env bash
# Optional: shellcheck cleandev scripts when shellcheck is installed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
CLEANDEV="${CLEANDEV:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export CLEANDEV
require_cleandev

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "SKIP shellcheck (not installed)"
  exit 0
fi

# Run from this directory so `source=lib.sh` directives resolve (shellcheck -x).
cd "$SCRIPT_DIR"
shellcheck -x lib.sh run.sh test-*.sh ../submodulize.sh ../unsubmodulize.sh ../manifest-submodulize-redundant.sh
ok "shellcheck"
