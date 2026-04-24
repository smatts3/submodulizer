#!/usr/bin/env bash
# Acceptance: base bare remote, Moodle clone, 1:1 plugin + monorepo plugins → bootstrap → submodule bumps →
# unsubmodulize replay (materializes plugin history on unsubmodulized) → push unsubmodulized → merge into integrator clone.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cleandev

TMP=$(mktemp -d)
export HOME="$TMP/_home"
mkdir -p "$HOME"
git config --global protocol.file.allow always
git config --global init.defaultBranch master
trap 'rm -rf "$TMP"' EXIT

BASE_GIT="$TMP/base.git"
PLUGIN_STD="$TMP/plugin_std"
PLUGIN_MONO="$TMP/plugin_mono"
MOODLE="$TMP/moodle"
INTEGRATOR="$TMP/integrator"

mkdir -p "$PLUGIN_STD" "$PLUGIN_MONO"
git init --bare "$BASE_GIT"
BASE_URI="file://${BASE_GIT}"

# --- 1:1 plugin repo (main) ---
git -C "$PLUGIN_STD" init -b main
git -C "$PLUGIN_STD" config core.autocrlf false
printf 'std=v0\n' >"$PLUGIN_STD/version.txt"
git -C "$PLUGIN_STD" add version.txt
git -C "$PLUGIN_STD" commit -q -m "std initial"
STD0="$(git -C "$PLUGIN_STD" rev-parse HEAD)"

# --- Monorepo: two plugin trees (avoid top-level "local/*" in case of ls-tree edge cases) ---
mkdir -p "$PLUGIN_MONO/plugins/mono_a" "$PLUGIN_MONO/plugins/mono_b"
git -C "$PLUGIN_MONO" init -b main
git -C "$PLUGIN_MONO" config core.autocrlf false
printf 'a=0\n' >"$PLUGIN_MONO/plugins/mono_a/a.txt"
printf 'b=0\n' >"$PLUGIN_MONO/plugins/mono_b/b.txt"
git -C "$PLUGIN_MONO" add plugins/mono_a plugins/mono_b
git -C "$PLUGIN_MONO" commit -q -m "mono initial"
MONO0="$(git -C "$PLUGIN_MONO" rev-parse HEAD)"

# --- Moodle: clone empty base, seed master, vendor layout matching plugin trees ---
GIT_TERMINAL_PROMPT=0 git clone -q "$BASE_URI" "$MOODLE"
git -C "$MOODLE" config core.autocrlf false

printf '# Moodle base\n' >"$MOODLE/README.md"
git -C "$MOODLE" add README.md
git -C "$MOODLE" commit -q -m "init base"
git -C "$MOODLE" push -u origin master

mkdir -p "$MOODLE/mod/onestd" "$MOODLE/blocks/mono_a" "$MOODLE/blocks/mono_b"
git -C "$PLUGIN_STD" archive "$STD0" | tar -x -C "$MOODLE/mod/onestd"
# git archive COMMIT:tree emits members at tar root (no path prefix).
git -C "$PLUGIN_MONO" archive "$MONO0:plugins/mono_a" | tar -x -C "$MOODLE/blocks/mono_a"
git -C "$PLUGIN_MONO" archive "$MONO0:plugins/mono_b" | tar -x -C "$MOODLE/blocks/mono_b"

{
  printf 'mod/onestd|%s|main\n' "../plugin_std"
  printf 'blocks/mono_a|%s|main|plugins/mono_a\n' "../plugin_mono"
  printf 'blocks/mono_b|%s|main|plugins/mono_b\n' "../plugin_mono"
} >"$MOODLE/plugin-submodules.manifest"

git -C "$MOODLE" add mod/onestd blocks/mono_a blocks/mono_b plugin-submodules.manifest
git -C "$MOODLE" commit -q -m "vendored plugins + manifest"
git -C "$MOODLE" push origin master

FORK="$(git -C "$MOODLE" rev-parse HEAD)"

# --- Bootstrap: submodulized + unsubmodulized; fork-point is vendored tip before submodule branch ---
(
  cd "$MOODLE"
  "$CLEANDEV/submodulize.sh" --repo . --bootstrap
)

git -C "$MOODLE" show-ref --verify --quiet refs/heads/submodulized || fail "missing submodulized"
git -C "$MOODLE" show-ref --verify --quiet refs/heads/unsubmodulized || fail "missing unsubmodulized"
git -C "$MOODLE" merge-base --is-ancestor "$FORK" submodulized || fail "fork not ancestor of submodulized"
git -C "$MOODLE" merge-base --is-ancestor "$FORK" unsubmodulized || fail "fork not ancestor of unsubmodulized"

git -C "$MOODLE" ls-tree submodulized mod/onestd | grep -q '^160000' || fail "expected gitlink mod/onestd"
git -C "$MOODLE" ls-tree submodulized blocks/mono_a | grep -q '^160000' || fail "expected gitlink blocks/mono_a"
git -C "$MOODLE" show "unsubmodulized:mod/onestd/version.txt" | grep -q 'std=v0' || fail "unsub vendored std=v0"
git -C "$MOODLE" show "unsubmodulized:blocks/mono_a/a.txt" | grep -q 'a=0' || fail "unsub vendored mono a=0"

# --- New commits on plugin remotes (explicit dates so unsub replay chronological order is stable) ---
export GIT_AUTHOR_DATE="2020-01-10T12:00:00" GIT_COMMITTER_DATE="2020-01-10T12:00:00"
printf 'std=v1\n' >"$PLUGIN_STD/version.txt"
git -C "$PLUGIN_STD" commit -q -am "std bump v1"

export GIT_AUTHOR_DATE="2020-01-10T14:00:00" GIT_COMMITTER_DATE="2020-01-10T14:00:00"
printf 'from-std-plugin\n' >"$PLUGIN_STD/feature.txt"
git -C "$PLUGIN_STD" add feature.txt
git -C "$PLUGIN_STD" commit -q -m "std add feature"
STD_TIP="$(git -C "$PLUGIN_STD" rev-parse HEAD)"

export GIT_AUTHOR_DATE="2020-01-10T18:00:00" GIT_COMMITTER_DATE="2020-01-10T18:00:00"
printf 'a=1\n' >"$PLUGIN_MONO/plugins/mono_a/a.txt"
git -C "$PLUGIN_MONO" commit -q -am "mono bump mono_a"
MONO_TIP="$(git -C "$PLUGIN_MONO" rev-parse HEAD)"
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE

# --- Superproject: record new submodule tips on submodulized (squashed policy: one super commit for bumps) ---
git -C "$MOODLE" checkout -q submodulized
git -C "$MOODLE" submodule update --init --recursive --depth 1 2>/dev/null || git -C "$MOODLE" submodule update --init --recursive

git -C "$MOODLE" update-index --add --cacheinfo "160000,$STD_TIP,mod/onestd" \
  --cacheinfo "160000,$MONO_TIP,blocks/mono_a" \
  --cacheinfo "160000,$MONO_TIP,blocks/mono_b"
git -C "$MOODLE" commit -q -m "chore: bump all plugin gitlinks to upstream tips"

# --- Replay plugin commits onto unsubmodulized (linear superproject history from submodule commits) ---
"$CLEANDEV/unsubmodulize.sh" --repo "$MOODLE" --fork-point "$FORK" --source submodulized --target unsubmodulized

git -C "$MOODLE" show "unsubmodulized:mod/onestd/feature.txt" | grep -q 'from-std-plugin' || fail "unsub missing std feature"
git -C "$MOODLE" show "unsubmodulized:blocks/mono_a/a.txt" | grep -q 'a=1' || fail "unsub missing mono_a bump"

# --- Publish unsubmodulized to base; integrator merges into master ---
git -C "$MOODLE" push origin submodulized
git -C "$MOODLE" push origin unsubmodulized

# Clone with autocrlf off so the working tree matches the index (avoids phantom "local changes" on merge on Windows).
GIT_TERMINAL_PROMPT=0 git -c core.autocrlf=false clone -q "$BASE_URI" "$INTEGRATOR"
git -C "$INTEGRATOR" config core.autocrlf false
git -C "$INTEGRATOR" fetch origin unsubmodulized
git -C "$INTEGRATOR" checkout -q -f master
git -C "$INTEGRATOR" reset --hard master
git -C "$INTEGRATOR" clean -fd
git -C "$INTEGRATOR" merge -q origin/unsubmodulized -m "Merge unsubmodulized (vendor replay)"

git -C "$INTEGRATOR" show "HEAD:mod/onestd/feature.txt" | grep -q 'from-std-plugin' || fail "integrator master missing std feature after merge"
git -C "$INTEGRATOR" show "HEAD:blocks/mono_a/a.txt" | grep -q 'a=1' || fail "integrator master missing mono_a after merge"
git -C "$INTEGRATOR" show "HEAD:blocks/mono_b/b.txt" | grep -q 'b=0' || fail "integrator master missing mono_b baseline"

ok "acceptance: bootstrap → submodule bumps → unsub replay → push → merge into base"
