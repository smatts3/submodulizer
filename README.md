# Submodulizer

Convert messy repos with copied-in files from other repos into a submodulized repo.

## Usage

1. Clone the messy repo, separate from any other instances.
2. Create a plugin manifest file.
3. Run `submodulize.sh <PATH>`
4. Do all your work on the `submodulized` branch or a descendent of it

### If there are changes to the submodules and you want to update the superproject

1. Run `unsubmodulize.sh <PATH>`
2. Push the `unsubmodulized` branch upstream

### If there are changes to the superproject and you want to update the submodulized repo

1. Fetch the master branch or whatever branch submodulize branched from
2. Run `submodulize.sh <PATH>`

## Plugin Manifest Files

JSON at the Moodle root in the file `submodulizer.json`. Requires `jq`.

```json
{
  "version": 1,
  "defaults": { "branch": "main" },
  "plugins": [
    { "path": "mod/hvp", "url": "https://github.com/h5p/moodle-mod_hvp.git" },

    { "path": "mod/kalvidassign",
      "url": "https://github.com/kaltura/moodle_plugin.git",
      "sparse_paths": ["mod/kalvidassign"],
      "group": "monorepo" },
    { "path": "filter/kaltura",
      "url": "https://github.com/kaltura/moodle_plugin.git",
      "sparse_paths": ["filter/kaltura"],
      "group": "monorepo" }
  ]
}
```

### Schema

Top-level:

- `version` (integer, optional) — currently must be `1` if set.
- `defaults.branch` (string, optional) — branch applied to entries with no explicit `branch`; defaults to `"main"`.
- `plugins` (array, required) — one object per plugin.

Per-entry fields:

- `path` (string, required) — plugin path inside the Moodle checkout (e.g. `mod/foo`).
- `url` (string, required for active entries) — clone URL.
- `branch` (string, optional) — branch in the plugin repo; falls back to `defaults.branch`.
- `sparse_paths` (array of strings, optional) — for monorepos, the directories inside the upstream repo to sparse-check-out.
- `tree` (string, optional) — in-repo tree path used for replay matching and archive extraction; required to omit only when there are no `sparse_paths`, otherwise defaults to the first element of `sparse_paths`.
- `group` (string, optional) — free-form category for inventory ("standard", "monorepo", "legacy", "no_clone" are the conventions used in this repo). Unused by the scripts; preserved across the auto-migration from the legacy text manifest.
- `disabled` (boolean, optional) — `true` skips the entry. Useful for documenting plugins whose upstream is missing or broken.
- `note` (string, optional) — free-form annotation. Useful with `disabled: true`.

Unknown top-level keys, unknown `defaults` keys, and unknown per-entry keys are rejected. Duplicate clone URLs are only allowed when every entry with that URL has a non-empty `sparse_paths` (monorepo rule).

## Pinning plugin versions

An optional sidecar file `submodulizer-moodle.json` at the Moodle root pins specific plugin commits across upstreams that don't reliably update `version.php`. See [README-moodle.md](README-moodle.md) for the schema and how `submodulize.sh` consumes it.