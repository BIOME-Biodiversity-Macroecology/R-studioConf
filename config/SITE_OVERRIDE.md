# Site-local config overlay

Real, site-specific values (AD realm/KDCs/OUs, researcher PII, PI emails, SMTP
host, internal IPs) are **never committed**. The repo ships sanitized
`*.example` templates; the live host keeps real values in `config/site/`, which
is gitignored and therefore immune to `git pull` / history rewrites.

This is the same principle as the `.env` rule (HC-12), applied to config.

## Resolution order (enforced in `lib/common_utils.sh`)

`resolve_site_config <name> <config_dir>` returns:

1. `config/site/<name>` if it exists (real values), else
2. `config/<name>.example` (placeholders) **with a loud WARN**.

For the AD/Kerberos chain, `assert_site_configured` then **aborts** if a
required value is empty or still contains the `__FILL_ME__` sentinel — a fresh
clone fails fast instead of half-joining a domain with placeholder data.

## Files under the overlay

| Committed template | Real file (gitignored) | Tier |
|---|---|---|
| `lib_kerberos_setup.vars.conf.example` | `site/lib_kerberos_setup.vars.conf` | S2 (sourced, asserted) |
| `join_domain_sssd.vars.conf.example` | `site/join_domain_sssd.vars.conf` | S2 (sourced, asserted) |
| `join_domain_samba.vars.conf.example` | `site/join_domain_samba.vars.conf` | S2 (sourced, asserted) |
| `admin_recipients.txt.example` | `site/admin_recipients.txt` | S1 (copied) |
| `user_email_map.txt.example` | `site/user_email_map.txt` | S1 (copied) |
| `scopri_progetti_known.conf.example` | `site/scopri_progetti_known.conf` | S1 (copied) |
| `setup_nodes.site.vars.conf.example` | `site/setup_nodes.site.vars.conf` | S3 (6 keys, sourced after defaults) |

`setup_nodes.vars.conf` stays committed; only its 6 sensitive keys (SMTP_HOST,
SENDER_EMAIL, MAIL_DOMAIN, MAIL_DOMAINS_USER, SMTP_DNS_SERVERS, BIOME_CONTACT)
are sanitized and overridden by `site/setup_nodes.site.vars.conf`.
The site file may also set the optional AD e-mail lookup keys `USER_MAIL_AD_URI`,
`USER_MAIL_AD_BASE_DN` and `USER_MAIL_AD_TIMEOUT` (ADR-0010). They are rendered
into `/etc/biome-calc/conf/r_orphan_cleanup.conf` only; empty means AD lookup off.

## Host values for any `<name>.vars.conf` (ADR-0011)

Every committed `config/<name>.vars.conf` can have a gitignored companion
`config/site/<name>.site.vars.conf`, sourced right after it, so its assignments
win. One implementation, `lib/site_overlay.sh` (`site_overlay_source`,
`site_overlay_get`, `site_overlay_render`), is used by every T1 reader of
`configure_rstudio`, `install_nginx`, `install_secure_access` and
`setup_nodes`. The deployed `/etc/biome-calc/conf/setup_nodes.vars.conf` is
the committed file followed by the overlay's effective values, written as plain
`KEY="value"` lines (what `telemetry_api.py` can parse).

**Never edit a tracked `config/*.vars.conf` on a host**: a host value there
blocks `git pull --ff-only` as soon as upstream changes the file. To move
existing host edits: `scripts/fix_config_site_overlay_inplace.sh`, runbook
[`docs/operations/CONFIG_SITE_OVERLAY.md`](../docs/operations/CONFIG_SITE_OVERLAY.md).

Exceptions (rule 19, single source of truth): `RPROFILE_VERSION`,
`DEFAULT_R_VERSION` and `R_CORE_PACKAGES` are ignored in any overlay (with a
warning), and `pin_r_version.vars.conf` never takes one.

## First-time setup on a host

```bash
mkdir -p config/site
for f in lib_kerberos_setup.vars.conf join_domain_sssd.vars.conf \
         join_domain_samba.vars.conf admin_recipients.txt \
         user_email_map.txt scopri_progetti_known.conf setup_nodes.site.vars.conf; do
    cp "config/${f}.example" "config/site/${f}"
done
# then edit each config/site/* and replace every __FILL_ME__ with real values
grep -rl __FILL_ME__ config/site/   # must be empty when done
```

## Migrating the CURRENTLY deployed host (one-time)

The host already has real values in the tracked `config/*` files. Stage them
into `config/site/` **before** pulling the scrub commit, or the pull will delete
them. Full runbook: `plan/secret_scrub_site_overlay_plan.md` §4.

## Backups

`config/site/` is now the only copy of these values in this checkout (also of
the values moved there by `fix_config_site_overlay_inplace.sh`). Include it
in `/var/backups/r_env_manager/`, or mirror to a **private** repo.
