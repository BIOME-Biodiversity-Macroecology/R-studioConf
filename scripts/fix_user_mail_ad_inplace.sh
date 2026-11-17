#!/usr/bin/env bash
set -euo pipefail
# scripts/fix_user_mail_ad_inplace.sh
#
# IN-PLACE HOTFIX: send user notification e-mails to the address stored in
# Active Directory (attribute `mail`) instead of a guessed username@domain.
#
# Why: resolve_user_email() used only user_email_map.txt, then composed
#   username@<each MAIL_DOMAINS_USER domain>. The relay accepts and silently
#   drops wrong addresses, so users whose AD mail differs from the pattern
#   (e.g. login martina.livornese2, mail on another domain or alias) never got
#   the orphan-cleanup notices. New order: map -> AD mail -> pattern.
#
# What it changes (nothing else is touched, no service restart):
#   * EDIT /etc/biome-calc/conf/r_orphan_cleanup.conf: sets USER_MAIL_AD_URI,
#          USER_MAIL_AD_BASE_DN, USER_MAIL_AD_TIMEOUT (other lines kept as is)
#   * COPY templates/orphan_cleanup_helpers.sh.template
#          -> /etc/biome-calc/script/orphan_cleanup_helpers.sh
#   * COPY templates/notify_r_orphans.sh.template
#          -> /etc/biome-calc/script/notify_r_orphans.sh
#
# Values come from config/site/setup_nodes.site.vars.conf (USER_MAIL_AD_URI,
# USER_MAIL_AD_BASE_DN, optional USER_MAIL_AD_TIMEOUT) or from --uri/--base-dn.
#
# Safety:
#   * dry-run by default; --commit applies; --rollback DIR restores.
#   * backup + manifest in ${BACKUP_ROOT}/user-mail-ad-hotfix-<ts>/ BEFORE any write.
#   * every file is written to a temp name in its directory, then mv (atomic).
#   * new helpers/notify are syntax-checked (bash -n) before install; after
#     install a failed check rolls everything back automatically (exit 1).
#   * the AD lookup itself never blocks a mail: any error falls back to the
#     old pattern, so the worst case equals today's behaviour.
#
# Measure (baseline before --commit, value after):
#   sudo bash scripts/fix_user_mail_ad_inplace.sh --check USER [USER...]
#   prints "USER ADDRESS SOURCE" for each user using the NEW resolver and the
#   settings above, without changing anything. --check-notified does the same
#   for every user with a pending or sent orphan notification log.
#
# Usage:
#   sudo bash scripts/fix_user_mail_ad_inplace.sh                 # dry-run
#   sudo bash scripts/fix_user_mail_ad_inplace.sh --commit
#   sudo bash scripts/fix_user_mail_ad_inplace.sh --rollback DIR
#   Options: --uri URI --base-dn DN --timeout SECONDS
#            --check USER...   --check-notified   -h|--help
#   Env:     FIX_USER_MAIL_ROOT        (default "", prefix for every path; tests only)
#            FIX_USER_MAIL_BACKUP_ROOT (default /var/backups/biome-calc)
#            FIX_USER_MAIL_SITE_VARS   (default config/site/setup_nodes.site.vars.conf)
#
# Exit codes:
#   0 applied, already applied, dry-run, checked or rolled back
#   1 refused or failed (rolled back where stated)
#   2 usage error

readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_BOLD='\033[1m'
readonly C_RESET='\033[0m'

log_info()  { printf '%b[INFO]%b %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_ok()    { printf '%b[ OK ]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()  { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%b[FAIL]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_head()  { printf '\n%b== %s ==%b\n' "$C_BOLD" "$*" "$C_RESET"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

R="${FIX_USER_MAIL_ROOT:-}"
BACKUP_ROOT="${FIX_USER_MAIL_BACKUP_ROOT:-/var/backups/biome-calc}"
SITE_VARS="${FIX_USER_MAIL_SITE_VARS:-${WORKSPACE_ROOT}/config/site/setup_nodes.site.vars.conf}"

CONF="${R}/etc/biome-calc/conf/r_orphan_cleanup.conf"
SCRIPT_D="${R}/etc/biome-calc/script"
NOTIFY_LOG_DIR="${R}/var/log/biome-log/r_orphan_cleanup/notifications"
SRC_HELPERS="${WORKSPACE_ROOT}/templates/orphan_cleanup_helpers.sh.template"
SRC_NOTIFY="${WORKSPACE_ROOT}/templates/notify_r_orphans.sh.template"
DST_HELPERS="${SCRIPT_D}/orphan_cleanup_helpers.sh"
DST_NOTIFY="${SCRIPT_D}/notify_r_orphans.sh"

usage() { sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'; }

MODE="dry-run"
ROLLBACK_DIR=""
OPT_URI=""; OPT_BASE=""; OPT_TIMEOUT=""
CHECK_USERS=()
CHECK_NOTIFIED=false
while (($#)); do
  case "$1" in
    --commit)   MODE="commit" ;;
    --rollback) MODE="rollback"; ROLLBACK_DIR="${2:-}"; shift || true ;;
    --uri)      OPT_URI="${2:-}"; shift || true ;;
    --base-dn)  OPT_BASE="${2:-}"; shift || true ;;
    --timeout)  OPT_TIMEOUT="${2:-}"; shift || true ;;
    --check)    MODE="check"; shift
                while (($#)) && [[ "$1" != --* ]]; do CHECK_USERS+=("$1"); shift; done
                continue ;;
    --check-notified) MODE="check"; CHECK_NOTIFIED=true ;;
    -h|--help)  usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

for bin in awk grep cut tr mktemp cp mv sha256sum date; do
  command -v "$bin" >/dev/null 2>&1 || { log_error "Missing required binary: $bin"; exit 1; }
done

site_value() {  # KEY -> value from the site overlay (not sourced: grep|cut)
  [[ -f "$SITE_VARS" ]] || return 0
  grep -E "^${1}=" "$SITE_VARS" | tail -1 | cut -d= -f2- | tr -d '"' || true
}

# ── Rollback ────────────────────────────────────────────────────────────────
do_rollback() {  # DIR
  local dir="$1" rel
  [[ -n "$dir" && -f "${dir}/MANIFEST" ]] || { log_error "No MANIFEST in '${dir}'"; return 1; }
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    if [[ -f "${dir}/files${rel}" ]]; then
      cp -p "${dir}/files${rel}" "${R}${rel}.rollback.$$" && mv -f "${R}${rel}.rollback.$$" "${R}${rel}"
      log_ok "Restored ${R}${rel}"
    else
      rm -f "${R}${rel}"
      log_ok "Removed ${R}${rel} (did not exist before)"
    fi
  done < "${dir}/MANIFEST"
}

if [[ "$MODE" == "rollback" ]]; then
  [[ "$(id -u)" -eq 0 || -n "$R" ]] || { log_error "Run as root"; exit 1; }
  do_rollback "$ROLLBACK_DIR" || exit 1
  log_ok "Rollback complete"
  exit 0
fi

# ── Settings ────────────────────────────────────────────────────────────────
AD_URI="${OPT_URI:-$(site_value USER_MAIL_AD_URI)}"
AD_BASE="${OPT_BASE:-$(site_value USER_MAIL_AD_BASE_DN)}"
AD_TIMEOUT="${OPT_TIMEOUT:-$(site_value USER_MAIL_AD_TIMEOUT)}"
AD_TIMEOUT="${AD_TIMEOUT:-10}"
[[ "$AD_TIMEOUT" =~ ^[0-9]+$ && "$AD_TIMEOUT" -gt 0 ]] || { log_error "--timeout must be a positive integer"; exit 2; }
for v in "$AD_URI" "$AD_BASE"; do
  [[ "$v" != *'"'* && "$v" != *'$'* && "$v" != *'`'* && "$v" != *\\* ]] \
    || { log_error "Refusing a value with quotes, \$, backticks or backslashes: $v"; exit 2; }
done
[[ -z "$AD_URI" || "$AD_URI" =~ ^ldaps?:// ]] || { log_error "USER_MAIL_AD_URI must start with ldap:// or ldaps://"; exit 2; }

# ── Check mode (measure; read-only) ─────────────────────────────────────────
if [[ "$MODE" == "check" ]]; then
  if $CHECK_NOTIFIED; then
    # Notification dirs: the one in the deployed conf (NOTIFY_DIR), plus the
    # legacy /var/log/r_orphan_cleanup tree that 50_setup_nodes.sh also creates.
    conf_notify=""
    if [[ -f "$CONF" ]]; then
      conf_notify="$(grep -E '^NOTIFY_DIR=' "$CONF" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
      conf_log="$(grep -E '^LOG_DIR=' "$CONF" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
      conf_notify="${conf_notify//\$\{LOG_DIR\}/$conf_log}"
    fi
    dirs=()
    for d in ${conf_notify:+"${R}${conf_notify}"} "$NOTIFY_LOG_DIR" "${R}/var/log/r_orphan_cleanup/notifications"; do
      [[ -d "$d" ]] || continue
      [[ " ${dirs[*]:-} " == *" $d "* ]] || dirs+=("$d")
    done
    log_info "Notification dirs scanned: ${dirs[*]:-none found}"
    if ((${#dirs[@]})); then
      while IFS= read -r u; do [[ -n "$u" ]] && CHECK_USERS+=("$u"); done < <(
        find "${dirs[@]}" -maxdepth 2 -name '*.log' 2>/dev/null \
          | sed -E 's#.*/##; s/\.log$//; s/_[0-9]{8}$//' | grep -v '+$' | sort -u || true)
    fi
    if ((${#CHECK_USERS[@]} == 0)); then
      log_info "No pending or sent orphan notice on this host: nothing to measure"
      printf 'TOTAL 0  map=0  ad=0  pattern=0\n'
      exit 0
    fi
  fi
  ((${#CHECK_USERS[@]})) || { log_error "--check needs at least one user (or use --check-notified)"; exit 2; }
  [[ -n "$AD_URI" && -n "$AD_BASE" ]] || log_warn "USER_MAIL_AD_URI/BASE_DN not set: every user resolves by map or pattern"
  command -v ldapsearch >/dev/null 2>&1 || log_warn "ldapsearch not installed (apt install ldap-utils): AD step will be skipped"
  [[ "$(id -u)" -eq 0 ]] || log_warn "Not root: the host keytab is unreadable, AD step will be skipped"
  declare -A count=()
  for u in "${CHECK_USERS[@]}"; do
    line="$(
      set +u
      # shellcheck source=/dev/null
      if [[ -f "$CONF" ]]; then source "$CONF"; fi
      # shellcheck source=/dev/null
      source "$SRC_HELPERS"
      USER_MAIL_AD_URI="$AD_URI" USER_MAIL_AD_BASE_DN="$AD_BASE" USER_MAIL_AD_TIMEOUT="$AD_TIMEOUT" \
        USER_EMAIL_MAP_FILE="${R}/etc/biome-calc/conf/user_email_map.txt" \
        resolve_user_email_source "$u" "${MAIL_DOMAIN:-}"
    )"
    printf '%s %s\n' "$u" "$line"
    src="${line##* }"; count[$src]=$(( ${count[$src]:-0} + 1 ))
  done
  printf 'TOTAL %d  map=%d  ad=%d  pattern=%d\n' "${#CHECK_USERS[@]}" "${count[map]:-0}" "${count[ad]:-0}" "${count[pattern]:-0}"
  exit 0
fi

# ── Pre-checks ──────────────────────────────────────────────────────────────
log_head "Pre-checks"
[[ "$(id -u)" -eq 0 || -n "$R" ]] || { log_error "Run as root"; exit 1; }
[[ -f "$CONF" ]] || { log_error "Not found: $CONF (run 50_setup_nodes.sh first)"; exit 1; }
[[ -d "$SCRIPT_D" ]] || { log_error "Not found: $SCRIPT_D"; exit 1; }
for f in "$SRC_HELPERS" "$SRC_NOTIFY"; do
  [[ -f "$f" ]] || { log_error "Not found: $f"; exit 1; }
  bash -n "$f" || { log_error "Syntax error in $f"; exit 1; }
done
if [[ -z "$AD_URI" || -z "$AD_BASE" ]]; then
  log_error "USER_MAIL_AD_URI and USER_MAIL_AD_BASE_DN are not set in ${SITE_VARS} (or use --uri/--base-dn)"
  exit 1
fi
command -v ldapsearch >/dev/null 2>&1 || log_warn "ldapsearch not installed: install ldap-utils, until then the AD step is skipped (fallback = today's behaviour)"
command -v kinit >/dev/null 2>&1 || log_warn "kinit not installed: the AD step is skipped"
log_ok "AD lookup: uri=${AD_URI} base=${AD_BASE} timeout=${AD_TIMEOUT}s"

# Render the new conf: drop any previous USER_MAIL_AD_* lines, append the block
NEW_CONF="$(mktemp "${CONF}.new.XXXXXX")"
trap 'rm -f "${NEW_CONF:-}" "${DST_HELPERS}.new.$$" "${DST_NOTIFY}.new.$$"' EXIT
grep -vE '^USER_MAIL_AD_(URI|BASE_DN|TIMEOUT)=|^# ── User e-mail from Active Directory' "$CONF" > "$NEW_CONF" || true
{
  echo '# ── User e-mail from Active Directory (fix_user_mail_ad_inplace.sh) ──'
  printf 'USER_MAIL_AD_URI="%s"\n' "$AD_URI"
  printf 'USER_MAIL_AD_BASE_DN="%s"\n' "$AD_BASE"
  printf 'USER_MAIL_AD_TIMEOUT="%s"\n' "$AD_TIMEOUT"
} >> "$NEW_CONF"
bash -n "$NEW_CONF" || { log_error "Rendered conf does not parse"; exit 1; }

changed=()
cmp -s "$NEW_CONF" "$CONF" || changed+=("/etc/biome-calc/conf/r_orphan_cleanup.conf")
cmp -s "$SRC_HELPERS" "$DST_HELPERS" 2>/dev/null || changed+=("/etc/biome-calc/script/orphan_cleanup_helpers.sh")
cmp -s "$SRC_NOTIFY" "$DST_NOTIFY" 2>/dev/null || changed+=("/etc/biome-calc/script/notify_r_orphans.sh")

if ((${#changed[@]} == 0)); then
  log_ok "Already applied: nothing to do"
  exit 0
fi

log_head "Changes"
for rel in "${changed[@]}"; do log_info "would update ${R}${rel}"; done
if [[ "$MODE" == "dry-run" ]]; then
  diff -u "$CONF" "$NEW_CONF" || true
  log_info "Dry-run: nothing written. Re-run with --commit to apply."
  exit 0
fi

# ── Backup ──────────────────────────────────────────────────────────────────
log_head "Backup"
BK="${BACKUP_ROOT}/user-mail-ad-hotfix-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${BK}/files" || { log_error "Cannot create ${BK}"; exit 1; }
chmod 700 "$BK" || { log_error "chmod on ${BK} failed"; exit 1; }
for rel in "${changed[@]}"; do
  echo "$rel" >> "${BK}/MANIFEST"
  if [[ -f "${R}${rel}" ]]; then
    mkdir -p "${BK}/files$(dirname "$rel")"
    cp -p "${R}${rel}" "${BK}/files${rel}" || { log_error "Backup of ${R}${rel} failed"; exit 1; }
    sha256sum "${R}${rel}" >> "${BK}/SHA256SUMS"
  fi
done
log_ok "Backup in ${BK}"

# ── Apply (atomic per file) ─────────────────────────────────────────────────
log_head "Apply"
install_file() {  # SRC DST MODE
  local tmp="${2}.new.$$"
  cp -f "$1" "$tmp" || return 1
  chmod "$3" "$tmp" || return 1
  if [[ -z "$R" ]]; then chown root:root "$tmp" || return 1; fi
  mv -f "$tmp" "$2"
}
fail_and_rollback() {
  log_error "$1: rolling back"
  do_rollback "$BK" || log_error "Rollback failed: restore manually from ${BK}"
  exit 1
}
for rel in "${changed[@]}"; do
  case "$rel" in
    */r_orphan_cleanup.conf)       install_file "$NEW_CONF" "$CONF" 644 || fail_and_rollback "Writing $CONF failed" ;;
    */orphan_cleanup_helpers.sh)   install_file "$SRC_HELPERS" "$DST_HELPERS" 755 || fail_and_rollback "Writing $DST_HELPERS failed" ;;
    */notify_r_orphans.sh)         install_file "$SRC_NOTIFY" "$DST_NOTIFY" 755 || fail_and_rollback "Writing $DST_NOTIFY failed" ;;
  esac
  log_ok "Updated ${R}${rel}"
done

# ── Verify ──────────────────────────────────────────────────────────────────
log_head "Verify"
bash -n "$DST_HELPERS" && bash -n "$DST_NOTIFY" || fail_and_rollback "Installed scripts do not parse"
probe="$(
  set +u
  # shellcheck source=/dev/null
  source "$CONF"
  # shellcheck source=/dev/null
  source "$DST_HELPERS"
  declare -F resolve_user_email_source >/dev/null && echo ok
)" || true
[[ "$probe" == "ok" ]] || fail_and_rollback "resolve_user_email_source not available after sourcing conf + helpers"
log_ok "conf + helpers source cleanly; resolver available"
log_info "Measure: sudo bash $0 --check-notified   (rollback: sudo bash $0 --rollback ${BK})"
exit 0
