#!/usr/bin/env bash
# Run all cleandev automated tests. Uses only temp dirs under /tmp; does not modify the workspace.
#
# Usage: bash cleandev/tests/run.sh
#    or:  cd cleandev/tests && ./run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANDEV="$(cd "$SCRIPT_DIR/.." && pwd)"
export CLEANDEV

echo "CLEANDEV=$CLEANDEV"
echo ""

failed=0
for t in "$SCRIPT_DIR"/test-*.sh; do
  [[ -f "$t" ]] || continue
  echo "---------- $(basename "$t") ----------"
  if bash "$t"; then
    echo ""
  else
    echo "FAILED: $(basename "$t")" >&2
    failed=1
    echo ""
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "Some tests failed." >&2
  exit 1
fi
echo "All tests passed."
