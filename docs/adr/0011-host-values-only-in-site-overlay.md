<!-- docs/adr/0011-host-values-only-in-site-overlay.md -->
# ADR-0011: Host values only in the site overlay, tracked config stays upstream

Status: Proposed (PR pending). Not applied on any host yet; plan: calc04 first.
Date: 2026-11-19

## Context

Production is the bare host install on biome-calc01-04. Each host runs from a
git checkout, `/home/ladmin/configServices/R-studioConf`, updated with
`git pull --ff-only`. The hosts' own values (RStudio session timeout, nginx
domain and certificates, ttyd/Nextcloud targets, NFS paths, ...) were edited
straight into **tracked** files:

| Host file (tracked) | Who reads it |
|---|---|
| `config/configure_rstudio.vars.conf` | `20_configure_rstudio.sh`, nginx timeout in `30_install_nginx.sh` / `update_nginx_templates.sh`, `99_check_rprofile_health.sh` |
| `config/install_nginx.vars.conf` | `30_install_nginx.sh`, `update_nginx_templates.sh`, `32_setup_letsencrypt.sh` |
| `config/install_secure_access.vars.conf` | `03_install_secure_access.sh` |
| `config/setup_nodes.vars.conf` | `50_setup_nodes.sh` (and its deployed copy in `/etc/biome-calc/conf/`), `99_*` checks, hotfixes |

Every upstream change to one of these files then blocks the pull. On
2026-11-19 biome-calc02 was 9 commits behind because PRs #65-#68 added 6 lines
to `setup_nodes.vars.conf`. Hosts are updated today from a `git worktree` of
`origin/main` to work around it, and the Step 8 release stamp reads
`v2026.10.1-dirty`. calc01-04 also carry local edits to 8 `scripts/tools/*.sh`
and `scripts/ttyd_login_wrapper.sh` (HOTFIX_REGISTER ledger).

A gitignored overlay already existed for some files (HC-12,
`config/SITE_OVERRIDE.md`): `config/site/setup_nodes.site.vars.conf` (mail keys),
`pkg_sync.site.vars.conf`, `node_maintenance.site.vars.conf`, each loaded by
hand in one script. The four files above had no overlay in most readers, so
there was nowhere else to put a host value.

## Decision

1. **One overlay rule for every `config/<name>.vars.conf`:** its host values go
   in `config/site/<name>.site.vars.conf` (gitignored), sourced right after the
   committed file. `lib/site_overlay.sh` implements it once:
   `site_overlay_source CONF`, `site_overlay_get CONF KEY` (for readers that
   used `grep`), `site_overlay_render CONF DEST` (deployed copies).
   `lib/common_utils.sh` loads it; scripts without common_utils source it
   directly. Every T1 reader of the four files uses it.
2. **The deployed copy carries the overlay.** `50_setup_nodes.sh` writes
   `/etc/biome-calc/conf/setup_nodes.vars.conf` with `site_overlay_render`
   (committed file, then the overlay's effective values as plain `KEY="value"`
   lines: last assignment wins for both the bash templates that source it and
   `telemetry_api.py`, which parses it line by line without expanding `${...}`).
   Before, only the 6 mail keys were patched in, so any other host value moved
   to the overlay would have been lost on the next deploy.
3. **Rule 19 is enforced in code.** `RPROFILE_VERSION`, `DEFAULT_R_VERSION` and
   `R_CORE_PACKAGES` keep their committed value even if a site file sets them
   (warning, never silent), and `pin_r_version.vars.conf` never takes an overlay.
   The R/Rprofile version can only change upstream. Both lists are fixed in code,
   not read from the environment or from a variable a site file could reassign.
4. **Migration is an in-place, idempotent script**,
   `scripts/fix_config_site_overlay_inplace.sh`: dry-run by default, `--commit`,
   `--rollback DIR`. It computes the effective configuration (every variable
   after sourcing) before and after, writes the overlay only if they are
   identical, and verifies again on the real checkout (automatic rollback on a
   mismatch). Under sudo the host files (bash) are evaluated as the checkout
   owner, never as root. A file edited during the run or after the migration
   is never overwritten silently, and a rollback only touches the paths a
   migration can write, in the checkout it was made for. It is all or nothing,
   and it changes nothing outside `config/`:
   edits to `scripts/` are reported with their diff, and flagged when the same
   content is already in `origin/main`.

## Consequences

- `git pull --ff-only` is no longer blocked by host values; the stamp stops
  reading `-dirty` once the `scripts/` edits are resolved too.
- `config/site/` is now the only copy of these values in the checkout (as for
  the mail keys since HC-12). It must be in the host backup.
- A host value deleted or a protected key edited in a tracked file cannot be
  carried over: the migration refuses until the operator chooses
  `--drop-key KEY` (upstream value applies, the local file stays in the backup).
- Overlay files are bash and are sourced: a syntax error there stops the deploy
  scripts with an error (`site_overlay_get` fails, no silent default), as it
  would have in the tracked file. The migration only writes files it has
  sourced successfully.
- Accepted risk: the deploy scripts themselves still source config and overlay
  files as root, as they always did with the tracked files. Whoever can edit the
  checkout can already change what the deploy runs; the migration does not add
  a new path to root.
- Not covered: `scripts/` edits (they need a review each, not a mechanical
  move); `config/*.example` and `r_env_manager.conf`.
- Tier deltas: T1 only. `docker-deploy/` already has its own self-contained
  `config/site/` overlay and its own `lib/common_utils.sh` (rule 4, vendored by
  Infra-Iam-PKI); it is unchanged. `kubernetes-deploy/` uses ConfigMaps.

## Alternatives considered

- **`git stash` / `git update-index --skip-worktree`** on the hosts: hides the
  edit but the pull still conflicts when upstream changes the file, and the
  values remain invisible to review. Rejected.
- **A private repo per host for `config/`**: more moving parts for four hosts;
  can still be added later on top of `config/site/` (SITE_OVERRIDE.md "Backups").
- **Textual diff of the tracked file into the overlay**: simple, but an
  unchanged line derived from a changed key (`TMP="${ROOT}/Rtmp"`) would keep
  the upstream value. The effective-configuration comparison catches exactly that.
