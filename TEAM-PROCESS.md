# Team process, image strategy, and manifest maintenance

This document covers **branch policy** for [lsuce-moodle](https://github.com/lsuonline/lsuce-moodle), the **Docker image decision** for this repo, and **how to refresh** `plugin-submodules.manifest` from the plugin inventory CSV.

**Where the manifest lives:** On **cleandev**, treat `plugin-submodules.manifest` as part of the Moodle superproject (repo root), alongside `.gitmodules`. The copy in **this** repo under [`cleandev/plugin-submodules.manifest`](plugin-submodules.manifest) is the maintained source for CSV refresh and CI lint; `submodulize.sh` / `unsubmodulize.sh` default to `ROOT/plugin-submodules.manifest` unless you pass `--manifest`.

**Branch replay (default):** `unsubmodulize.sh` and `submodulize.sh` run replay unless you pass **`--no-replay`**. Replay builds histories with **one Moodle superproject commit per plugin-repo commit** (chronological order, carry-forward). **`--fork-point`** defaults to local **`master`** (else **`main`**) when omitted, when the script can infer it; otherwise pass it explicitly. **`--source`** defaults when omitted: **unsub** prefers **`unsubmodulized`**, then **`master`**, **`main`**, **`submodulized`**; **sub** prefers **`submodulized`**, **`master`**, **`main`**. Source tips may be **gitlinks or vendored trees** (tree matched to plugin commits). Defaults **`--target`** branch names (`submodulized`, `unsubmodulized`). If the fork-point checkout is **vendored** at a manifest path, the script matches the embedded tree to a plugin commit (or use `--plugin-base path=SHA`). `new.sh --submodulize` runs **`submodulize.sh --no-replay`** (one-shot only).

---

## 1. Team process (develop ↔ cleandev)

### Roles of each branch

| Branch | Layout | Use |
|--------|--------|-----|
| **develop** | Plugins **vendored** in the monorepo | Default integration branch; what `new.sh` merges (`origin/develop`) into `/var/www/html`; safest shared line until everyone is on submodules. |
| **cleandev** | Plugins as **Git submodules** (see `.gitmodules` + `plugin-submodules.manifest`) | Preferred direction for new work: per-plugin repos, clearer ownership, submodule SHAs on the superproject. |

### Where changes land

- **Plugin code** (features, fixes): commit and push in the **plugin’s own repository**, then update the **submodule pointer** on **cleandev** in lsuce-moodle (superproject commit records the new SHA).
- **Moodle core / cross-cutting tree** (not in a submodule): commit on the branch you are using (**develop** or **cleandev**), following team review rules.
- **develop** should remain the branch that receives **vendored** merges from upstream workflows until the team fully switches; **cleandev** stays in sync via policy merges or ports (see [ROADMAP.md](../ROADMAP.md) for planned commit-port tooling).

### Switching default work to cleandev

1. Use **cleandev** for day-to-day clones and feature branches when working on submodule-backed plugins.
2. Keep **develop** buildable and merged regularly if CI or release still tracks it.
3. When pulling large updates from **develop** into a **cleandev** checkout, expect **layout friction** (vendored vs submodule). Until automated porting exists, coordinate with `unsubmodulize.sh` / `submodulize.sh` and avoid mixing half-converted trees.

### Local Docker stack (`new.sh`)

- **Without `--submodulize`:** Container tracks **vendored** layout after merge from `origin/develop` (matches **develop**).
- **With `--submodulize`:** After that merge, runs `submodulize.sh --no-replay` so manifest-listed paths become **submodules** (closer to **cleandev**). Requires `GITHUB_TOKEN` / `cleandev/.github-token` or `SUBMODULIZE_SSH=1` for private GitHub repos.
- Never commit **`cleandev/.github-token`** (gitignored).

### Submodule hygiene

- After `git submodule update --init --recursive`, run tests as usual.
- If a submodule shows dirty state, fix inside the submodule repo (commit/push) or reset deliberately—do not commit accidental local edits in the superproject without intent.

---

## 2. Image strategy (this repo)

**Decision:** Stay on the **repository `Dockerfile`** (`php:8.3-apache`) and the Compose default image **`lsuce-moodle-web:local`** until there is a published **`lsuonline/moodle-dev` (or equivalent) image** explicitly built for **Moodle 4.5** on a **supported PHP** (not PHP 8.4 with the current installer breakage: `SerializableClosure` / `use` in closures).

- **`docker-compose.yml`** is the source of truth: `build: .` + `image: lsuce-moodle-web:local`.
- To use a registry image instead, follow the comment in `docker-compose.yml` (swap `build` / `image`).
- **`build.sh`** only runs `docker build -t lsuonline/moodle-dev:latest .`; that tag name is **legacy** for ad-hoc or Hub-style workflows and is **not** what Compose uses by default.

Revisit this decision when ops publishes a vetted tag; then update Compose comments and this section.

---

## 3. Manifest regeneration (from CSV)

There is **no checked-in generator script**; updates are **manual** (or a one-off script you run locally). Use this checklist whenever the inventory or plugin remotes change.

### Source file

- **`Evaluation of LSU moodle messy plugins(List) (3).csv`** (repository root).

### Columns (relevant)

| Column | Use |
|--------|-----|
| **Path** | Moodle path; strip a leading `/` for the manifest (e.g. `/mod/hvp` → `mod/hvp`). |
| **Third Party Repo URL** | Upstream Git clone URL (often HTTPS). |
| **Custom URL** | LSU/custom override. **If both Custom URL and Third Party Repo URL are set, prefer Custom URL** for the clone URL in the manifest. |
| **URL** (last column) | Often duplicates the chosen upstream URL; use if the other columns are empty and this is the only usable Git URL. |

Other columns (versions, hashes, “In sync”) help auditing but do not go into the manifest line format.

### Manifest line format

```text
relative_path|clone_url|branch
```

- Lines starting with `#` are comments (ignored by scripts).
- If **branch** is empty, `submodulize.sh` / `unsubmodulize.sh` default to **`main`**, then fall back to the remote’s default branch if `main` does not exist.

### `customcertelement_*` rows

The CSV lists many plugins under `mod/customcert/element/...` (`customcertelement_bgimage`, etc.). They all belong to **`moodle-mod_customcert`**. The manifest should have **one** active line:

```text
mod/customcert|https://github.com/mdjnelson/moodle-mod_customcert.git|main
```

Do **not** add separate submodule lines per element subdirectory.

### Monorepos

If **one Git repository** contains **multiple** top-level Moodle plugin paths (e.g. Kaltura, Microsoft o365-moodle, `lsu-enrol_ues`), **do not** add one manifest line per path with the same URL: `submodulize.sh` cannot “clone once, map subpaths.” Keep a **commented block** in `plugin-submodules.manifest` listing the URL and paths (see `# --- Monorepos ---` in the manifest). Treat those directories as **vendored** in the superproject unless you adopt an advanced layout (see below).

#### One-shot: refresh vendored monorepo plugins (develop or cleandev)

Use this when upstream shipped changes and you need the same Moodle paths updated without submodule tooling.

1. **Note the source** from the manifest comment block (clone URL and the list of Moodle-relative paths, e.g. `mod/kalvidassign`).
2. **Clone upstream** somewhere outside the Moodle tree (temp is fine), on the branch or tag you intend to ship:
   ```bash
   git clone --depth 1 -b BRANCH_OR_TAG https://github.com/org/monorepo.git /tmp/monorepo-src
   ```
   Use a full clone if you need history or a non-default branch tip.
3. **Map paths** — upstream layout varies by project. Under `/tmp/monorepo-src`, locate the directory that corresponds to each Moodle path (often the path matches the repo tree; if the project nests plugins under `moodle/` or similar, copy from there).
4. **Copy into lsuce-moodle** from the Moodle repo root, one path at a time (adjust source side to match step 3):
   ```bash
   rsync -a --delete /tmp/monorepo-src/mod/kalvidassign/ mod/kalvidassign/
   ```
   Prefer `--delete` only when you intend to mirror upstream exactly; otherwise omit it. On Windows without `rsync`, use a graphical diff tool or `cp -r` with care.
5. **Review** (`git status`, smoke test in Moodle), then **commit** in **lsuce-moodle** (single commit per upstream bump or per path—follow team convention).

Repeat for each path listed under that URL in the manifest comment. Bundles such as **Kaltura** (`moodle_plugin`), **Kaltura gallery** (`moodle-local_kalturamediagallery`), **o365-moodle**, and **lsu-enrol_ues** are independent clones; refresh each comment group from its own remote.

#### One-shot: cleandev when monorepo paths stay vendored

On **cleandev**, submodule-backed plugins use `.gitmodules`; monorepo-backed paths stay **normal tracked directories** in the superproject (no submodule entry). Do not add duplicate manifest active lines for the same URL. After `git submodule update --init`, those paths behave like core tree: edit, commit, and push on **lsuce-moodle** unless your team splits them out later.

*Automated “clone once, map subpaths” for the manifest is still not implemented; the steps above are the supported manual approach.*

### No usable HTTPS URL

If the CSV has no working public URL (internal, defunct, empty), add or keep a **comment** under `# --- No https clone URL` (or similar) naming the plugin id and path—do not invent URLs.

### After editing the manifest

1. Run **`submodulize.sh --no-replay --dry-run`** from a **test clone** of lsuce-moodle to sanity-check paths and remotes.
2. Commit manifest changes in **this** repo (`lsuce_moodle_project`) when the tooling repo owns the file; if the manifest is versioned only in lsuce-moodle, commit there per your layout.

For script flags and `GITHUB_TOKEN` behavior, see the headers in `submodulize.sh` and `unsubmodulize.sh`.
