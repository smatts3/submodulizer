# Submodulizer

Convert messy repos with copied-in files from other repos into a submodulized repo.

## Usage

1. Clone the messy repo, separate from any other instances.
1. Create a plugin manifest file.
1. Run `submodulize.sh <PATH>`
1. If you make changes to any submodules or they update and you want to update the superproject, run `unsubmodulize.sh <PATH>`
1. If there are updates to the superproject and you want to move them to the submodulized repo, run `submodulize.sh <PATH>`

## Plugin Manifest Files

Plain text at the Moodle in the file `plugin-submodules.manifest`. One plugin per line:

```text
relative_path|clone_url|branch
```

Example: `mod/hvp|https://github.com/h5p/moodle-mod_hvp.git|main`

Lines starting with `#` are comments. If `branch` is empty, the scripts fall back to `main` (then the remote default).