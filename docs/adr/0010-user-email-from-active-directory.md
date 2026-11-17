<!-- docs/adr/0010-user-email-from-active-directory.md -->
# ADR-0010: User notification e-mail from the Active Directory `mail` attribute

Status: Accepted. Applied on biome-calc01-04 on 2026-11-17 (PR #65, #66, #67); runbook [USER_MAIL_AD.md](../operations/USER_MAIL_AD.md)
Date: 2026-11-16

## Context

Orphan-cleanup notices (`notify_r_orphans.sh`) and, from ADR-0009, the
maintenance drain notices go to researchers by e-mail. Until now the address came
from `resolve_user_email()` in `templates/orphan_cleanup_helpers.sh.template`:

1. an explicit entry in `user_email_map.txt`;
2. otherwise `username@<each domain in MAIL_DOMAINS_USER>`, as a CSV;
3. otherwise `username@MAIL_DOMAIN`.

Step 2 is a guess. The relay accepts every address and drops the wrong ones
without a bounce, so a wrong guess fails silently: the researcher never gets the
notice and the admin never learns it. Nothing in the code knew the real address.

The real address is in AD. Verified on biome-calc04 on 2026-11-16 as root with
the host keytab and a private credential cache:
`kinit -k 'BIOME-CALC04$'` then `ldapsearch -Y GSSAPI ... "(sAMAccountName=martina.livornese2)" mail`
returns `mail: martina.livornese2@unibo.it`. Running `kinit` under sudo and
`ldapsearch` as another user fails (different credential cache).

## Decision

1. One resolver for every user e-mail, in `orphan_cleanup_helpers.sh`:
   `resolve_user_email_source USER [DEFAULT_DOMAIN]` prints `<address> <source>`
   with source `map`, `ad` or `pattern`. Order: map, then AD, then the old
   pattern. `resolve_user_email` keeps its interface and prints the address only.
   `biome_node_maintenance.sh` (ADR-0009) calls the same function instead of its
   own lookup.
2. The AD step (`ad_lookup_user_mail`) binds with the host keytab (principal
   `HOSTNAME$`, GSSAPI), in a private `mktemp -d` credential cache removed after
   the call. It runs only when `USER_MAIL_AD_URI` and `USER_MAIL_AD_BASE_DN` are
   set in `r_orphan_cleanup.conf` (from the site overlay). `kinit` and
   `ldapsearch` each have a timeout (`USER_MAIL_AD_TIMEOUT`, default 10 s).
   The domain controllers come from the `_ldap._tcp.<domain>` SRV record of
   the URI's host (priority order, at most `USER_MAIL_AD_MAX_DCS`, default 3)
   and `ldapsearch -N` binds to each by its FQDN, so the Kerberos service
   principal is `ldap/<DC fqdn>`. Reason: on calc01 (2026-11-17) the domain
   name resolved to 6 DC IPs, two without a PTR record; SASL's reverse-DNS
   canonicalisation then asked for an unknown principal ("Server not found in
   Kerberos database"), so the plain `ldap://<domain>` URI worked only when
   round-robin picked a DC with a correct PTR (it did on calc04).
3. Every failure falls through to the pattern: AD keys empty, `ldap-utils`
   missing, not root, keytab unreadable, AD unreachable, timeout, no `mail`
   attribute, malformed value. A lookup never blocks or drops a notice.
4. The username must match `^[A-Za-z0-9._-]{1,64}$` before it reaches the LDAP
   filter (no filter injection); the returned value must be one plain address.
5. Each notice logs its source (`source=map|ad|pattern`); a `pattern` address
   also logs a `WARN ... not verified` line, so the admin can count guesses.
6. Existing hosts get it in place with `scripts/fix_user_mail_ad_inplace.sh`
   (dry-run, `--commit`, `--rollback`, `--check` to measure).

## Consequences

- Notices reach the address AD holds for the account, including users whose
  address differs from the login. The map still wins, for exceptions.
- New runtime dependency on AD and the host keytab; when either is down the
  behaviour is exactly the old one. `ldap-utils` must be installed (base package
  list in `50_setup_nodes.sh`, added with ADR-0009; `apt install ldap-utils` on
  existing hosts).
- Each notified user costs one `kinit`, one SRV query and one `ldapsearch`
  per DC tried (worst case `(1 + USER_MAIL_AD_MAX_DCS) × timeout`).
- `--check` / `--check-notified` and `simulate_user_notice.sh` print why AD
  gave no address (`USER_MAIL_AD_DEBUG=1`: kinit error, per-DC ldapsearch
  error, unknown account, no `mail`). The notify script resolves only users that get a mail.
- The notify scripts run as root (cron), which is what reading
  `/etc/krb5.keytab` needs. Non-root callers silently get the pattern.
- Not in scope: the portal problem report (#58). Its `/api/` endpoint is not
  behind authentication, so the login it receives is unverified; using AD there
  is useful only to show the admin the AD address for that login, never to
  prefill the form (that would expose any user's address). Separate PR.

## Metrics

Baseline and after, per host: `fix_user_mail_ad_inplace.sh --check-notified`
prints `TOTAL n map=a ad=b pattern=c` for every user with a pending or sent
orphan notice. Before the hotfix `ad=0`; the goal is `pattern=0` except for
accounts without a `mail` attribute.
