# `submodulizer-moodle.json`

Optional sidecar file at the Moodle root that pins specific plugin versions / commits across multiple upstreams. Plugin upstreams aren't always consistent about updating `version.php`, so this file records observed states by date+source so the pin choice is explicit.

```json
{
  "plugins": {
    "theme/snap": {
      "versions": [
        { "date": "2026-06-09", "source": "moodle.org/plugins/theme_snap",
          "sourcetype": "directory", "version": "v4.5.1", "current": true },
        { "date": "2026-05-04", "source": "open-lms-open-source/moodle-theme_snap",
          "sourcetype": "github", "commithash": "3d4c345" }
      ]
    }
  }
}
```

## Schema

Top-level:

- `plugins` (object, required) — keyed by plugin path; the key must exist (and not be `disabled`) in `submodulizer.json`.

Per plugin:

- `versions` (array, required, non-empty) — one object per observed state of this plugin.

Per entry:

- `source` (string, required) — the upstream identifier (e.g. `"owner/repo"` for `github`, a moodle.org plugins-directory slug for `directory`).
- `sourcetype` (string, required) — one of `directory` | `github` | `gitlab` | `bitbucket` | `url`.
- `date` (string, optional) — ISO-like date the snapshot was taken. Used as the primary tiebreaker when no entry is marked `current: true`.
- `version` (string, optional) — the value the plugin's `version.php` declared at this source (not always available; external repos are inconsistent about updating it).
- `commithash` (string, optional) — git commit at this source (preferred precise pin).
- `current` (boolean, optional) — at most one entry per plugin may be `true`. Marks the canonical state.

Unknown top-level keys, unknown per-plugin keys, and unknown per-entry keys are rejected. Plugin paths that don't exist (or are disabled) in `submodulizer.json` are rejected.

## How `submodulize.sh` uses it

For each plugin with entries in this file, the script picks a single "pin entry":

1. The unique `current: true` entry, if any.
2. Otherwise, the entry with the most recent `date` (string compare).
3. Ties or missing `date`: a probe bare repo fetches each tied entry's commit (`commithash` directly, or `version` as a tag against the URL in `submodulizer.json`) and the chronologically-latest commit timestamp wins.

The pin entry is then resolved to a precise commit:

- `commithash` is used as-is.
- Otherwise `version` is resolved as a tag against the `submodulizer.json` URL.

That commit is fetched into the submodule, checked out, and recorded in the gitlink (overriding the branch tip from `submodulizer.json`). If the resolved commit isn't on the remote (force-pushed away, GC'd, etc.), the run aborts. A `current: true` entry that has neither `commithash` nor `version` is rejected by the schema validator.

The file is optional. Plugins with no entry in `submodulizer-moodle.json` keep the existing behavior — pinned to the branch tip from `submodulizer.json`.

Staging: like `submodulizer.json`, `submodulizer-moodle.json` is staged on the `submodulized` branch only; vendored branches (`master`, `main`, `unsubmodulized`) can keep it untracked.
