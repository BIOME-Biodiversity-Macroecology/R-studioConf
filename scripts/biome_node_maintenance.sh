#!/usr/bin/env bash
set -euo pipefail
# scripts/biome_node_maintenance.sh
#
# OS updates (unattended-upgrades), the rstudio-server restart they need and,
# opt-in, the reboot a new kernel needs: only inside the night window and only
# when the node is free (ADR-0007, ADR-0009).
#
# Why: on biome-calc01 on 2026-10-28 at 06:26 the stock apt-daily-upgrade.timer
# upgraded libbrotli, and needrestart restarted rstudio-server. Stopping the
# service suspends every RStudio session: each session's whole R environment is
# written to ~/.local/share/rstudio on NFS and read back at the next login. One
# researcher's environment was 765 MB, and his login hung on "Loading…".
# Nodes were then never rebooted (calc02 up since 2026-08-24): kernel updates
# were installed but not running (ADR-0009).
#
# What --install-timer changes on the host:
#   * NEW  /etc/needrestart/conf.d/biome-rstudio.conf: needrestart never
#          restarts rstudio-server (other services are restarted as before)
#   * NEW  biome-node-maintenance.{service,timer} and biome-node-postboot.service
#          in /etc/systemd/system
#   * apt-daily-upgrade.timer disabled (its state is saved for --remove-timer).
#     apt-daily.timer (package lists refresh) is left alone.
#
# Each run (timer: every 15 minutes, 03:00-05:00 by default; work from 03:30):
#   1. gate   stop unless: inside the window, not done tonight, the R package
#             sync is not running on this node, apt/dpkg is idle, and no
#             RStudio session or R process runs. Nothing is ever killed.
#             A deferred run exits 75 and the next slot retries; after the
#             last slot the work moves to the next night. After
#             MAINT_OVERDUE_NIGHTS deferred nights it logs a warning; with
#             MAINT_NOTIFY_*_NIGHTS set it emails the admin and, when a reboot
#             is pending, the blocking users (once per night each).
#   2. update apt-get update, then unattended-upgrade (its own origins
#             config, /etc/apt/apt.conf.d/50unattended-upgrades)
#   3. reboot if a reboot is needed, MAINT_REBOOT=true, today is one of
#             MAINT_REBOOT_DAYS and the node is STILL free after
#             MAINT_REBOOT_RECHECK_SECONDS: reboot. Never twice for the same
#             kernel. Otherwise the reboot is reported as pending.
#   4. restart (no reboot) if needrestart lists rstudio-server and the node is
#             STILL free, restart it; otherwise leave it pending
#   5. report JSON in MAINT_STATE_DIR/last_report.json
# After a reboot done here, biome-node-postboot.service runs --post-boot once:
# rstudio-server, sssd, NFS mounts from fstab and the running kernel are checked;
# a failure is logged and mailed to the admin recipients.
# Locks are local to the node: no node waits for another.
#
# Usage:
#   sudo bash scripts/biome_node_maintenance.sh                  # one run (what the timer does)
#   sudo bash scripts/biome_node_maintenance.sh --plan           # gates, needrestart, blockers; change nothing
#   bash scripts/biome_node_maintenance.sh --status              # last report and deferral state
#   sudo bash scripts/biome_node_maintenance.sh --install-timer  # in-place install (idempotent)
#   sudo bash scripts/biome_node_maintenance.sh --remove-timer   # rollback: stock behaviour back
#   sudo bash scripts/biome_node_maintenance.sh --post-boot      # what biome-node-postboot.service runs
#   Options: --force-window (ignore the window, tonight's done-marker and
#            MAINT_REBOOT_DAYS; for a supervised manual run; the session gate
#            and MAINT_REBOOT still apply; no emails), -h|--help
# Settings: config/node_maintenance.vars.conf, site overrides in
#           config/site/node_maintenance.site.vars.conf.
#
# Exit: 0 done / nothing to do / outside window / rebooting | 1 failed
#       2 usage error | 75 deferred (sessions, package sync or apt busy)

readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_RESET='\033[0m'

log_info()  { printf '%b[INFO]%b %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_ok()    { printf '%b[ OK ]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()  { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%b[FAIL]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SCRIPT_DIR WORKSPACE_ROOT

# shellcheck source=../config/node_maintenance.vars.conf disable=SC1091
source "${WORKSPACE_ROOT}/config/node_maintenance.vars.conf"
SITE_CONF="${WORKSPACE_ROOT}/config/site/node_maintenance.site.vars.conf"
# shellcheck source=/dev/null
[[ -f "${SITE_CONF}" ]] && source "${SITE_CONF}"

SYSTEMD_DIR="${MAINT_SYSTEMD_DIR:-/etc/systemd/system}"
NEEDRESTART_DIR="${MAINT_NEEDRESTART_DIR:-/etc/needrestart/conf.d}"
LOCK_FILE="${MAINT_LOCK:-/run/lock/biome-node-maintenance.lock}"
REBOOT_REQUIRED_FILE="${MAINT_REBOOT_REQUIRED_FILE:-/var/run/reboot-required}"
EMAIL_MAP="${MAINT_EMAIL_MAP:-/etc/biome-calc/conf/user_email_map.txt}"
FSTAB="${MAINT_FSTAB:-/etc/fstab}"
NR_CONF="${NEEDRESTART_DIR}/biome-rstudio.conf"
APT_OPTS=(-q -o DPkg::Lock::Timeout=300)
TAG="biome-node-maintenance"
UNITS=(biome-node-maintenance.service biome-node-maintenance.timer biome-node-postboot.service)

ACTION="run"; FORCE_WINDOW=false
usage() { sed -n '2,62p' "$0" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)          ACTION="plan"; shift ;;
    --status)        ACTION="status"; shift ;;
    --install-timer) ACTION="install-timer"; shift ;;
    --remove-timer)  ACTION="remove-timer"; shift ;;
    --post-boot)     ACTION="post-boot"; shift ;;
    --force-window)  FORCE_WINDOW=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) log_error "unknown argument: $1 (see --help)"; exit 2 ;;
  esac
done

for bin in jq pgrep ps awk flock date hostname; do
  command -v "$bin" >/dev/null 2>&1 || { log_error "required binary not found: $bin"; exit 1; }
done
for v in MAINT_WINDOW_START MAINT_WINDOW_END; do
  [[ "${!v}" =~ ^([01][0-9]|2[0-3])[0-5][0-9]$ ]] || { log_error "${v} must be HHMM, not '${!v}'"; exit 2; }
done
(( 10#$MAINT_WINDOW_START < 10#$MAINT_WINDOW_END )) \
  || { log_error "MAINT_WINDOW_START must be before MAINT_WINDOW_END (a window across midnight is not supported)"; exit 2; }
for v in MAINT_OVERDUE_NIGHTS MAINT_REBOOT_RECHECK_SECONDS MAINT_NOTIFY_ADMIN_NIGHTS MAINT_NOTIFY_USERS_NIGHTS MAINT_POSTBOOT_TIMEOUT; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { log_error "${v} must be a whole number, not '${!v}'"; exit 2; }
done
for v in MAINT_RESTART_RSTUDIO MAINT_REBOOT; do
  [[ "${!v}" == true || "${!v}" == false ]] || { log_error "${v} must be true or false"; exit 2; }
done
[[ "$MAINT_REBOOT_DAYS" =~ ^[1-7]?( [1-7])*$ ]] \
  || { log_error "MAINT_REBOOT_DAYS must be weekday numbers 1-7 (date +%u) separated by spaces, not '${MAINT_REBOOT_DAYS}'"; exit 2; }
if [[ "$MAINT_NOTIFY_USERS_NIGHTS" != 0 && "$MAINT_REBOOT" != true ]]; then
  log_warn "MAINT_NOTIFY_USERS_NIGHTS is set but MAINT_REBOOT=false: users are only asked to leave for a reboot, so no user email is sent"
fi

is_root()  { [[ "$(id -u)" -eq 0 ]]; }
now_hhmm() { echo "${MAINT_NOW:-$(date +%H%M)}"; }
today()    { echo "${MAINT_TODAY:-$(date +%F)}"; }
weekday()  { date -d "$(today)" +%u; }
utc_now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
host_s()   { hostname -s; }

write_atomic() {
  local file="$1" tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  cat > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$file"
}

jlog() {  # PRIORITY MESSAGE: journal line for the operator (never fails the run)
  if command -v logger >/dev/null 2>&1; then logger -t "$TAG" -p "daemon.$1" "$2" || true; fi
}

sessions_active() {  # prints "<rsession> <R>" (same test as biome_pkg_sync.sh)
  local s r
  s="$(pgrep -c -x rsession 2>/dev/null || true)"; r="$(pgrep -c -x R 2>/dev/null || true)"
  echo "${s:-0} ${r:-0}"
}

# Who keeps the node busy: one line per rsession/R process of a person
# (uid >= 1000): "user pid elapsed_seconds cpu_seconds comm". user:32 stops ps
# from printing a uid instead of a long AD name.
blockers() {
  ps -o user:32=,uid=,pid=,etimes=,times=,comm= -C rsession,R 2>/dev/null \
    | awk '$2 >= 1000 { print $1, $3, $4, $5, $6 }' || true
}

blockers_table() {  # human-readable, one process per line
  blockers | awk '{ el = $3; cpu = $4
    printf "  %-28s %-8s pid %-8s running %4dd %02dh, CPU time %6.1fh (%3d%% of one core on average)\n",
      $1, $5, $2, el / 86400, (el % 86400) / 3600, cpu / 3600, (el > 0 ? 100 * cpu / el : 0) }'
}

apt_busy() {  # an apt/dpkg frontend is running (e.g. an operator's manual upgrade)
  pgrep -x 'apt|apt-get|aptitude|dpkg' >/dev/null 2>&1 && return 0
  # unattended-upgrade runs under python3 with comm "unattended-upgr". The
  # always-on unattended-upgrade-shutdown helper (unattended-upgrades.service)
  # has the same comm, so match the command line instead (calc04, 2026-11-03:
  # matching the comm deferred every run).
  pgrep -f '(^|[ /])unattended-upgrade( |$)' >/dev/null 2>&1
}

pkg_sync_busy() {  # biome_pkg_sync.sh holds its flock for its whole run
  [[ -e "$MAINT_PKG_SYNC_LOCK" ]] || return 1
  ! flock -n "$MAINT_PKG_SYNC_LOCK" true 2>/dev/null
}

# needrestart batch mode lists, never restarts. Prints
# "<rstudio-server yes|no|unknown> <kernel status 0-3|unknown> <expected kernel|unknown>".
# Kernel status: 1 = running the newest, 2 = same version rebuilt (ABI-compatible
# upgrade), 3 = newer version installed; 2 and 3 both need a reboot.
needrestart_state() {
  local out svc="no" ksta kexp
  if ! command -v needrestart >/dev/null 2>&1; then echo "unknown unknown unknown"; return 0; fi
  out="$(needrestart -b 2>/dev/null || true)"
  grep -q '^NEEDRESTART-SVC: rstudio-server' <<<"$out" && svc="yes"
  ksta="$(awk -F': ' '$1=="NEEDRESTART-KSTA"{print $2; exit}' <<<"$out")"
  kexp="$(awk -F': ' '$1=="NEEDRESTART-KEXP"{print $2; exit}' <<<"$out")"
  echo "$svc ${ksta:-unknown} ${kexp:-unknown}"
}

reboot_needed() {  # KSTA
  [[ "$1" == 2 || "$1" == 3 ]] || [[ -e "$REBOOT_REQUIRED_FILE" ]]
}

reboot_day() {  # today is one of MAINT_REBOOT_DAYS (empty = every day)
  [[ -z "$MAINT_REBOOT_DAYS" ]] && return 0
  [[ " $MAINT_REBOOT_DAYS " == *" $(weekday) "* ]]
}

days_since() {  # STATE_FILE holding a date -> whole days until today (0 if none)
  local first
  first="$(cat "$1" 2>/dev/null || true)"
  [[ -n "$first" ]] || { echo 0; return 0; }
  echo $(( ( $(date -d "$(today)" +%s) - $(date -d "$first" +%s) ) / 86400 ))
}
nights_deferred() { days_since "${MAINT_STATE_DIR}/first_deferred"; }   # this deferral streak
reboot_pending_days() { days_since "${MAINT_STATE_DIR}/reboot_pending_since"; }

mark_reboot_pending() { [[ -s "${MAINT_STATE_DIR}/reboot_pending_since" ]] || today > "${MAINT_STATE_DIR}/reboot_pending_since"; }

# ── mail (same relay, recipients and address map as the R orphan notifier) ────
# The deployed config and helpers are sourced in a subshell, so nothing they
# define reaches this script.
mail_ready() { [[ -r "$MAINT_MAIL_CONF" && -r "$MAINT_MAIL_HELPERS" ]]; }

send_mail() {  # TO SUBJECT BODY_FILE
  (
    set +u
    # shellcheck source=/dev/null
    source "$MAINT_MAIL_CONF" && source "$MAINT_MAIL_HELPERS" || exit 1
    [[ -x "${SEND_EMAIL_SCRIPT:-}" ]] || { echo "send_email.sh not found: ${SEND_EMAIL_SCRIPT:-unset}" >&2; exit 1; }
    "$SEND_EMAIL_SCRIPT" -s "$SMTP_HOST" -p "$SMTP_PORT" -f "$SENDER_EMAIL" -T "$1" \
      -u "$2" -m "$3" -d "$DNS_SERVERS" -L "$TAG"
  )
}

admin_recipients() {
  ( set +u
    # shellcheck source=/dev/null
    source "$MAINT_MAIL_CONF" && source "$MAINT_MAIL_HELPERS" || exit 1
    resolve_admin_recipients "$ADMIN_EMAIL" ) 2>/dev/null || true
}

# Address of a person, and where it came from: "map", "ad" or "pattern".
# "pattern" (user@domain) is never verified: the relay drops bounces silently.
ad_mail() {  # USER -> address from AD (attribute mail) with the node keytab, or nothing
  local u="$1" dir out
  [[ -n "$MAINT_AD_LDAP_URI" && -n "$MAINT_AD_BASE_DN" ]] || return 0
  [[ "$u" =~ ^[A-Za-z0-9._-]+$ ]] || return 0      # no LDAP filter injection
  command -v kinit >/dev/null 2>&1 && command -v ldapsearch >/dev/null 2>&1 || return 0
  dir="$(mktemp -d)"
  out="$(
    export KRB5CCNAME="FILE:${dir}/cc"
    kinit -k "$(host_s | tr '[:lower:]' '[:upper:]')\$" >/dev/null 2>&1 \
      && timeout 20 ldapsearch -LLL -o ldif-wrap=no -Y GSSAPI -Q -H "$MAINT_AD_LDAP_URI" -b "$MAINT_AD_BASE_DN" \
           "(sAMAccountName=${u})" mail 2>/dev/null
  )" || true
  rm -rf "$dir"
  awk -F': ' 'tolower($1)=="mail" && $2 ~ /@/ { print $2; exit }' <<<"$out"
}

user_email() {  # USER -> "address source"
  local u="$1" a
  if [[ -f "$EMAIL_MAP" ]]; then
    a="$(awk -v u="$u" '$1 !~ /^#/ && $1 == u { print $2; exit }' "$EMAIL_MAP")"
    [[ "$a" == *@* ]] && { echo "$a map"; return 0; }
  fi
  a="$(ad_mail "$u")"
  [[ -n "$a" ]] && { echo "$a ad"; return 0; }
  a="$( ( set +u
          # shellcheck source=/dev/null
          source "$MAINT_MAIL_CONF" && source "$MAINT_MAIL_HELPERS" || exit 1
          resolve_user_email "$u" "${MAIL_DOMAIN:-}" ) 2>/dev/null || true)"
  [[ -n "$a" ]] && echo "$a pattern"
  return 0
}

notify_admin() {  # NIGHTS REASON
  local to body
  to="$(admin_recipients)"
  [[ -n "$to" ]] || { log_warn "no admin recipients resolved: admin email skipped"; return 0; }
  body="$(mktemp)"
  {
    echo "Node $(host_s) has not completed its maintenance for $1 night(s) in a row."
    echo "Reason: $2"
    echo
    if reboot_needed "$(cat "${MAINT_STATE_DIR}/kernel_status" 2>/dev/null || echo unknown)"; then
      echo "A reboot is pending since $(cat "${MAINT_STATE_DIR}/reboot_pending_since" 2>/dev/null || echo "an earlier run")."
      echo "MAINT_REBOOT=${MAINT_REBOOT}, reboot days: ${MAINT_REBOOT_DAYS:-every night}."
    fi
    echo
    echo "Processes keeping the node busy (CPU share near 0% = probably an idle session):"
    blockers_table
    echo
    echo "Nothing has been stopped. Contact the users, then on the node:"
    echo "  sudo bash ${SCRIPT_DIR}/biome_node_maintenance.sh --plan"
    echo "  sudo bash ${SCRIPT_DIR}/biome_node_maintenance.sh --force-window"
  } > "$body"
  if send_mail "$to" "[$(host_s)] maintenance blocked for $1 night(s)" "$body" >/dev/null 2>&1; then
    log_info "admin email sent to ${to}"; jlog notice "admin email sent: maintenance blocked for $1 night(s)"
  else
    log_warn "admin email to ${to} failed"; jlog warning "admin email failed: maintenance blocked for $1 night(s)"
  fi
  rm -f "$body"
}

notify_users() {  # PENDING_DAYS
  local u to src body admins
  admins="$(admin_recipients)"
  for u in $(blockers | awk '{ print $1 }' | sort -u); do
    read -r to src <<<"$(user_email "$u")"
    [[ -n "${to:-}" ]] || { log_warn "no address for ${u}: user email skipped"; continue; }
    body="$(mktemp)"
    {
      echo "Hello ${u},"
      echo
      echo "the compute node $(host_s) needs a restart to load security updates."
      echo "It restarts only when no RStudio session and no R process are running,"
      echo "and your processes have kept it busy for $1 night(s):"
      echo
      blockers | awk -v u="$u" '$1 == u' | awk '{ printf "  %s (pid %s), running for %d day(s)\n", $5, $2, $3 / 86400 }'
      echo
      echo "Nothing will be stopped automatically. Please, when you can:"
      echo "  1. save your work: scripts, and the R objects you need with saveRDS();"
      echo "  2. quit the session: in RStudio use File > Quit Session (closing the"
      echo "     browser tab keeps the session running);"
      echo "  3. continue on another BIOME compute node. Your home folder and files"
      echo "     are the same on every node."
      echo
      echo "If a computation must keep running on $(host_s), reply to:"
      echo "  ${admins:-the system administrator}"
      echo
      echo "-- $(host_s) maintenance"
    } > "$body"
    if send_mail "$to" "[$(host_s)] please save your work and move to another node" "$body" >/dev/null 2>&1; then
      log_info "user email sent: ${u} -> ${to} (address from ${src})"
      jlog notice "user email sent: ${u} -> ${to} (address from ${src})"
    else
      log_warn "user email failed: ${u} -> ${to} (address from ${src})"
      jlog warning "user email failed: ${u} -> ${to} (address from ${src})"
    fi
    rm -f "$body"
  done
}

# At most one email of each kind per night; never on a supervised run.
escalate() {  # NIGHTS REASON
  local n="$1" pend
  [[ "$FORCE_WINDOW" == true ]] && return 0
  (( MAINT_NOTIFY_ADMIN_NIGHTS > 0 || MAINT_NOTIFY_USERS_NIGHTS > 0 )) || return 0
  mail_ready || { log_warn "mail config not readable (${MAINT_MAIL_CONF}, ${MAINT_MAIL_HELPERS}): no email"; return 0; }
  # A node that is never free never reaches the reboot step, so the pending
  # reboot is detected here too (needrestart only lists, never restarts).
  if [[ "$MAINT_REBOOT" == true && ! -s "${MAINT_STATE_DIR}/reboot_pending_since" ]]; then
    local svc ksta kexp
    read -r svc ksta kexp <<<"$(needrestart_state)"
    printf '%s\n' "$ksta" > "${MAINT_STATE_DIR}/kernel_status"
    reboot_needed "$ksta" && mark_reboot_pending
  fi
  if (( MAINT_NOTIFY_ADMIN_NIGHTS > 0 && n >= MAINT_NOTIFY_ADMIN_NIGHTS )) \
     && [[ "$(cat "${MAINT_STATE_DIR}/notified_admin" 2>/dev/null || true)" != "$(today)" ]]; then
    today > "${MAINT_STATE_DIR}/notified_admin"
    notify_admin "$n" "$2"
  fi
  pend="$(reboot_pending_days)"
  if [[ "$MAINT_REBOOT" == true && -s "${MAINT_STATE_DIR}/reboot_pending_since" ]] \
     && (( MAINT_NOTIFY_USERS_NIGHTS > 0 && pend >= MAINT_NOTIFY_USERS_NIGHTS )) \
     && [[ "$(cat "${MAINT_STATE_DIR}/notified_users" 2>/dev/null || true)" != "$(today)" ]]; then
    today > "${MAINT_STATE_DIR}/notified_users"
    notify_users "$pend"
  fi
}

REPORT_STATUS="unknown"; REPORT_NOTE=""; REPORT_UPGRADE="not run"; REPORT_RESTART="not needed"
REPORT_KERNEL="unknown"; REPORT_REBOOT="not needed"
write_report() {  # STATUS NOTE
  REPORT_STATUS="$1"; REPORT_NOTE="$2"
  [[ -d "$MAINT_STATE_DIR" ]] || return 0
  jq -n --arg host "$(host_s)" --arg at "$(utc_now)" --arg status "$REPORT_STATUS" \
        --arg note "$REPORT_NOTE" --arg upgrade "$REPORT_UPGRADE" --arg restart "$REPORT_RESTART" \
        --arg kernel "$REPORT_KERNEL" --arg reboot "$REPORT_REBOOT" \
        --arg pending "$(cat "${MAINT_STATE_DIR}/reboot_pending_since" 2>/dev/null || true)" \
        --argjson nights "$(nights_deferred)" \
    '{schema: 2, host: $host, finished_at: $at, status: $status, note: $note, upgrade: $upgrade,
      rstudio_restart: $restart, needrestart_kernel_status: $kernel, reboot: $reboot,
      reboot_pending_since: (if $pending == "" then null else $pending end), nights_deferred: $nights}' \
    | write_atomic "${MAINT_STATE_DIR}/last_report.json"
}
finish() {  # STATUS NOTE EXIT
  write_report "$1" "$2"
  log_info "result: $1: $2"
  exit "$3"
}

# Where a deferred run goes next: the next 15-minute slot, or the next night.
next_slot_note() {
  local n m
  if [[ "$FORCE_WINDOW" == true ]]; then
    echo "run --force-window again later, or wait for the night window"
    return
  fi
  n="$(now_hhmm)"; m=$(( 10#${n:0:2} * 60 + 10#${n:2:2} ))
  m=$(( (m / 15 + 1) * 15 ))
  if (( m >= 10#${MAINT_WINDOW_END:0:2} * 60 + 10#${MAINT_WINDOW_END:2:2} )); then
    echo "last slot tonight, moves to the next night"
  else
    printf 'retry at %02d:%02d' $(( m / 60 )) $(( m % 60 ))
  fi
}

defer() {  # REASON
  local f="${MAINT_STATE_DIR}/first_deferred" n
  [[ -s "$f" ]] || today > "$f"
  n="$(nights_deferred)"
  escalate "$n" "$1"
  if (( n >= MAINT_OVERDUE_NIGHTS )); then
    jlog warning "OS updates deferred for ${n} night(s) on $(host_s): $1"
    finish overdue "deferred for ${n} night(s): $1: $(next_slot_note)" 75
  fi
  finish deferred "$1: $(next_slot_note)" 75
}

# ── status (read-only) ──────────────────────────────────────────────────────
if [[ "$ACTION" == "status" ]]; then
  if [[ -f "${MAINT_STATE_DIR}/last_report.json" ]]; then
    jq -r '"last run: \(.status) at \(.finished_at): \(.note)",
           "  upgrade: \(.upgrade); rstudio restart: \(.rstudio_restart); kernel status: \(.needrestart_kernel_status); nights deferred: \(.nights_deferred)",
           "  reboot: \(.reboot // "n/a"); pending since: \(.reboot_pending_since // "-")"' \
      "${MAINT_STATE_DIR}/last_report.json"
  else
    log_warn "no report yet in ${MAINT_STATE_DIR}"
  fi
  [[ -f "${MAINT_STATE_DIR}/postboot_report.json" ]] \
    && jq -r '"last post-boot check: \(.status) at \(.finished_at): \(.note)"' "${MAINT_STATE_DIR}/postboot_report.json"
  log_info "reboot: MAINT_REBOOT=${MAINT_REBOOT}, days: ${MAINT_REBOOT_DAYS:-every night}; emails: admin after ${MAINT_NOTIFY_ADMIN_NIGHTS} night(s), users after ${MAINT_NOTIFY_USERS_NIGHTS} (0 = off)"
  if command -v systemctl >/dev/null 2>&1; then
    log_info "biome-node-maintenance.timer: $(systemctl is-enabled biome-node-maintenance.timer 2>/dev/null || true); biome-node-postboot.service: $(systemctl is-enabled biome-node-postboot.service 2>/dev/null || true); apt-daily-upgrade.timer: $(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || true)"
  fi
  if [[ -f "$NR_CONF" ]]; then log_ok "needrestart leaves rstudio-server alone (${NR_CONF})"
  else log_warn "needrestart may restart rstudio-server (${NR_CONF} missing)"; fi
  exit 0
fi

# ── install / remove (in-place, idempotent; remove = rollback) ──────────────
if [[ "$ACTION" == "install-timer" || "$ACTION" == "remove-timer" ]]; then
  is_root || { log_error "--${ACTION} needs root"; exit 1; }
  command -v systemctl >/dev/null 2>&1 || { log_error "systemctl not found"; exit 1; }
  mkdir -p "$MAINT_STATE_DIR" || { log_error "cannot create ${MAINT_STATE_DIR}"; exit 1; }
  if [[ "$ACTION" == "remove-timer" ]]; then
    systemctl disable --now biome-node-maintenance.timer 2>/dev/null || true
    systemctl disable biome-node-postboot.service 2>/dev/null || true
    for u in "${UNITS[@]}"; do rm -f "${SYSTEMD_DIR}/${u}"; done
    rm -f "$NR_CONF"
    systemctl daemon-reload
    was="$(cat "${MAINT_STATE_DIR}/apt_upgrade_timer_was" 2>/dev/null || echo enabled)"
    if [[ "$was" == enabled ]]; then
      systemctl enable --now apt-daily-upgrade.timer || { log_error "could not re-enable apt-daily-upgrade.timer"; exit 1; }
      log_ok "apt-daily-upgrade.timer re-enabled (stock behaviour)"
    else
      log_info "apt-daily-upgrade.timer left ${was}, as it was before --install-timer"
    fi
    log_ok "removed: timer, services and ${NR_CONF} (reports in ${MAINT_STATE_DIR} are kept)"
    exit 0
  fi
  command -v unattended-upgrade >/dev/null 2>&1 \
    || { log_error "unattended-upgrade not found (apt install unattended-upgrades)"; exit 1; }
  tpl="${WORKSPACE_ROOT}/templates"
  # save the stock timer state once, so --remove-timer restores what was there
  if [[ ! -f "${MAINT_STATE_DIR}/apt_upgrade_timer_was" ]]; then
    st="$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || true)"
    printf '%s\n' "${st:-unknown}" > "${MAINT_STATE_DIR}/apt_upgrade_timer_was"
  fi
  if [[ -d "$NEEDRESTART_DIR" ]]; then
    write_atomic "$NR_CONF" < "${tpl}/needrestart/biome-rstudio.conf.template"
    if command -v perl >/dev/null 2>&1 \
       && ! perl -e 'our %nrconf; do $ARGV[0]; die $@ if $@; die "no override_rc\n" unless $nrconf{override_rc}' "$NR_CONF" 2>/dev/null; then
      rm -f "$NR_CONF"; log_error "needrestart fragment does not parse: removed, nothing else changed"; exit 1
    fi
    log_ok "needrestart will not restart rstudio-server: ${NR_CONF}"
  else
    log_warn "${NEEDRESTART_DIR} not found (needrestart not installed): nothing restarts rstudio-server on upgrade anyway"
  fi
  for svc in biome-node-maintenance biome-node-postboot; do
    sed -e "s|%%SCRIPT%%|${SCRIPT_DIR}/biome_node_maintenance.sh|g" \
        "${tpl}/systemd/${svc}.service.template" \
      | write_atomic "${SYSTEMD_DIR}/${svc}.service"
  done
  start="${MAINT_WINDOW_START:0:2}"; last="${MAINT_WINDOW_END:0:2}"
  [[ "${MAINT_WINDOW_END:2:2}" == "00" ]] && last=$(( 10#$last - 1 ))
  sed "s|%%HOURS%%|${start}..$(printf '%02d' "$((10#$last))")|g" "${tpl}/systemd/biome-node-maintenance.timer.template" \
    | write_atomic "${SYSTEMD_DIR}/biome-node-maintenance.timer"
  systemctl daemon-reload
  systemctl disable --now apt-daily-upgrade.timer 2>/dev/null || true
  systemctl enable --now biome-node-maintenance.timer \
    || { log_error "could not enable biome-node-maintenance.timer; undo: sudo bash $0 --remove-timer"; exit 1; }
  # enabled, not started: it only acts after a reboot done by this script
  systemctl enable biome-node-postboot.service \
    || { log_error "could not enable biome-node-postboot.service; undo: sudo bash $0 --remove-timer"; exit 1; }
  log_ok "installed: OS updates ${MAINT_WINDOW_START}-${MAINT_WINDOW_END} on a free node; next runs: systemctl list-timers biome-node-maintenance.timer"
  log_info "reboot: MAINT_REBOOT=${MAINT_REBOOT} (days: ${MAINT_REBOOT_DAYS:-every night}); set it in ${SITE_CONF}"
  log_info "undo: sudo bash $0 --remove-timer"
  exit 0
fi

# ── post-boot check (after a reboot done by this script) ────────────────────
if [[ "$ACTION" == "post-boot" ]]; then
  is_root || { log_error "--post-boot needs root"; exit 1; }
  marker="${MAINT_STATE_DIR}/reboot_requested"
  [[ -f "$marker" ]] || { log_info "no reboot requested by this script: nothing to check"; exit 0; }
  kexp="$(jq -r '.expected_kernel // "unknown"' "$marker" 2>/dev/null || echo unknown)"
  problems=()
  deadline=$(( $(date +%s) + MAINT_POSTBOOT_TIMEOUT ))
  while :; do
    problems=()
    systemctl is-active --quiet rstudio-server || problems+=("rstudio-server not active")
    if systemctl cat sssd.service >/dev/null 2>&1; then
      systemctl is-active --quiet sssd || problems+=("sssd not active")
    fi
    while read -r mnt; do
      [[ -n "$mnt" ]] || continue
      mountpoint -q "$mnt" 2>/dev/null || problems+=("NFS ${mnt} not mounted")
    done < <(awk '$1 !~ /^#/ && ($3 == "nfs" || $3 == "nfs4") && $4 !~ /(^|,)noauto(,|$)/ { print $2 }' "$FSTAB" 2>/dev/null)
    (( ${#problems[@]} == 0 )) && break
    (( $(date +%s) >= deadline )) && break
    sleep 10
  done
  running="$(uname -r)"
  if [[ "$kexp" != unknown && "$kexp" != "$running" ]]; then
    problems+=("running kernel ${running}, expected ${kexp} (check the GRUB default)")
  fi
  if (( ${#problems[@]} == 0 )); then
    status=ok; note="kernel ${running}; rstudio-server, sssd and NFS mounts up"
    rm -f "${MAINT_STATE_DIR}/reboot_pending_since"
    log_ok "post-boot: ${note}"; jlog notice "post-boot check ok: ${note}"
  else
    status=failed; note="$(IFS=';'; echo "${problems[*]}")"
    log_error "post-boot: ${note}"; jlog err "post-boot check FAILED: ${note}"
    if mail_ready && to="$(admin_recipients)" && [[ -n "$to" ]]; then
      body="$(mktemp)"
      printf 'Node %s was rebooted by the maintenance job and the check after boot failed:\n\n' "$(host_s)" > "$body"
      printf '  %s\n' "${problems[@]}" >> "$body"
      printf '\nCheck on the node: systemctl --failed; journalctl -b -p err\n' >> "$body"
      send_mail "$to" "[$(host_s)] FAILED check after maintenance reboot" "$body" >/dev/null 2>&1 \
        || log_warn "admin email failed"
      rm -f "$body"
    fi
  fi
  jq -n --arg host "$(host_s)" --arg at "$(utc_now)" --arg status "$status" --arg note "$note" \
        --arg kernel "$running" --arg expected "$kexp" \
    '{schema: 1, host: $host, finished_at: $at, status: $status, note: $note, kernel: $kernel, expected_kernel: $expected}' \
    | write_atomic "${MAINT_STATE_DIR}/postboot_report.json"
  rm -f "$marker"
  [[ "$status" == ok ]] && exit 0 || exit 1
fi

# ── run / plan ───────────────────────────────────────────────────────────────
if [[ "$ACTION" == "plan" ]]; then
  now="$(now_hhmm)"
  log_info "window ${MAINT_WINDOW_START}-${MAINT_WINDOW_END}, now ${now}: $( (( 10#$now >= 10#$MAINT_WINDOW_START && 10#$now < 10#$MAINT_WINDOW_END )) && echo inside || echo outside)"
  read -r s r <<<"$(sessions_active)"
  log_info "RStudio sessions: ${s}, R processes: ${r} ($( (( s + r == 0 )) && echo free || echo busy))"
  (( s + r == 0 )) || blockers_table
  if pkg_sync_busy; then log_info "package sync: running"; else log_info "package sync: idle"; fi
  if apt_busy; then log_info "apt/dpkg: busy"; else log_info "apt/dpkg: idle"; fi
  read -r svc ksta kexp <<<"$(needrestart_state)"
  log_info "rstudio-server needs restart: ${svc}; needrestart kernel status: ${ksta} (2 or 3 = reboot needed); expected kernel: ${kexp}; running: $(uname -r)"
  if reboot_needed "$ksta"; then
    log_info "reboot needed; MAINT_REBOOT=${MAINT_REBOOT}; reboot day today: $(reboot_day && echo yes || echo "no (${MAINT_REBOOT_DAYS})")"
  fi
  log_info "deferred nights in a row: $(nights_deferred 2>/dev/null || echo 0); reboot pending since: $(cat "${MAINT_STATE_DIR}/reboot_pending_since" 2>/dev/null || echo -)"
  if (( MAINT_NOTIFY_USERS_NIGHTS > 0 )) && (( s + r > 0 )); then
    for u in $(blockers | awk '{ print $1 }' | sort -u); do
      read -r to src <<<"$(user_email "$u")"
      log_info "user email for ${u}: ${to:-none} (source: ${src:-none}$([[ "${src:-}" == pattern ]] && echo ", not verified"))"
    done
  fi
  exit 0
fi

is_root || { log_error "a run needs root"; exit 1; }
mkdir -p "$MAINT_STATE_DIR" || { log_error "cannot create ${MAINT_STATE_DIR}"; exit 1; }
exec 9>"${LOCK_FILE}"
flock -n 9 || { log_warn "another run is active: exiting"; exit 0; }

now="$(now_hhmm)"
if [[ "$FORCE_WINDOW" != true ]]; then
  if (( 10#$now < 10#$MAINT_WINDOW_START || 10#$now >= 10#$MAINT_WINDOW_END )); then
    log_info "outside the window ${MAINT_WINDOW_START}-${MAINT_WINDOW_END}: nothing to do"; exit 0
  fi
  if [[ "$(cat "${MAINT_STATE_DIR}/done_date" 2>/dev/null || true)" == "$(today)" ]]; then
    log_info "already done tonight: nothing to do"; exit 0
  fi
fi

pkg_sync_busy && defer "R package sync running on this node"
apt_busy && defer "apt/dpkg busy"
read -r s r <<<"$(sessions_active)"
(( s + r == 0 )) || defer "${s} RStudio session(s), ${r} R process(es) running"

command -v unattended-upgrade >/dev/null 2>&1 || finish failed "unattended-upgrade not found" 1
# Respect the host's apt policy: the stock timer would not upgrade either.
uu_on="$(apt-config dump 2>/dev/null | awk '$1=="APT::Periodic::Unattended-Upgrade"{gsub(/[";]/, "", $2); print $2}' | tail -n 1)"
if [[ "${uu_on:-0}" == "0" ]]; then
  REPORT_UPGRADE="skipped"
else
  apt-get update "${APT_OPTS[@]}" >/dev/null 2>&1 || log_warn "apt-get update failed: upgrading from the current lists"
  set +e
  unattended-upgrade
  uu_rc=$?
  set -e
  if (( uu_rc != 0 )); then
    REPORT_UPGRADE="failed (rc ${uu_rc}, see /var/log/unattended-upgrades/)"
    finish failed "unattended-upgrade exit ${uu_rc}" 1
  fi
  REPORT_UPGRADE="done"
fi
rm -f "${MAINT_STATE_DIR}/first_deferred"

read -r svc ksta kexp <<<"$(needrestart_state)"
REPORT_KERNEL="$ksta"
printf '%s\n' "$ksta" > "${MAINT_STATE_DIR}/kernel_status"

# ── reboot (ADR-0009) ──
if reboot_needed "$ksta"; then
  last_kexp="$(cat "${MAINT_STATE_DIR}/last_reboot_kernel" 2>/dev/null || true)"
  if [[ "$MAINT_REBOOT" != true ]]; then
    REPORT_REBOOT="needed, disabled by MAINT_REBOOT=false"
    log_warn "a reboot is needed (kernel status ${ksta}): reboot this node in a maintenance slot or set MAINT_REBOOT=true"
  elif [[ "$kexp" != unknown && "$kexp" == "$last_kexp" ]]; then
    # already rebooted once for this kernel and it is still not running: never loop
    REPORT_REBOOT="needed, refused: already rebooted for ${kexp} and it is still not running (check the GRUB default)"
    log_error "$REPORT_REBOOT"; jlog err "$REPORT_REBOOT"
  elif [[ "$FORCE_WINDOW" != true ]] && ! reboot_day; then
    mark_reboot_pending
    REPORT_REBOOT="pending: not a reboot day for this node (days ${MAINT_REBOOT_DAYS}, today $(weekday))"
  else
    mark_reboot_pending
    log_info "reboot needed (kernel status ${ksta}): checking again in ${MAINT_REBOOT_RECHECK_SECONDS}s that the node is still free"
    sleep "$MAINT_REBOOT_RECHECK_SECONDS"
    read -r s r <<<"$(sessions_active)"
    if (( s + r > 0 )) || pkg_sync_busy || apt_busy; then
      REPORT_REBOOT="pending: node busy again before the reboot (${s} session(s), ${r} R process(es))"
      finish deferred "upgrade ${REPORT_UPGRADE}, $REPORT_REBOOT: $(next_slot_note)" 75
    fi
    jq -n --arg at "$(utc_now)" --arg k "$kexp" --arg ksta "$ksta" \
      '{requested_at: $at, expected_kernel: $k, kernel_status: $ksta}' \
      | write_atomic "${MAINT_STATE_DIR}/reboot_requested"
    [[ "$kexp" != unknown ]] && printf '%s\n' "$kexp" > "${MAINT_STATE_DIR}/last_reboot_kernel"
    today > "${MAINT_STATE_DIR}/done_date"
    REPORT_REBOOT="rebooting"; REPORT_RESTART="not needed (reboot)"
    write_report rebooting "upgrade ${REPORT_UPGRADE}; rebooting for kernel ${kexp} (status ${ksta})"
    jlog notice "rebooting $(host_s) on a free node for kernel ${kexp} (status ${ksta})"
    log_info "result: rebooting: kernel ${kexp}"
    if ! systemctl reboot; then
      rm -f "${MAINT_STATE_DIR}/reboot_requested"
      REPORT_REBOOT="failed"
      finish failed "systemctl reboot failed" 1
    fi
    exit 0
  fi
else
  rm -f "${MAINT_STATE_DIR}/reboot_pending_since"
fi

# ── rstudio-server restart (no reboot) ──
if [[ "$svc" == yes ]]; then
  read -r s r <<<"$(sessions_active)"
  if [[ "$MAINT_RESTART_RSTUDIO" != true ]]; then
    REPORT_RESTART="needed, disabled by MAINT_RESTART_RSTUDIO=false"
  elif (( s + r > 0 )); then
    # someone logged in during the upgrade: retry the restart at the next slot
    REPORT_RESTART="pending: ${s} session(s) started during the upgrade"
    finish deferred "upgrade done, rstudio-server restart pending: $(next_slot_note)" 75
  elif systemctl restart rstudio-server; then
    REPORT_RESTART="done"; log_ok "rstudio-server restarted on a free node"
  else
    REPORT_RESTART="failed"
    finish failed "systemctl restart rstudio-server failed: systemctl status rstudio-server" 1
  fi
fi
today > "${MAINT_STATE_DIR}/done_date"
if [[ "$REPORT_UPGRADE" == skipped ]]; then
  finish skipped "APT::Periodic::Unattended-Upgrade is off on this host (/etc/apt/apt.conf.d/20auto-upgrades); reboot: ${REPORT_REBOOT}" 0
fi
finish "done" "upgrade done; rstudio-server restart: ${REPORT_RESTART}; reboot: ${REPORT_REBOOT}" 0
