<!-- docs/operations/USER_MAIL_AD.md -->
---
title: "User e-mail from Active Directory: operations and troubleshooting"
audience: operator
status: current
tier: T1
source_path: docs/operations/USER_MAIL_AD.md
last_verified: 2026-11-17
---

# User e-mail from Active Directory

How the hosts choose the address of a user notice, how to configure and measure it,
and what to do when a notice goes to a guessed address. Decision record:
[ADR-0010](../adr/0010-user-email-from-active-directory.md).

## 1. What it does

Every user notice resolves the recipient with `resolve_user_email_source USER`
from `/etc/biome-calc/script/orphan_cleanup_helpers.sh`. The function prints
`<address> <source>`:

| Order | Source | Where the address comes from | Verified |
|---|---|---|---|
| 1 | `map` | `/etc/biome-calc/conf/user_email_map.txt` (`username address`) | yes, by the admin |
| 2 | `ad` | AD attribute `mail` of `sAMAccountName=USER`, read as root with the host keytab | yes, by AD |
| 3 | `pattern` | `USER@<each MAIL_DOMAINS_USER domain>` (CSV), else `USER@MAIL_DOMAIN` | **no** |

A `pattern` address is a guess. The relay `smtprelay.unibo.it` accepts it and drops
it without a bounce when it is wrong, so neither the user nor the admin learns
the notice was lost. The target is `pattern=0`, except for accounts that are not in AD.

Callers:

- `notify_r_orphans.sh` (orphan-cleanup notices, cron, root);
- `biome_node_maintenance.sh` drain/escalation notices (ADR-0009, PR #64), with the
  same function and the same settings.

The AD step never blocks or drops a notice. Every failure falls through to `pattern`,
which is the behaviour from before ADR-0010.

## 2. Fleet state

| Host | Applied | Backup (`/var/backups/biome-calc/`) | Verified |
|---|---|---|---|
| biome-calc04 | 2026-11-17 19:00 UTC | `user-mail-ad-hotfix-20261117T190044Z` | simulated notice `source=ad` |
| biome-calc03 | 2026-11-17 19:05 UTC | `user-mail-ad-hotfix-20261117T190544Z` | `ldap-utils` installed after the commit; simulated notice `source=ad` |
| biome-calc02 | 2026-11-17 20:40 UTC | `user-mail-ad-hotfix-20261117T204042Z` | `ldap-utils` installed first; `--check` and simulated notice `source=ad` |
| biome-calc01 | 2026-11-17 20:41 UTC | `user-mail-ad-hotfix-20261117T204110Z` | `--check` and simulated notice `source=ad` |

On every host, the only user that resolves by `pattern` is `gianfranco.samuele`,
an admin test account with no AD entry. That result is correct. The live record is
[HOTFIX_REGISTER](HOTFIX_REGISTER.md).

## 3. Configuration

| Key (in `r_orphan_cleanup.conf`) | Default | Meaning |
|---|---|---|
| `USER_MAIL_AD_URI` | empty (off) | `ldap://personale.dir.unibo.it`. Its host name is used for the `_ldap._tcp` SRV query, see §5.2 |
| `USER_MAIL_AD_BASE_DN` | empty (off) | `dc=personale,dc=dir,dc=unibo,dc=it` |
| `USER_MAIL_AD_TIMEOUT` | `10` | seconds, per `kinit` and per `ldapsearch` |
| `USER_MAIL_AD_MAX_DCS` | `3` | DCs tried, in SRV priority order |
| `USER_MAIL_AD_PRINCIPAL` | `HOSTNAME$` (upper case) | keytab principal; set it only if the keytab uses another name |

Source of truth: `config/site/setup_nodes.site.vars.conf` on each host (gitignored).
`50_setup_nodes.sh` renders the keys into `/etc/biome-calc/conf/r_orphan_cleanup.conf`.
If the site file has no AD keys, a redeploy renders them empty, which turns the
lookup off silently. After any redeploy, run `--check-notified` (§4).

Requirements on the host:

- packages `ldap-utils` (`ldapsearch`), `krb5-user` (`kinit`) and `bind9-host` or
  `dnsutils` (`host` or `dig`);
- a readable `/etc/krb5.keytab`, so the caller must be root;
- the host joined to `personale.dir.unibo.it`.

## 4. Measure and verify

Run from the source checkout or from a worktree of `main` (§6). None of these commands writes anything.

```bash
# one or more users: "USER ADDRESS SOURCE"; if the source is not ad, the reason follows
sudo bash scripts/fix_user_mail_ad_inplace.sh --check USER [USER...]

# every user with a pending or sent orphan notice; the metric is the last line
sudo bash scripts/fix_user_mail_ad_inplace.sh --check-notified
#   TOTAL n  map=a  ad=b  pattern=c

# end-to-end: the real notify script and resolver, with a FAKE send_email.sh
sudo bash scripts/tools/simulate_user_notice.sh USER
#   notify.log: SENDING | user=USER | to=ADDRESS | source=ad | ...
```

`--check` takes its settings from `--uri`/`--base-dn`, then from the site overlay,
then from the deployed conf. On an already patched host no option is needed.

What production logs, in `/var/log/biome-log/r_orphan_cleanup/notify.log`:

```text
... | SENDING | user=U | to=ADDR | source=ad | bcc=... | orphans=N
... | WARN | Address not verified (no map entry, no AD mail). user=U | to=ADDR
```

Count the guesses since a given date:

```bash
sudo grep -c 'source=pattern' /var/log/biome-log/r_orphan_cleanup/notify.log
sudo grep 'Address not verified' /var/log/biome-log/r_orphan_cleanup/notify.log | tail
```

## 5. Troubleshooting

### 5.1 A notice went to a `pattern` address

Run `--check USER`. The line after the result gives the reason (`ad: ...`):

| `ad:` reason | Cause | Fix |
|---|---|---|
| `lookup off (USER_MAIL_AD_URI/BASE_DN empty)` | keys missing from the deployed conf, or (before PR #67) `--check` run from a worktree | add the keys to the site file and run the hotfix `--commit` (§6). Check `grep ^USER_MAIL_AD_ /etc/biome-calc/conf/r_orphan_cleanup.conf` |
| `ldapsearch not installed` | `ldap-utils` missing (calc02 and calc03 lacked it before 2026-11-17) | `sudo apt install ldap-utils`. No redeploy needed |
| `kinit not installed` / `timeout not installed` | base packages missing | `sudo apt install krb5-user coreutils` |
| `username rejected (unsafe characters)` | login outside `[A-Za-z0-9._-]{1,64}` | add a map entry, by design |
| `no usable ldap:// or ldaps:// URI` | malformed `USER_MAIL_AD_URI` | fix the site file and run `--commit` |
| `kinit -k HOST$ failed (rc N): ...` | not root (keytab unreadable), broken machine trust, clock skew | run as root. If root also fails: TROUBLESHOOTING §3.2 (clock, `klist -k`), then §3.1 |
| `kinit timed out after Ns` | KDC unreachable | DNS/network to the DCs; `host -t SRV _kerberos._tcp.personale.dir.unibo.it` |
| `ldapsearch failed on every DC tried: <uri> rc N: ...` | see the per-DC error | §5.2 |
| `no AD account with sAMAccountName=U` | local or test account, or a typo | correct result. Add a map entry if the user must get mail |
| `account has no mail attribute` | AD entry without `mail` | ask the AD admins, or add a map entry |
| `mail attribute is not a plain address` | multi-valued or odd value | add a map entry. Report it to the AD admins |
| `lookup did not complete` | `mktemp` failed or the subshell was killed | check free space in `/tmp` and the system journal |

### 5.2 `Server not found in Kerberos database` (GSSAPI)

`personale.dir.unibo.it` resolves to 6 DC addresses. Two of them (10.21.25.7 and .8)
have no PTR record. When `ldapsearch` binds by the domain name, SASL canonicalises
the host through reverse DNS and asks the KDC for a service principal that does not
exist. On calc01 this failed on every try. On calc04 it worked only because
round-robin picked a DC with a correct PTR.

The resolver avoids this. It reads the DCs from `_ldap._tcp.<domain>` (SRV, by
priority) and binds to each one by its FQDN with `ldapsearch -N` (no
canonicalisation), so the service principal is `ldap/<DC fqdn>`. Never put a bare IP
in `USER_MAIL_AD_URI`.

Reproduce by hand, as root, with a private credential cache:

```bash
export KRB5CCNAME="FILE:$(mktemp -d)/cc"
kinit -k "$(hostname -s | tr a-z A-Z)\$"
host -t SRV _ldap._tcp.personale.dir.unibo.it        # list of DCs
ldapsearch -N -LLL -o ldif-wrap=no -Y GSSAPI -Q \
  -H ldap://dcrpersonale01.personale.dir.unibo.it \
  -b dc=personale,dc=dir,dc=unibo,dc=it "(sAMAccountName=USER)" mail
kdestroy; unset KRB5CCNAME
```

Pitfall: `sudo kinit` followed by `ldapsearch` as ladmin fails, because the two
commands use different credential caches. Run both in one root shell.

### 5.3 The notice was sent to the right address but the user did not get it

The address is correct when `source=ad`. In that case look at the relay, not the resolver:

```bash
sudo grep "user=U" /var/log/biome-log/r_orphan_cleanup/notify.log | tail
# SENDING ... -> SENT OK      relay accepted the message
# SENDING ... -> SEND FAILED  relay refused or unreachable: check SMTP_HOST/DNS_SERVERS in the conf
```

`SENT OK` means the relay accepted the message. After that, ask the user to check
spam and quarantine (Microsoft 365) before suspecting the host.

### 5.4 `--check` and the simulation disagree

Both scripts run the resolver from the checkout. The live cron runs the copy deployed
in `/etc/biome-calc/script/`. If the checkout is newer than the deployed copy, they
can disagree. Compare them:

```bash
cmp templates/orphan_cleanup_helpers.sh.template /etc/biome-calc/script/orphan_cleanup_helpers.sh
cmp templates/notify_r_orphans.sh.template /etc/biome-calc/script/notify_r_orphans.sh
```

A difference means the host needs the hotfix `--commit` again (idempotent) or a redeploy.

## 6. Apply, update, roll back

The hosts keep local changes in `config/*.vars.conf`, so a `git pull` can conflict.
Use a worktree of `main` instead:

```bash
cd /home/ladmin/configServices/R-studioConf
for b in ldapsearch kinit host; do command -v $b >/dev/null || echo "MISSING: $b"; done
git fetch origin && git worktree add /tmp/um-main origin/main && cd /tmp/um-main
SITE=/home/ladmin/configServices/R-studioConf/config/site/setup_nodes.site.vars.conf
AD="--uri ldap://personale.dir.unibo.it --base-dn dc=personale,dc=dir,dc=unibo,dc=it"
sudo FIX_USER_MAIL_SITE_VARS=$SITE bash scripts/fix_user_mail_ad_inplace.sh $AD --check-notified   # baseline
sudo FIX_USER_MAIL_SITE_VARS=$SITE bash scripts/fix_user_mail_ad_inplace.sh $AD             # dry-run + diff
sudo FIX_USER_MAIL_SITE_VARS=$SITE bash scripts/fix_user_mail_ad_inplace.sh $AD --commit    # prints the backup dir
sudo bash scripts/tools/simulate_user_notice.sh USER                                        # expect source=ad
grep -q '^USER_MAIL_AD_URI=' $SITE || printf '%s\n' \
  'USER_MAIL_AD_URI="ldap://personale.dir.unibo.it"' \
  'USER_MAIL_AD_BASE_DN="dc=personale,dc=dir,dc=unibo,dc=it"' | sudo tee -a $SITE
cd - && git worktree remove /tmp/um-main
```

- Check each binary on its own: `command -v a b c` succeeds when any one of them exists.
- `--commit` edits only the 3 keys of the conf and installs the helpers and the
  notify script. It restarts nothing and is idempotent ("Already applied").
- Roll back with `sudo bash scripts/fix_user_mail_ad_inplace.sh --rollback /var/backups/biome-calc/user-mail-ad-hotfix-<ts>`.
  This restores the 3 files byte for byte. An empty `USER_MAIL_AD_URI` in the conf is
  the quick off switch.
- Step 11b of `50_setup_nodes.sh` deploys the same files at the next release.
  The keys must be in the site file (last step above), otherwise that redeploy
  turns AD off.

## 7. Not covered

- The portal Problem Reporter (PR #58) asks the user for an address. Its `/api/` is
  not authenticated, so an AD lookup there could only be an admin-side check, never a
  prefill. It is a separate PR, not started.
- No cache: each notified user costs one `kinit` and up to `USER_MAIL_AD_MAX_DCS`
  `ldapsearch` calls. That is fine at today's volume (a few notices a day per host).
