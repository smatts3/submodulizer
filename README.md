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

### Migrating from the legacy `plugin-submodules.manifest`

The pipe-delimited `plugin-submodules.manifest` is auto-migrated on the first run of `submodulize.sh` or `unsubmodulize.sh`: the script invokes `tools/convert-manifest.sh`, writes `submodulizer.json`, and `git rm`s the legacy file when staging on the `submodulized` branch (the old file stays in history). To run the converter standalone:

```bash
bash tools/convert-manifest.sh --in plugin-submodules.manifest --out submodulizer.json
```

The converter assigns `group` based on the legacy section-header comments (`# --- Monorepos ---`, `# --- Legacy plugins ---`, `# --- No submodule clone ---`). Commented-out "broken upstream" lines aren't parseable; add them by hand as `{ "group": "no_clone", "disabled": true, "note": "..." }` entries if you want them preserved.
