<!-- docs/adr/0009-reboot-on-a-free-node-with-drain-escalation.md -->
# ADR-0009: Kernel reboots on a free node, with drain escalation by email

Status: Proposed (PR; off by default, not enabled on any host)
Date: 2026-11-16
Extends: [ADR-0007](0007-os-updates-only-on-a-free-node.md)

## Context

ADR-0007 moved OS updates to 03:30-05:00 on a free node and stopped needrestart
from restarting rstudio-server. Since its rollout (calc01-03 on 2026-11-14) the
journals show no daytime restarts on any host. ADR-0007 deliberately only
*reported* a pending kernel and never rebooted.

That leaves a gap: on 2026-11-16 `journalctl --list-boots` on biome-calc02 showed
the current boot started on 2026-08-24. Every kernel update installed since then
is on disk but not running, which includes kernel security fixes. Nothing reboots
the nodes except an operator, and an operator cannot see when a node is free at
night.

A node can stay busy for days. One reason is a computation that really runs for
days. The other is an idle RStudio tab: with `session-timeout-minutes=10080` on
the hosts, an rsession survives up to 7 days without activity. ADR-0007 already
logs a warning after `MAINT_OVERDUE_NIGHTS`, but the warning goes to the journal,
where nobody looks, and the blocking users are never told.

The nodes are Proxmox VMs, so the operator has a console if a node does not come
back.

## Decision

1. **Reboot only on a free node, opt-in per host.** With `MAINT_REBOOT=true`
   in the host's site file, a run that finds a reboot needed (needrestart kernel
   status 2 or 3, or `/var/run/reboot-required`) reboots the node, on these
   conditions:
   - the ADR-0007 gates hold: inside the window, no rsession, no R process, the
     package sync idle, apt idle;
   - today is one of `MAINT_REBOOT_DAYS`. Each host gets a different weekday, so
     two nodes are never down at the same time;
   - the node is still free `MAINT_REBOOT_RECHECK_SECONDS` (60) later.
   The default is `false`. The timer runs the script from the host checkout, so
   a `git pull` alone never enables reboots.
2. **No boot loop.** The kernel needrestart expects (`NEEDRESTART-KEXP`) is saved
   before the reboot. If the next run finds the same kernel still expected and
   not running, it refuses to reboot again and logs an error. The usual cause is
   a GRUB default that points at the old kernel.
3. **Check after boot.** `biome-node-postboot.service` runs at every boot and
   acts only after a reboot this script requested. For up to
   `MAINT_POSTBOOT_TIMEOUT` (300 s) it checks:
   - rstudio-server is active;
   - sssd is active;
   - every NFS mount in `/etc/fstab` is mounted (`noauto` entries excluded);
   - the expected kernel is running.
   The result goes to `postboot_report.json`. A failure is logged at priority
   err and mailed to the admin recipients.
4. **Drain escalation, never a kill.** While the node stays busy, emails go out
   at most once per night of each kind, and never on a supervised
   `--force-window` run:
   - **Admin**, after `MAINT_NOTIFY_ADMIN_NIGHTS` nights in a row: who blocks
     the node, with process, age and average CPU share. A share near 0% means
     an idle session.
   - **Users**, after `MAINT_NOTIFY_USERS_NIGHTS` nights with a reboot pending,
     and only with `MAINT_REBOOT=true`, so nobody is asked to leave for a reboot
     that will never happen: save your work (`saveRDS()`), quit the session
     (File > Quit Session), continue on another node; reply to the admin if a
     computation must keep running.
   Both thresholds default to 0 (off). Updates alone never email users.
5. **Mail reuses the R orphan notifier.** It uses the same relay, sender and
   admin recipients (`/etc/biome-calc/conf/r_orphan_cleanup.conf`), the same
   `send_email.sh`, and the same `user_email_map.txt`. A user's address is
   resolved in this order:
   1. the `user_email_map.txt` override;
   2. the AD attribute `mail`, read with the node's own keytab (`kinit -k HOST$`,
      private credential cache, removed after use), when `MAINT_AD_LDAP_URI` and
      `MAINT_AD_BASE_DN` are set;
   3. the `MAIL_DOMAINS_USER` pattern.

   The source of each address is logged. A `pattern` address is not verified,
   and the relay drops bounces silently.

## Consequences

- Kernel fixes become active within a week on hosts that are free at night,
  without an operator.
- A reboot ends nothing that is running: only a node with zero rsession and zero
  R processes reboots. Suspended sessions on NFS are not affected by a reboot.
- A user who keeps a session open blocks the reboot indefinitely. This is by
  design. The emails make the cost visible, and the admin decides.
- "Free" still means no rsession and no R. A Python or other job started over
  ssh does not count and would be cut by a reboot. This limit was already
  accepted for package changes in ADR-0004 and ADR-0007, and it matters more
  for a reboot. Mitigation: the reboot day is known, and the admin email names
  the node beforehand.
- A node that does not come back needs the Proxmox console. The post-boot
  check reports the cases it can see.
- New dependency: `ldap-utils`, only for the AD lookup. It is in the
  `50_setup_nodes.sh` base packages; existing hosts need `apt install ldap-utils`.
- A suspended RStudio session is never used to move work. Restoring a 765 MB
  suspended environment is what blocked a login on 2026-10-28. Users are asked
  to save and restart instead.

## Alternatives considered

- **Reboot whenever needed, killing sessions after a notice.** Rejected: a
  research computation can run for days, and an automatic kill loses it.
- **Suspend idle sessions before the reboot** (`rstudio-server suspend-session`).
  Rejected for now: it writes the R environment to NFS, which is the failure
  mode of 2026-10-28.
- **Kernel livepatch** (Canonical Livepatch). Rejected for now: it needs an
  Ubuntu Pro subscription, is not open source on the service side, covers only
  some CVEs, and still needs reboots for the rest.
