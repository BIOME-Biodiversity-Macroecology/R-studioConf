<!-- docs/operations/CONFIG_SITE_OVERLAY.md -->
---
title: "Host values in config/site: migration runbook"
audience: operator
status: current
tier: T1
source_path: docs/operations/CONFIG_SITE_OVERLAY.md
last_verified: 2026-11-19
---

# Host values in `config/site/`: migration runbook

Moves the values edited on a host into tracked `config/*.vars.conf` files to
the gitignored overlay `config/site/<name>.site.vars.conf`, so the checkout can
`git pull --ff-only` again. Decision record:
[ADR-0011](../adr/0011-host-values-only-in-site-overlay.md). The overlay rule
itself: [`config/SITE_OVERRIDE.md`](../../config/SITE_OVERRIDE.md).

## 1. What changes on the host

| Changed | How | Not changed |
|---|---|---|
| `config/site/<name>.site.vars.conf` | written (new, mode 600) or appended to (existing, a marked block) | anything under `/etc`, services, the deployed system |
| `config/<name>.vars.conf` | restored to the content at the checkout's `HEAD` (owner and mode kept) | `scripts/`, untracked files, `config/pin_r_version.vars.conf` |

No git commit, pull, stash or checkout is run. The live system does not change:
the scripts read the same effective values before and after (that is checked,
see §3). The next deploy (`50_setup_nodes.sh`, `30_install_nginx.sh`, ...)
reads the overlay through `lib/site_overlay.sh`.

## 2. Prerequisite: the code that reads the overlay

The overlay is read only by a checkout that contains ADR-0011. On a host still
behind (calc02 on 2026-11-19), the order is:

1. Run the migration **from a worktree of `origin/main`** (it contains the
   script) against the host checkout, with `FIX_SITE_OVERLAY_REPO`, see §4.
   This is the step that makes the pull possible.
2. Pull the host checkout. From then on its own scripts read the overlay.

Running a deploy script from the old checkout **after** step 1 and **before**
step 2 would deploy upstream values (the old scripts do not read the overlay).
Do steps 1 and 2 back to back, and deploy nothing in between.

## 3. Safety checks built in

- Dry-run by default; nothing is written without `--commit`.
- For every migrated file the script sources the host file, and the upstream
  file plus the new overlay, in a clean bash, and compares every variable. It
  writes only if they are identical (checked on a scratch copy), checks again on
  the real checkout after writing, and rolls back by itself on a mismatch.
- All or nothing. It refuses, and writes nothing, when:
  - a key was **deleted** in the host file (an overlay cannot unset it safely);
  - a **single-source-of-truth key** (`RPROFILE_VERSION`, `DEFAULT_R_VERSION`,
    `R_CORE_PACKAGES`, rule 19) differs from upstream.
  `--drop-key KEY` accepts the upstream value for that key; the host file stays
  in the backup.
- Comments and other non-assignment lines changed on the host are not carried
  over; the count is printed and the original is in the backup.
- Backup and `MANIFEST` in `/var/backups/biome-calc/config-site-overlay-<ts>-<pid>/`
  before any write: the host files, the existing overlay files, `worktree.diff`,
  `status.txt`, `untracked.txt`, and `review/<path>.patch` for every other
  modified tracked file.
- One run at a time (`flock` on `.git/biome-site-overlay.lock`); refused during
  a merge, rebase or cherry-pick.

## 4. Procedure (calc04 first, then one production host at a time)

As ladmin, from the host checkout:

```bash
cd /home/ladmin/configServices/R-studioConf
git fetch origin
git status --short | tee /tmp/status-before.txt | wc -l      # baseline: modified + untracked
git diff --name-only HEAD -- config/ | wc -l                   # baseline: tracked config edits
rm -rf /tmp/rsc-main && git worktree add --detach /tmp/rsc-main origin/main

# 1. dry-run: read the plan (keys moved, old -> new values, refusals, other edits)
FIX_SITE_OVERLAY_REPO="$PWD" bash /tmp/rsc-main/scripts/fix_config_site_overlay_inplace.sh

# 2. apply (sudo only for the backup under /var/backups)
sudo FIX_SITE_OVERLAY_REPO="$PWD" bash /tmp/rsc-main/scripts/fix_config_site_overlay_inplace.sh --commit

# 3. measure
git diff --name-only HEAD -- config/ | wc -l                   # target: 0
git status --short | wc -l
```

The script prints "Modified tracked files: N before, M after". `M > 0` means
other edits (scripts) still block the pull; resolve them first (§5), then:

```bash
git pull --ff-only
git worktree remove /tmp/rsc-main
sudo bash scripts/50_setup_nodes.sh --dry-run   # the overlay is read: no "No site-local override" warning
```

Record the run in [`HOTFIX_REGISTER.md`](HOTFIX_REGISTER.md) (host, commit, counts
before/after, backup path).

## 5. The other edits (`scripts/tools/*.sh`, `ttyd_login_wrapper.sh`)

The script lists each one:

- **"same content as origin/main"**: the fix is already upstream;
  `git checkout -- <path>` is safe before the pull.
- **"local edit not in origin/main"**: review `review/<path>.patch` in the backup.
  Either it becomes an upstream PR, or it is dropped with `git checkout -- <path>`
  (the patch stays in the backup). A mode-only change shows as
  `old mode 100644 / new mode 100755` in the patch.

These are not moved automatically: a script edit is code, not a value, and each
needs a decision.

## 6. Rollback

```bash
sudo FIX_SITE_OVERLAY_REPO=/home/ladmin/configServices/R-studioConf \
  bash /tmp/rsc-main/scripts/fix_config_site_overlay_inplace.sh \
  --rollback /var/backups/biome-calc/config-site-overlay-<ts>-<pid>
```

Restores the host files and the overlay files exactly, and removes the overlay
files the migration created. It refuses if `HEAD` moved since the backup (after
a pull the restored files would be edits against a newer commit); `--force`
overrides that.

## 7. Adding a host value later

Never edit a tracked `config/*.vars.conf` on a host. Put the key in
`config/site/<name>.site.vars.conf` (create it, mode 600). Single-source-of-truth
keys are ignored there with a warning: change them upstream.
