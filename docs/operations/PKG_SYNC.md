<!-- docs/operations/PKG_SYNC.md -->
# Nightly R package sync across hosts

Decision: [ADR-0004](../adr/0004-replicated-local-r-libraries.md) step 4.
Script: `scripts/biome_pkg_sync.sh`. Settings: `config/pkg_sync.vars.conf`, with site
values in `config/site/pkg_sync.site.vars.conf` (gitignored).

Every night each host publishes the list of its `r-cran-*` packages to a shared
directory on biome-store03. When no R session is running, it installs the packages
the other hosts have and it lacks, after aligning the versions of what it has. It
never removes a package and never changes R itself.

## What it does, per timer slot (every 15 minutes, 03:00 … 04:45)

| Time | Action |
|---|---|
| any slot | write `hosts/<host>.json` (manifest) |
| 03:00, 03:15 | manifest only, so every host has published before any host reads |
| 03:30 – 04:45 | once per night: plan, then (mode `apply`) align versions + install missing |
| sessions running | exit 75 ("deferred"), the next slot retries (log: `retry at HH:MM`) |
| still busy at 04:45 | exit 75, log `last slot tonight, the sync moves to the next night` |
| after 05:00 | nothing starts; the next night runs (a missed night is not caught up) |
| an earlier slot still running | log `WARN another sync run is active: exiting`, exit 0; the next slot takes over. Harmless: the lock (`flock`) keeps two runs from overlapping |

The window is in `config/pkg_sync.vars.conf` (`PKG_SYNC_WINDOW_START=0300`,
`PKG_SYNC_APPLY_FROM=0330`, `PKG_SYNC_WINDOW_END=0500`). A run started at 04:45
can end after 05:00; at most 50 binary installs keep it short.

Refusals (exit 3, host unchanged): R not at the pinned version
(`config/pin_r_version.vars.conf`), a plan that removes packages, touches
`r-base*`/`r-recommended`, or upgrades a package without a saved `.deb`.

### Version alignment and partial rollback

The repository (r2u) keeps only the current build of most packages, so the old
`.deb` of a package about to be upgraded often cannot be downloaded again. By
default (`PKG_SYNC_ACCEPT_PARTIAL_ROLLBACK=false`) the alignment then refuses
the whole plan: the report reads `version_alignment: refused, unchanged`, and
only missing packages are installed. On calc04, 152 upgrades were refused this
way on 2026-11-16.

With `PKG_SYNC_ACCEPT_PARTIAL_ROLLBACK=true` in the host's site file, those
upgrades go ahead. The trade-off: `--rollback` of the alignment restores only the
packages whose old `.deb` was saved; the others stay at the new version. Set it
per host, after the host passed one night in `apply` without it:

```bash
grep -q '^PKG_SYNC_ACCEPT_PARTIAL_ROLLBACK=' config/site/pkg_sync.site.vars.conf \
  || echo 'PKG_SYNC_ACCEPT_PARTIAL_ROLLBACK=true' | sudo tee -a config/site/pkg_sync.site.vars.conf
```

## One-time setup

Whoever can write the shared directory decides what every host installs (from the
configured apt repositories only). So root on the four hosts writes it, and nobody
else does.

1. **On biome-store03, as root**: create a directory used only for this and
   export it to the four hosts only. Replace the path and the addresses with the
   real ones.

   ```bash
   install -d -o root -g root -m 0755 /srv/biome-pkg-sync
   install -d -o root -g root -m 0755 /srv/biome-pkg-sync/hosts /srv/biome-pkg-sync/reports
   # /etc/exports: root of the hosts stays root on this export only
   echo '/srv/biome-pkg-sync <calc01-ip>(rw,sync,no_subtree_check,no_root_squash) <calc02-ip>(rw,sync,no_subtree_check,no_root_squash) <calc03-ip>(rw,sync,no_subtree_check,no_root_squash) <calc04-ip>(rw,sync,no_subtree_check,no_root_squash)' >> /etc/exports
   exportfs -ra && exportfs -v | grep biome-pkg-sync
   ```

   If `no_root_squash` is not acceptable, use `all_squash,anonuid=<uid>,anongid=<gid>`
   with a dedicated account that owns the directory (`0755`): only these four
   hosts can reach the export, and on them only root runs the job.

   **Variant used on BIOME (TrueNAS, inside the home share):** biome-store03
   exports `/mnt/zpool/home` (mounted at `/nfs/home`, NFS 4.2, root not
   squashed), so the directory is `/nfs/home/.biome-pkg-sync`. The leading dot
   keeps it out of the user list, and Step 7c of `50_setup_nodes.sh` skips it
   because no account has that name. A directory created there inherits the
   share's NFSv4 ACL: on 2026-10-27 calc04 got mode `2775 root:domain_users`
   and six inherited entries (`fd`) giving write to AD groups, gid 33 and uid
   568. TrueNAS ignores `chmod` while such an ACL is set. `--init-dir` replaces
   the ACL first, then sets the mode. Run it once, on one host (calc04 first):

   ```bash
   cd /home/ladmin/configServices/R-studioConf
   sudo bash scripts/biome_pkg_sync.sh --init-dir /nfs/home/.biome-pkg-sync --test-user <researcher>
   ```

   It creates `hosts/` and `reports/`. It sets the NFSv4 ACL of the three
   directories to owner write and others read (`nfs4_setfacl`, from
   `nfs4-acl-tools`), then mode 755 without setgid. It writes
   `config/site/pkg_sync.site.vars.conf` (dry-run) if that file does not exist,
   then runs `--check-dir`. It is idempotent: a second run re-applies ACL and mode
   and keeps the manifests. To undo it, remove the directory and the site config.
   Without `nfs4-acl-tools`, use the TrueNAS UI instead: Edit Permissions on the
   directory, Strip ACL, owner root, mode 755, applied recursively.

   The same steps by hand, as done on 2026-10-27:

   ```bash
   D=/nfs/home/.biome-pkg-sync
   mkdir -p $D/hosts $D/reports
   for d in $D $D/hosts $D/reports; do nfs4_setfacl -s 'A::OWNER@:rwaDxtTnNcCy,A::GROUP@:rxtncy,A::EVERYONE@:rxtncy' $d; done
   chmod 0755 $D $D/hosts $D/reports
   nfs4_getfacl $D/hosts                       # 3 entries, none with w/a except OWNER@
   sudo -u <researcher> touch $D/hosts/probe   # must fail: Permission denied
   ```

   On the other three hosts the directory already exists: write the site config
   (step 3) and run `--check-dir` (step 4). Running `--init-dir` there also works:
   it only re-applies the same ACL and mode. Skip step 2: the share is already
   mounted. Result on 2026-10-27: all four hosts passed `--check-dir`.
2. **On every host, as root**: mount it at the same path.

   ```bash
   install -d -m 0755 /mnt/biome-pkg-sync
   echo 'biome-store03:/srv/biome-pkg-sync /mnt/biome-pkg-sync nfs defaults,_netdev,nofail,hard,timeo=600 0 0' >> /etc/fstab
   mount /mnt/biome-pkg-sync
   ```

3. **Site config** on every host, in `config/site/pkg_sync.site.vars.conf`:

   ```bash
   PKG_SYNC_DIR="/mnt/biome-pkg-sync"        # BIOME: /nfs/home/.biome-pkg-sync
   PKG_SYNC_MODE="dry-run"
   PKG_SYNC_TEST_USER="<a researcher account>"
   ```

4. **Check access from every host** (calc01, calc02, calc03, calc04):
   `sudo bash scripts/biome_pkg_sync.sh --check-dir`. It checks that the
   directory is an NFS mount, that root can write it, that it is not writable by
   group/others, that no NFSv4 ACL entry gives write to anyone but the owner
   (when `nfs4_getfacl` is installed), and that `nobody` and
   `PKG_SYNC_TEST_USER` cannot write it. `nobody` is in no AD group, so without
   `PKG_SYNC_TEST_USER` a group ACL would go unnoticed: the check warns. Then it publishes the
   host's manifest and lists the hosts that reached the directory: after the
   fourth host the list must show all four. Exit 1 means fix the export first.
5. **Timer**: `sudo bash scripts/biome_pkg_sync.sh --install-timer`, then
   `systemctl list-timers biome-pkg-sync.timer`.

## Rollout

State on 2026-10-27: shared directory ready, `--check-dir` passed on calc01-04,
timer installed on all four in `dry-run` (first run 2026-10-28 03:00 CET).
calc03 is on the pinned R since the same day.

1. **Two nights in `dry-run` on all four hosts.** Each morning, on any host:

   ```bash
   cd /home/ladmin/configServices/R-studioConf
   bash scripts/biome_pkg_sync.sh --status                         # fleet view, MODE column
   sudo journalctl -u biome-pkg-sync --since yesterday | tail -40  # this host's runs
   sudo jq '{finished_at, mode, status, note, n: (.installed_or_planned | length)}' /var/lib/biome-pkg-sync/last_report.json
   jq -r '.host + ": " + .status + " " + (.note // "")' /nfs/home/.biome-pkg-sync/reports/*.json
   ```

   Check: every host has a manifest from last night (MANIFEST column), status
   `dry-run` (or `deferred` when sessions ran past 04:45), and the planned
   packages make sense (no package you would not want on every host; exclude
   it in `policy.json` otherwise, see below).
2. **calc04 (test host) to `apply`**, the evening before. First check that the
   host checkout is on the current `main`: the timer runs the script from the
   checkout, so an old checkout runs old code. On 2026-11-17 calc03 was 37
   commits behind and its plan still failed on the `awk` bug fixed in PR #62.

   ```bash
   cd /home/ladmin/configServices/R-studioConf
   git fetch origin && git status -sb      # must not show [behind N]
   git pull --ff-only                      # if behind; it refuses if a locally modified file changed upstream
   sudo sed -i 's/^PKG_SYNC_MODE=.*/PKG_SYNC_MODE="apply"/' config/site/pkg_sync.site.vars.conf
   sudo bash scripts/biome_pkg_sync.sh --plan    # what tonight will do, changes nothing
   ```

   The next morning on calc04 (the run is after midnight, so use `--since today`
   and not a window counted back from the afternoon):

   ```bash
   sudo journalctl -u biome-pkg-sync --since today | grep -iE "result:|error|refused|WARN"
   sudo jq '{status, note, version_alignment, backup}' /var/lib/biome-pkg-sync/last_report.json
   sudo cat "$(sudo jq -r .backup /var/lib/biome-pkg-sync/last_report.json)/align_backup"  # alignment backup dir
   bash scripts/biome_pkg_sync.sh --status       # calc04 MISSING should have dropped
   ```

   Then a researcher test on calc04: log in to RStudio and load a few packages
   that arrived overnight (`library(<pkg>)`) plus `library(tidyverse)`. Also run
   `Rscript --vanilla -e 'for (p in rownames(installed.packages())) tryCatch(loadNamespace(p), error = function(e) cat("FAIL", p, conditionMessage(e), "\n"))'`
   and compare with the previous day (only already-failing packages such as
   `loadeR` may appear).
   If something broke:

   ```bash
   sudo sed -i 's/^PKG_SYNC_MODE=.*/PKG_SYNC_MODE="dry-run"/' config/site/pkg_sync.site.vars.conf
   sudo bash scripts/biome_pkg_sync.sh --rollback /var/backups/biome-calc/r-pkg-sync-<ts>
   sudo bash scripts/fix_r_pkg_versions_inplace.sh --rollback /var/backups/biome-calc/r-pkg-align-<ts>
   ```

3. **calc01-03 to `apply`, one host per night**, same commands and checks.
   calc03 first: it is the furthest behind (266 missing).
4. **Done** when `--status` reads 0 versions differing, 0 missing, 1 R version,
   for several nights in a row. To stop the job at any time:
   `sudo bash scripts/biome_pkg_sync.sh --remove-timer`.

Metric: `--status` prints packages that differ in version, the sum of missing
packages and the number of R versions. Target 0 / 0 / 1.

During the rollout the packages that differ in version go **up**, and that is
expected: the hosts in `apply` move to the current r2u builds (alignment and
new installs), while the hosts still in `dry-run` keep their old versions. The
number falls only when every host is in `apply`. A host's missing count can
also rise for a night, when another host installed new dependencies. Baseline 2026-10-15
(`99_check_pkg_host_drift.sh`): 426 of 690 packages drift.

Baseline from `--status`, 2026-10-27 14:28 UTC, all hosts in dry-run, after the
calc03 R upgrade: 162 packages differ in version, 725 missing (sum over hosts),
1 R version (4.6.0).

| Host | r-cran-* | missing | not apt |
|---|---|---|---|
| biome-calc01 | 667 | 26 | 9 |
| biome-calc02 | 513 | 180 | 11 |
| biome-calc03 | 427 | 266 | 12 |
| biome-calc04 | 440 | 253 | 12 |

With `PKG_SYNC_MAX_NEW=50`, calc03 needs about six nights in `apply` to close
its gap.

State on 2026-11-25 (`--status` after the night): 44 packages differ in
version, 27 missing, 1 R version (on 2026-11-19: 190, 281, 1; on 2026-10-27:
162, 725).

| Host | Mode | r-cran-* | missing | In `apply` since |
|---|---|---|---|---|
| biome-calc01 | apply, partial rollback (deferred every slot so far) | 682 | 27 | 2026-11-24 |
| biome-calc02 | apply, partial rollback | 709 | 0 | 2026-11-19 |
| biome-calc03 | apply, partial rollback | 709 | 0 | 2026-11-17 |
| biome-calc04 | apply, partial rollback | 709 | 0 | 2026-11-16 |

Every night that applied ended with `status: done`, alignment `done`, and
0 packages failing to load (calc04 631/631 on 2026-11-17, calc03 648/648 on
2026-11-19).

A host where sessions stay open all night never applies: every slot from 03:30
to 04:45 logs `result: deferred: N RStudio session(s), M R process(es) running`
and the last one says `the sync moves to the next night`. `--force-window`
does not skip this check; nothing installs while R runs. calc01 deferred all
of 2026-11-25 with 4 sessions and 32 R processes. If that repeats, find who
holds them (`ps -o user=,etime=,cmd= -C rsession`) and agree a free night with
those users, or run `--force-window` by hand once they have closed.

## Manual run and rollback

```bash
sudo bash scripts/biome_pkg_sync.sh --plan                 # publish + plan, no change
sudo bash scripts/biome_pkg_sync.sh --force-window         # one run now (mode from config)
sudo bash scripts/biome_pkg_sync.sh --rollback /var/backups/biome-calc/r-pkg-sync-<ts>
sudo bash scripts/fix_r_pkg_versions_inplace.sh --rollback /var/backups/biome-calc/r-pkg-align-<ts>
sudo bash scripts/biome_pkg_sync.sh --remove-timer         # stop the job
```

`--rollback` removes exactly what that run installed and refuses if apt would also
remove anything else. Version alignment has its own backup, named in the run's
`align_backup` file.

## Excluding a package

`<PKG_SYNC_DIR>/policy.json`:

```json
{"exclude": ["r-cran-somepkg"]}
```

## Files

| Path | Content |
|---|---|
| `<PKG_SYNC_DIR>/hosts/<host>.json` | manifest: `r-cran-*` with versions, R version, packages apt does not manage |
| `<PKG_SYNC_DIR>/reports/<host>.json` | last run: status, note, what it installed or planned, packages not in apt |
| `/var/lib/biome-pkg-sync/` | `last_report.json`, `done_date` |
| `/var/backups/biome-calc/r-pkg-sync-<ts>/` | `before.tsv`, `after.tsv`, `new.tsv`, `install.log`, `align.log` |
