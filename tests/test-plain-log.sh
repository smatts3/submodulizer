#!/usr/bin/env bash
# --plain-log: no tooling footers; neutral aggregate commit messages.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cleandev

TMP=$(mktemp -d)
export HOME="$TMP/_home"
mkdir -p "$HOME"
git config --global protocol.file.allow always
trap 'rm -rf "$TMP"' EXIT

PLUGIN="$TMP/plugin"
MOODLE="$TMP/moodle"
mkdir -p "$PLUGIN" "$MOODLE"

git -C "$PLUGIN" init -b main
echo "v1" > "$PLUGIN/f.txt"
git -C "$PLUGIN" add f.txt
git -C "$PLUGIN" commit -q -m "p1"
echo "v2" >> "$PLUGIN/f.txt"
git -C "$PLUGIN" commit -q -am "p2"

C0="$(git -C "$PLUGIN" rev-parse HEAD~1)"

git -C "$MOODLE" init -b main
printf 'core\n' > "$MOODLE/README.md"
mkdir -p "$MOODLE/mod/foo"
git -C "$PLUGIN" archive "$(git -C "$PLUGIN" rev-parse HEAD~1)" | tar -x -C "$MOODLE/mod/foo"
git -C "$MOODLE" add README.md mod/foo
git -C "$MOODLE" commit -q -m "vendored base"

BASE="$(git -C "$MOODLE" rev-parse HEAD)"

git -C "$MOODLE" config -f .gitmodules submodule.mod/foo.path mod/foo
git -C "$MOODLE" config -f .gitmodules submodule.mod/foo.url "$PLUGIN"
git -C "$MOODLE" add .gitmodules
git -C "$MOODLE" rm -rf --cached mod/foo
git -C "$MOODLE" update-index --add --cacheinfo "160000,$C0,mod/foo"
git -C "$MOODLE" commit -q -m "sub at c0"

git -C "$MOODLE" checkout -q -b submodulized
git -C "$MOODLE" update-index --add --cacheinfo "160000,$(git -C "$PLUGIN" rev-parse HEAD),mod/foo"
git -C "$MOODLE" commit -q -m "sub at c1"

printf 'mod/foo|%s|main\n' "$PLUGIN" > "$MOODLE/plugin-submodules.manifest"

"$CLEANDEV/unsubmodulize.sh" --repo "$MOODLE" --fork-point "$BASE" --source submodulized \
  --target unsubmodulized --force --plugin-base "mod/foo=$C0" --plain-log

if git -C "$MOODLE" log -1 --format=%B unsubmodulized | grep -q '^Replayed-from:'; then
  fail "unsub replay: did not expect Replayed-from footer with --plain-log"
fi
if git -C "$MOODLE" log -1 --format=%B unsubmodulized | grep -q '^Plugin-path:'; then
  fail "unsub replay: did not expect Plugin-path footer with --plain-log"
fi

git -C "$MOODLE" checkout -q main
"$CLEANDEV/submodulize.sh" --repo "$MOODLE" --fork-point "$BASE" --source submodulized \
  --target sub2 --force --plugin-base "mod/foo=$C0" --plain-log

if git -C "$MOODLE" log -1 --format=%B sub2 | grep -q '^Replayed-from:'; then
  fail "sub replay: did not expect Replayed-from footer with --plain-log"
fi
if git -C "$MOODLE" log -1 --format=%B sub2 | grep -q '^gitlink:'; then
  fail "sub replay: did not expect gitlink footer with --plain-log"
fi

ok "plain-log omits replay footers (unsub + sub)"
