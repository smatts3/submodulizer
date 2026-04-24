# Submodulizer

Convert messy repos with copied-in files from other repos into a submodulized repo.

## Usage

1. Clone the messy repo, separate from any other instances.
1. Create a plugin manifest file.
1. Run `submodulize.sh <PATH>`
1. Do all your work on the `submodulized` branch or a descendent of it

### If there are changes to the submodules and you want to update the superproject
1. Run `unsubmodulize.sh <PATH>`
1. Push the `unsubmodulized` branch upstream

### If there are changes to the superproject and you want to update the submodulized repo
1. Fetch the master branch or whatever branch submodulize branched from
1. Run `submodulize.sh <PATH>`

## Plugin Manifest Files

Plain text at the Moodle root in the file `plugin-submodules.manifest`. One plugin per line.

```text
relative_path|clone_url|branch [| sparse_paths [| in_repo_tree_path]]
```

Example (one repo per path): `mod/hvp|https://github.com/h5p/moodle-mod_hvp.git|main`

Example (monorepo — same URL on two lines, each with sparse paths):

```text
local/kaltura_assign|https://github.com/kaltura/moodle_plugin.git|main|mod/kalvidassign
filter/kaltura|https://github.com/kaltura/moodle_plugin.git|main|filter/kaltura
```

Fields:

- **relative_path**, **clone_url**, **branch** — Same meaning as before. If `branch` is empty, the scripts fall back to `main` (then the remote default).
- **sparse_paths** (optional 4th field) — Comma-separated directories **inside** the upstream repository to include in each submodule checkout (Git cone sparse-checkout). Required on **every** manifest line that shares a `clone_url` with another line, so the manifest linter can allow monorepos.
- **in_repo_tree_path** (optional 5th field) — Directory inside the remote used for tree matching during replay and for `git archive` when unsubmodulize vendors a flat tree under `relative_path`. Omit it to default to the first path in `sparse_paths`. The 5th field is only valid when the 4th is non-empty.

Lines starting with `#` are comments.

**Submodule checkout layout:** Sparse checkout keeps in-repo path prefixes (for example `mod/foo/...` under the Moodle path for that submodule). **Unsubmodulize** strips that prefix when copying files so vendored branches look like a normal Moodle plugin directory.
