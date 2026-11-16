<!-- docs/operations/NODE_MAINTENANCE.md -->
# OS updates on a free node (runbook)

Decision and rationale: [ADR-0007](../adr/0007-os-updates-only-on-a-free-node.md)
(updates, rstudio-server restart) and
[ADR-0009](../adr/0009-reboot-on-a-free-node-with-drain-escalation.md) (opt-in
kernel reboot, drain emails, post-boot check).
Script: `scripts/biome_node_maintenance.sh`. Settings:
`config/node_maintenance.vars.conf`, with site overrides in
`config/site/node_maintenance.site.vars.conf`.

## What it changes

| Before | After |
|---|---|
| `apt-daily-upgrade.timer` runs unattended-upgrades at 06:00 + up to 60 min random | disabled; `biome-node-maintenance.timer` runs every 15 min, work only 03:30-05:00 |
| needrestart restarts `rstudio-server` after a library upgrade, which suspends every session | `/etc/needrestart/conf.d/biome-rstudio.conf` excludes it; the script restarts it only on a free node |
| no link with the R package sync | defers while `biome_pkg_sync.sh` holds `/run/lock/biome-pkg-sync.lock` |
| kernel updates installed but never running (calc02 up since 2026-08-24) | opt-in: reboot on a free node, on this host's weekday; `biome-node-postboot.service` checks the node after it |
| a blocked node only logs to the journal | opt-in: one email per night to the admin, then to the blocking users when a reboot is pending |

"Free" means the same as for the package sync: no `rsession` process and no `R`
process (`pgrep -x`). An R job in tmux or ssh keeps the node busy.

## Install on a host (in-place, idempotent)

Test host first (calc04), then the production hosts one at a time. As ladmin in
`/home/ladmin/configServices/R-studioConf`, on `main`, with an empty
`git status --short templates/`:

```bash
sudo bash scripts/biome_node_maintenance.sh --plan            # read-only: window, sessions, sync, apt, needrestart
sudo bash scripts/biome_node_maintenance.sh --install-timer
systemctl list-timers biome-node-maintenance.timer apt-daily-upgrade.timer
sudo needrestart -b | grep -c rstudio-server                   # whatever it says, it no longer restarts it
```

Check the next morning:

```bash
bash scripts/biome_node_maintenance.sh --status
journalctl -u biome-node-maintenance --since yesterday --no-pager | grep result:
journalctl -u rstudio-server --since yesterday --no-pager | grep -E "Stopping|Started"   # only inside 03:30-05:00
```

## Rollback

```bash
sudo bash scripts/biome_node_maintenance.sh --remove-timer
```

This removes the timer, the service and the needrestart fragment, and puts
`apt-daily-upgrade.timer` back in the state saved at install time. Reports in
`/var/lib/biome-node-maintenance/` are kept.

## Run results (`result:` line, `last_report.json`)

| status | exit | meaning |
|---|---|---|
| `done` | 0 | upgraded; `rstudio_restart` says whether rserver was restarted, `reboot` whether one is pending |
| `rebooting` | 0 | free node, reboot needed and allowed: `systemctl reboot` issued |
| `skipped` | 0 | `APT::Periodic::Unattended-Upgrade "0"` on this host (a pending reboot is still handled) |
| `deferred` | 75 | sessions / package sync / apt busy, or a restart pending; next slot retries |
| `overdue` | 75 | deferred for `MAINT_OVERDUE_NIGHTS`+ nights; also a journal warning |
| `failed` | 1 | unattended-upgrade, the rserver restart or `systemctl reboot` failed; see `/var/log/unattended-upgrades/` |

If the status is `overdue`, find who keeps the node busy
(`ps -eo user,etime,args | grep -E '[r]session|/[R] '`), warn them, then run once
under supervision: `sudo bash scripts/biome_node_maintenance.sh --force-window`.
This ignores the window and the done-marker, but **not** the session check.

A pending kernel (`needrestart_kernel_status` 2 or 3) is only reported while
`MAINT_REBOOT=false` (the default). Reboot by hand in a maintenance slot, or
enable the reboot below.

## Reboot on a free node and drain emails (ADR-0009, opt-in)

Everything is off by default, so `git pull` changes nothing on a host. Enable
it per host in `config/site/node_maintenance.site.vars.conf`, one host at a
time, calc04 first:

```bash
# config/site/node_maintenance.site.vars.conf (gitignored)
MAINT_REBOOT=true
MAINT_REBOOT_DAYS="1"            # date +%u: calc04 1 (Mon), calc03 2, calc02 3, calc01 4
MAINT_NOTIFY_ADMIN_NIGHTS=3      # 0 = off
MAINT_NOTIFY_USERS_NIGHTS=5      # 0 = off; needs MAINT_REBOOT=true
```

User addresses come from the shared resolver in
`/etc/biome-calc/script/orphan_cleanup_helpers.sh`. Its AD lookup (ADR-0010)
is configured in the setup site file, not here.

Prerequisites on the host:

- the R orphan notifier's mail setup is deployed
  (`/etc/biome-calc/conf/r_orphan_cleanup.conf`,
  `/etc/biome-calc/script/orphan_cleanup_helpers.sh` and `send_email.sh`);
- for AD addresses: the ADR-0010 resolver is deployed and `ldap-utils` is installed;
- after `git pull`, run `--install-timer` again: it adds
  `biome-node-postboot.service`. It is idempotent.

Check before enabling:

```bash
sudo bash scripts/biome_node_maintenance.sh --plan
```

`--plan` shows: whether a reboot is needed, the expected and running kernel,
whether today is a reboot day, who blocks the node, and, with user emails on,
the address each user would get and where it came from (`map`, `ad`, or
`pattern`, which is not verified).

Supervised first reboot: `sudo bash scripts/biome_node_maintenance.sh --force-window`.
It ignores the window and the reboot day, never the session check or
`MAINT_REBOOT`, and sends no email. After the node is back:

```bash
bash scripts/biome_node_maintenance.sh --status      # includes the last post-boot check
uname -r
journalctl -u biome-node-postboot -b --no-pager
```

What the job never does:

- kill or suspend a session;
- reboot twice for the same expected kernel (fix the GRUB default, see the
  error in the journal);
- email users when only updates (no reboot) are waiting.

Disable: set `MAINT_REBOOT=false` and the two `MAINT_NOTIFY_*` to `0` in the
site file. The next run uses the new values; nothing else to undo.

## Known limits

- With `session-timeout-minutes=10080` (calc01, 2026-10-28) an idle browser tab
  keeps an rsession alive for up to 7 days, so a node can stay "busy" for a long
  time. The repository value is 2880; aligning the hosts is open. The admin
  email shows the average CPU share per process, so idle sessions stand out.
- "Free" means no rsession and no R. A Python or other job started over ssh is
  not seen and would be cut by a reboot.
- A session that the server does suspend (idle timeout) still writes its
  environment to NFS. `99_check_rprofile_health.sh --user` warns at 256 MiB, and
  `--reset-profile --commit` is the reversible fix
  ([DIAGNOSTICS_INDEX](DIAGNOSTICS_INDEX.md)).
