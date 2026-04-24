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

Plain text at the Moodle root in the file `plugin-submodules.manifest`. One plugin per line:

```text
relative_path|clone_url|branch
```

Example: `mod/hvp|https://github.com/h5p/moodle-mod_hvp.git|main`

Lines starting with `#` are comments. If `branch` is empty, the scripts fall back to `main` (then the remote default).

Some upstream repositories are **monorepos** (one Git tree with several plugin roots, for example Kaltura or Microsoft 365 plugins). This workflow does **not** support them: each line assumes the **remote repository root** is exactly what Moodle expects at `relative_path`. `git submodule add` clones the whole remote into that path, not a subdirectory of a shared repo, so multiple manifest lines pointing at the same clone URL would not produce a correct tree (and this repo’s manifest lint rejects duplicate URLs across active lines). Keep those plugins vendored, split them upstream into one repo per plugin, or handle them outside submodulize.