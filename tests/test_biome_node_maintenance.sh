#!/usr/bin/env bash
set -euo pipefail
# tests/test_biome_node_maintenance.sh — scripts/biome_node_maintenance.sh (ADR-0007)
#
# pgrep, ps, id, systemctl, unattended-upgrade, needrestart, apt-get, apt-config,
# logger, hostname, sleep, uname, mountpoint and send_email.sh
# are stubbed on PATH; state, systemd and needrestart dirs
# are fakes under mktemp. flock and perl are real. Never touches apt, systemd
# or /var.
#
# Exit: 0 all pass | 1 at least one failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SUT="${SCRIPT_DIR}/../scripts/biome_node_maintenance.sh"
readonly NR_TEMPLATE="${SCRIPT_DIR}/../templates/needrestart/biome-rstudio.conf.template"
readonly HELPERS="${SCRIPT_DIR}/../templates/orphan_cleanup_helpers.sh.template"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=""; GREEN=""; NC=""; }

command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }
T="$(mktemp -d)"
HOLDER=""
cleanup() { [[ -n "$HOLDER" ]] && kill "$HOLDER" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
fails=0
pass() { printf "%sPASS%s %s\n" "$GREEN" "$NC" "$1"; }
fail() { printf "%sFAIL%s %s\n" "$RED" "$NC" "$1"; fails=$((fails + 1)); }
check() { if eval "$1"; then pass "$2"; else fail "$2"; printf '%s\n' "$OUT" | sed 's/^/      | /'; fi; }

# ── stubs ──
mkdir -p "$T/bin"
cat > "$T/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *rsession*) n="$(cat "$STUB_SESS")"; echo "$n"; [[ "$n" -gt 0 ]]; exit ;;
  "-c -x R")  echo "${STUB_R:-0}"; [[ "${STUB_R:-0}" -gt 0 ]]; exit ;;
  -x*apt-get*)
    # emulate pgrep -x against process names (comm, 15 chars): the always-on
    # unattended-upgrade-shutdown helper shows up as "unattended-upgr"
    comms="unattended-upgr"
    [[ "${STUB_APT_BUSY:-0}" == 1 ]] && comms+=$'\napt-get'
    grep -Exq -- "(${*: -1})" <<< "$comms"; exit ;;
  -f*unattended-upgrade*)
    # emulate pgrep -f against a process table: the shutdown helper is always
    # there (unattended-upgrades.service); a real run only with STUB_UU_RUNNING=1
    procs="/usr/bin/python3 /usr/share/unattended-upgrades/unattended-upgrade-shutdown --wait-for-signal"
    [[ "${STUB_UU_RUNNING:-0}" == 1 ]] && procs+=$'\n/usr/bin/python3 /usr/bin/unattended-upgrade'
    pat="${*: -1}"
    grep -Eq -- "$pat" <<< "$procs"; exit ;;
esac
echo 0; exit 1
EOF
cat > "$T/bin/id" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_UID:-0}"
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
[[ "$1" == is-enabled ]] && { echo "${STUB_APT_TIMER:-enabled}"; exit 0; }
if [[ "$1" == is-active ]]; then [[ " ${STUB_INACTIVE:-} " == *" ${*: -1} "* ]] && exit 3; exit 0; fi
[[ "$1" == cat ]] && exit 0
[[ "$1" == reboot && "${STUB_REBOOT_FAIL:-0}" == 1 ]] && exit 1
[[ "$1 $2" == "restart rstudio-server" && "${STUB_RESTART_FAIL:-0}" == 1 ]] && exit 1
exit 0
EOF
cat > "$T/bin/unattended-upgrade" <<'EOF'
#!/usr/bin/env bash
echo "unattended-upgrade $*" >> "$STUB_LOG"
[[ -n "${STUB_SESS_AFTER_UU:-}" ]] && echo "$STUB_SESS_AFTER_UU" > "$STUB_SESS"
exit "${STUB_UU_RC:-0}"
EOF
cat > "$T/bin/needrestart" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -b ]] || exit 2
echo "NEEDRESTART-VER: 3.6"
echo "NEEDRESTART-KSTA: ${STUB_KSTA:-1}"
[[ -n "${STUB_KEXP:-}" ]] && echo "NEEDRESTART-KEXP: ${STUB_KEXP}"
[[ "${STUB_NR_RSTUDIO:-0}" == 1 ]] && echo "NEEDRESTART-SVC: rstudio-server.service"
echo "NEEDRESTART-SVC: cron.service"
EOF
cat > "$T/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "$STUB_LOG"
EOF
cat > "$T/bin/apt-config" <<'EOF'
#!/usr/bin/env bash
echo 'APT::Periodic::Update-Package-Lists "1";'
echo "APT::Periodic::Unattended-Upgrade \"${STUB_UU_PERIODIC:-1}\";"
EOF
cat > "$T/bin/logger" <<'EOF'
#!/usr/bin/env bash
echo "logger $*" >> "$STUB_LOG"
EOF
cat > "$T/bin/hostname" <<'EOF'
#!/usr/bin/env bash
echo "calc-test"
EOF
cat > "$T/bin/ps" <<'EOF'
#!/usr/bin/env bash
# only the blockers() call: user:32 uid pid etimes times comm
[[ "$*" == *"-C rsession,R"* ]] || exit 1
[[ -f "${STUB_PS:-/nonexistent}" ]] && cat "$STUB_PS"
exit 0
EOF
cat > "$T/bin/sleep" <<'EOF'
#!/usr/bin/env bash
[[ -n "${STUB_SESS_AFTER_SLEEP:-}" ]] && echo "$STUB_SESS_AFTER_SLEEP" > "$STUB_SESS"
exit 0
EOF
cat > "$T/bin/send_email.sh" <<'EOF'
#!/usr/bin/env bash
to=""; subj=""; body=""
while getopts "s:p:f:t:T:B:u:m:d:HL:" o; do
  case $o in T) to="$OPTARG" ;; u) subj="$OPTARG" ;; m) body="$OPTARG" ;; *) ;; esac
done
echo "MAIL to=${to} subj=${subj}" >> "$STUB_LOG"
cat "$body" >> "$STUB_LOG.mail"
exit "${STUB_MAIL_RC:-0}"
EOF
cat > "$T/bin/uname" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_UNAME:-6.8.0-50-generic}"
EOF
cat > "$T/bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ " ${STUB_UNMOUNTED:-} " == *" ${*: -1} "* ]] && exit 1
exit 0
EOF
chmod +x "$T"/bin/*

reset_env() {
  rm -rf "$T/state" "$T/systemd" "$T/nr" "$T/log" "$T/log.mail" "$T/sess" "$T/ps" "$T/reboot-required" "$T/map"
  mkdir -p "$T/state" "$T/systemd" "$T/nr"
  : > "$T/log"; echo 0 > "$T/sess"
  unset STUB_R STUB_APT_BUSY STUB_UU_RUNNING STUB_SESS_AFTER_UU STUB_UU_RC STUB_KSTA STUB_NR_RSTUDIO STUB_UU_PERIODIC STUB_RESTART_FAIL STUB_APT_TIMER \
        STUB_KEXP STUB_INACTIVE STUB_REBOOT_FAIL STUB_SESS_AFTER_SLEEP STUB_MAIL_RC STUB_UNAME STUB_UNMOUNTED
}
run() {  # args...
  set +e
  OUT="$(PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_SESS="$T/sess" STUB_PS="$T/ps" \
         MAINT_STATE_DIR="$T/state" MAINT_SYSTEMD_DIR="$T/systemd" MAINT_NEEDRESTART_DIR="$T/nr" \
         MAINT_LOCK="$T/run.lock" MAINT_PKG_SYNC_LOCK="$T/pkgsync.lock" \
         MAINT_NOW="${NOW:-0345}" MAINT_TODAY="${TODAY:-2026-10-29}" \
         MAINT_REBOOT_RECHECK_SECONDS=0 MAINT_POSTBOOT_TIMEOUT=0 \
         MAINT_REBOOT_REQUIRED_FILE="$T/reboot-required" MAINT_EMAIL_MAP="$T/map" MAINT_FSTAB="$T/fstab" \
         MAINT_MAIL_CONF="${MAINT_MAIL_CONF:-$T/mail.conf}" MAINT_MAIL_HELPERS="${MAINT_MAIL_HELPERS:-$HELPERS}" \
         bash "$SUT" "$@" 2>&1)"
  # shellcheck disable=SC2034  # read inside the eval'd check strings
  RC=$?
  set -e
}
report() { jq -r ".$1" "$T/state/last_report.json" 2>/dev/null || true; }
rebooted() { grep -q '^systemctl reboot' "$T/log"; }
mails() { grep -c '^MAIL ' "$T/log" || true; }
# two blockers: an idle session (0% CPU) and a long computation
blockers_fixture() {
  printf '%s\n' "martina.livornese2 1500001 4242 604800 600 rsession" \
                 "mario.rossi 1500002 5151 259200 250000 R" \
                 "rstudio-server 998 77 9000 1 rsession" > "$T/ps"
}
uu_called() { grep -q '^unattended-upgrade' "$T/log"; }
restarted() { grep -q '^systemctl restart rstudio-server' "$T/log"; }

cat > "$T/mail.conf" <<EOF
SEND_EMAIL_SCRIPT="$T/bin/send_email.sh"
SMTP_HOST="smtp.example.org"; SMTP_PORT="25"; SENDER_EMAIL="calc@example.org"; DNS_SERVERS="192.0.2.10"
MAIL_DOMAIN="example.org"; MAIL_DOMAINS_USER="example.org students.example.org"
ADMIN_EMAIL="admin@example.org"
EOF
cat > "$T/helpers_v2.sh" <<'EOS'
resolve_admin_recipients() { echo "$1"; }
resolve_user_email_source() {
  case "$1" in
    martina.livornese2) echo "martina.livornese2@unibo.example ad" ;;
    mario.rossi)        echo "m.rossi@example.org map" ;;
  esac
}
EOS
printf '%s\n' "srv:/export/home /nfs/home nfs4 defaults 0 0" "srv:/x /mnt/x nfs noauto 0 0" "/dev/sda1 / ext4 defaults 0 1" > "$T/fstab"

echo "## gates"
reset_env; NOW=0200 run
check '[[ $RC -eq 0 ]] && ! uu_called && [[ "$OUT" == *"outside the window"* ]]' "outside the window: exit 0, no upgrade"

reset_env; echo 2 > "$T/sess"; NOW=0345 run
check '[[ $RC -eq 75 ]] && ! uu_called && [[ "$(report status)" == deferred ]]' "RStudio sessions: deferred (75), no upgrade"
check '[[ "$(cat "$T/state/first_deferred")" == 2026-10-29 ]] && [[ "$(report note)" == *"retry at 04:00"* ]]' "deferral recorded, next slot named"

reset_env; NOW=0445 STUB_R=1 run
check '[[ $RC -eq 75 ]] && [[ "$(report note)" == *"moves to the next night"* ]]' "R process in tmux counts as busy; last slot moves to the next night"

reset_env; echo 2026-10-25 > "$T/state/first_deferred"; echo 1 > "$T/sess"; run
check '[[ $RC -eq 75 && "$(report status)" == overdue ]] && grep -q "logger -t biome-node-maintenance -p daemon.warning" "$T/log"' "4 nights deferred (>= 3): overdue + journal warning"

reset_env; ( exec 8>"$T/pkgsync.lock"; flock 8; exec sleep 30 ) & HOLDER=$!; sleep 0.3; run
kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true; HOLDER=""
check '[[ $RC -eq 75 ]] && ! uu_called && [[ "$(report note)" == *"package sync running"* ]]' "package sync holds its lock: deferred, no upgrade"

reset_env; : > "$T/pkgsync.lock"; run
check '[[ $RC -eq 0 ]] && uu_called' "package sync lock file present but free: runs"

reset_env; STUB_APT_BUSY=1 run
check '[[ $RC -eq 75 ]] && ! uu_called && [[ "$(report note)" == *"apt/dpkg busy"* ]]' "apt/dpkg busy: deferred"
reset_env; STUB_UU_RUNNING=1 run
check '[[ $RC -eq 75 ]] && ! uu_called && [[ "$(report note)" == *"apt/dpkg busy"* ]]' "unattended-upgrade already running: deferred"
reset_env; run
check '[[ $RC -eq 0 ]] && uu_called' "always-on unattended-upgrade-shutdown helper does not count as busy"
reset_env; STUB_APT_BUSY=1 run --force-window
check '[[ $RC -eq 75 ]] && [[ "$(report note)" == *"run --force-window again later"* ]]' "--force-window deferral names the manual retry, not the night slot"

reset_env; STUB_UU_PERIODIC=0 run
check '[[ $RC -eq 0 && "$(report status)" == skipped ]] && ! uu_called' "APT::Periodic::Unattended-Upgrade 0 respected: no upgrade"

echo "## upgrade + restart"
reset_env; echo 2026-10-28 > "$T/state/first_deferred"; STUB_NR_RSTUDIO=1 run
check '[[ $RC -eq 0 && "$(report status)" == done ]] && uu_called && restarted' "free node: upgrade, then rstudio-server restart"
check '[[ "$(cat "$T/state/done_date")" == 2026-10-29 && ! -e "$T/state/first_deferred" ]]' "done-marker written, deferral streak cleared"
check 'grep -q "^apt-get update" "$T/log"' "package lists refreshed first"
run
check '[[ $RC -eq 0 && "$OUT" == *"already done tonight"* ]] && [[ $(grep -c "^unattended-upgrade" "$T/log") -eq 1 ]]' "second slot the same night: nothing to do"

reset_env; run
check '[[ $RC -eq 0 ]] && uu_called && ! restarted && [[ "$(report rstudio_restart)" == "not needed" ]]' "no restart when needrestart does not list rstudio-server"

reset_env; STUB_NR_RSTUDIO=1 STUB_SESS_AFTER_UU=1 run
check '[[ $RC -eq 75 ]] && uu_called && ! restarted && [[ ! -e "$T/state/done_date" ]] && [[ "$(report rstudio_restart)" == pending* ]]' "session opened during the upgrade: restart pending, retried next slot"

reset_env; STUB_NR_RSTUDIO=1 MAINT_RESTART_RSTUDIO=false run
check '[[ $RC -eq 0 ]] && ! restarted && [[ "$(report rstudio_restart)" == *"disabled"* ]]' "MAINT_RESTART_RSTUDIO=false: reported, not restarted"

reset_env; STUB_NR_RSTUDIO=1 STUB_RESTART_FAIL=1 run
check '[[ $RC -eq 1 && "$(report status)" == failed && ! -e "$T/state/done_date" ]]' "restart failure: exit 1, not marked done"

reset_env; STUB_UU_RC=1 run
check '[[ $RC -eq 1 && "$(report status)" == failed && ! -e "$T/state/done_date" ]]' "unattended-upgrade failure: exit 1, not marked done"

reset_env; STUB_KSTA=3 run
check '[[ $RC -eq 0 && "$(report needrestart_kernel_status)" == 3 ]] && [[ "$OUT" == *"reboot this node"* ]] && ! grep -q reboot "$T/log"' "pending kernel: reported, never rebooted"

reset_env; STUB_UID=1000 run
check '[[ $RC -eq 1 ]] && ! uu_called' "non-root run refused"

reset_env; MAINT_WINDOW_START=0500 MAINT_WINDOW_END=0330 run
check '[[ $RC -eq 2 ]]' "window across midnight rejected (exit 2)"


echo "## reboot (ADR-0009)"
reset_env; STUB_KSTA=3 STUB_KEXP=6.8.0-51-generic MAINT_REBOOT=true run
check '[[ $RC -eq 0 && "$(report status)" == rebooting && "$(report schema)" == 2 ]] && rebooted' "MAINT_REBOOT=true, kernel 3, free node: reboots"
check '[[ "$(jq -r .expected_kernel "$T/state/reboot_requested")" == 6.8.0-51-generic && "$(cat "$T/state/last_reboot_kernel")" == 6.8.0-51-generic && -s "$T/state/done_date" ]]' "marker, expected kernel and done-marker written before the reboot"
check '! restarted' "no separate rstudio-server restart when rebooting"

reset_env; STUB_KSTA=2 MAINT_REBOOT=true run
check '[[ $RC -eq 0 ]] && rebooted' "kernel status 2 (ABI-compatible rebuild) also reboots"
reset_env; : > "$T/reboot-required"; MAINT_REBOOT=true run
check '[[ $RC -eq 0 ]] && rebooted' "/var/run/reboot-required alone also reboots"
reset_env; MAINT_REBOOT=true run
check '[[ $RC -eq 0 && "$(report reboot)" == "not needed" ]] && ! rebooted' "no reboot needed: none done"

reset_env; STUB_KSTA=3 run
check '[[ $RC -eq 0 && "$(report reboot)" == *"MAINT_REBOOT=false"* ]] && ! rebooted' "default MAINT_REBOOT=false: reported only"

reset_env; STUB_KSTA=3 MAINT_REBOOT=true MAINT_REBOOT_DAYS="1 2" run
check '[[ $RC -eq 0 && "$(report reboot)" == pending*"not a reboot day"* ]] && ! rebooted && [[ "$(cat "$T/state/reboot_pending_since")" == 2026-10-29 ]]' "not this node's reboot day (Thu): pending, date recorded"
reset_env; STUB_KSTA=3 MAINT_REBOOT=true MAINT_REBOOT_DAYS="4" run
check '[[ $RC -eq 0 ]] && rebooted' "this node's reboot day (4 = Thu): reboots"
reset_env; STUB_KSTA=3 MAINT_REBOOT=true MAINT_REBOOT_DAYS="1" run --force-window
check '[[ $RC -eq 0 ]] && rebooted' "--force-window (supervised) ignores the reboot day"

reset_env; STUB_KSTA=3 MAINT_REBOOT=true STUB_SESS_AFTER_SLEEP=1 run
check '[[ $RC -eq 75 && "$(report reboot)" == pending*"busy again"* ]] && ! rebooted && [[ ! -e "$T/state/done_date" ]]' "login during the re-check: no reboot, retried next slot"

reset_env; echo 6.8.0-51-generic > "$T/state/last_reboot_kernel"; STUB_KSTA=3 STUB_KEXP=6.8.0-51-generic MAINT_REBOOT=true run
check '[[ $RC -eq 0 && "$(report reboot)" == *"already rebooted"* ]] && ! rebooted && grep -q "daemon.err" "$T/log"' "never reboots twice for the same kernel (no boot loop)"

reset_env; STUB_KSTA=3 MAINT_REBOOT=true STUB_REBOOT_FAIL=1 run
check '[[ $RC -eq 1 && "$(report status)" == failed && ! -e "$T/state/reboot_requested" ]]' "systemctl reboot fails: exit 1, marker removed"

reset_env; STUB_KSTA=3 MAINT_REBOOT=true STUB_UU_PERIODIC=0 run
check '[[ $RC -eq 0 ]] && rebooted && ! uu_called' "upgrades off on the host: a pending kernel still reboots"

reset_env; MAINT_REBOOT=maybe run
check '[[ $RC -eq 2 ]]' "MAINT_REBOOT not true/false rejected (exit 2)"
reset_env; MAINT_REBOOT_DAYS="8" run
check '[[ $RC -eq 2 ]]' "MAINT_REBOOT_DAYS outside 1-7 rejected (exit 2)"

echo "## escalation emails"
reset_env; blockers_fixture; echo 1 > "$T/sess"; echo 2026-10-26 > "$T/state/first_deferred"; run
check '[[ $RC -eq 75 && "$(mails)" == 0 ]]' "defaults (0 = off): no email even when overdue"

reset_env; blockers_fixture; echo 1 > "$T/sess"; echo 2026-10-26 > "$T/state/first_deferred"; MAINT_NOTIFY_ADMIN_NIGHTS=3 run
check '[[ $RC -eq 75 && "$(mails)" == 1 ]] && grep -q "^MAIL to=admin@example.org subj=\[calc-test\] maintenance blocked for 3 night" "$T/log"' "3 nights: one email to the admin"
check 'grep -q "martina.livornese2 .*rsession.*(  0% of one core" "$T/log.mail" && grep -q "mario.rossi" "$T/log.mail" && ! grep -q "^  rstudio-server" "$T/log.mail"' "admin email lists people (idle vs computing), not system users"
NOW=0400 MAINT_NOTIFY_ADMIN_NIGHTS=3 run
check '[[ "$(mails)" == 1 ]]' "second slot the same night: no second admin email"
TODAY=2026-10-30 MAINT_NOTIFY_ADMIN_NIGHTS=3 run
check '[[ "$(mails)" == 2 ]]' "next night: one more admin email"

reset_env; blockers_fixture; echo 1 > "$T/sess"; echo 2026-10-28 > "$T/state/first_deferred"; MAINT_NOTIFY_ADMIN_NIGHTS=3 run
check '[[ "$(mails)" == 0 ]]' "1 night: below the admin threshold, no email"

reset_env; blockers_fixture; echo 1 > "$T/sess"; echo 2026-10-26 > "$T/state/first_deferred"; echo 2026-10-24 > "$T/state/reboot_pending_since"
MAINT_REBOOT=true MAINT_NOTIFY_USERS_NIGHTS=5 run
check '[[ "$(mails)" == 2 ]] && grep -q "^MAIL to=martina.livornese2@example.org,martina.livornese2@students.example.org subj=\[calc-test\] please save your work" "$T/log"' "reboot pending 5 nights: each blocking user emailed (domain pattern)"
check 'grep -q "address from pattern" "$T/log" && grep -q "File > Quit Session" "$T/log.mail" && grep -q "saveRDS" "$T/log.mail"' "user email explains save/quit/move; log names the unverified source"
MAINT_REBOOT=true MAINT_NOTIFY_USERS_NIGHTS=5 NOW=0415 run
check '[[ "$(mails)" == 2 ]]' "users emailed at most once per night"

reset_env; blockers_fixture; echo 1 > "$T/sess"; STUB_KSTA=3 MAINT_REBOOT=true MAINT_NOTIFY_USERS_NIGHTS=5 run
check '[[ $RC -eq 75 && "$(cat "$T/state/reboot_pending_since")" == 2026-10-29 && "$(mails)" == 0 ]]' "node never free: pending reboot detected at the deferral, users not yet emailed"
STUB_KSTA=3 MAINT_REBOOT=true MAINT_NOTIFY_USERS_NIGHTS=5 TODAY=2026-11-03 run
check '[[ "$(mails)" == 2 ]]' "node never free: users emailed after 5 nights of pending reboot"

reset_env; blockers_fixture; echo 1 > "$T/sess"; echo 2026-10-24 > "$T/state/reboot_pending_since"; MAINT_NOTIFY_USERS_NIGHTS=5 run
check '[[ "$(mails)" == 0 ]]' "MAINT_REBOOT=false: users are never asked to leave"
reset_env; blockers_fixture; echo 1 > "$T/sess"; echo 2026-10-24 > "$T/state/first_deferred"; MAINT_REBOOT=true MAINT_NOTIFY_USERS_NIGHTS=5 run
check '[[ "$(mails)" == 0 ]]' "no reboot pending: updates alone never email users"
reset_env; blockers_fixture; echo 1 > "$T/sess"; echo 2026-10-24 > "$T/state/reboot_pending_since"; MAINT_REBOOT=true MAINT_NOTIFY_USERS_NIGHTS=5 MAINT_NOTIFY_ADMIN_NIGHTS=1 run --force-window
check '[[ "$(mails)" == 0 ]]' "--force-window (supervised): no emails"

reset_env; blockers_fixture; echo 1 > "$T/sess"; echo 2026-10-24 > "$T/state/reboot_pending_since"
MAINT_REBOOT=true MAINT_NOTIFY_USERS_NIGHTS=5 MAINT_MAIL_HELPERS="$T/helpers_v2.sh" run
check 'grep -q "^MAIL to=martina.livornese2@unibo.example " "$T/log" && grep -q "martina.livornese2 .*address from ad" "$T/log" && grep -q "^MAIL to=m.rossi@example.org " "$T/log" && grep -q "mario.rossi .*address from map" "$T/log"' "shared helper with resolve_user_email_source (ADR-0010): its address and source are used"

reset_env; blockers_fixture; echo 1 > "$T/sess"; echo 2026-10-24 > "$T/state/reboot_pending_since"
MAINT_REBOOT=true MAINT_NOTIFY_USERS_NIGHTS=5 MAINT_MAIL_CONF="$T/missing.conf" run
check '[[ $RC -eq 75 && "$(mails)" == 0 ]] && [[ "$OUT" == *"mail config not readable"* ]]' "mail config missing: warning, run still deferred normally"
reset_env; blockers_fixture; echo 1 > "$T/sess"; echo 2026-10-26 > "$T/state/first_deferred"; STUB_MAIL_RC=1 MAINT_NOTIFY_ADMIN_NIGHTS=3 run
check '[[ $RC -eq 75 ]] && grep -q "admin email failed" "$T/log"' "relay failure: journal warning, exit code unchanged"

echo "## post-boot check"
reset_env; run --post-boot
check '[[ $RC -eq 0 && "$OUT" == *"no reboot requested"* && ! -e "$T/state/postboot_report.json" ]]' "ordinary boot: nothing checked"
reset_env; echo 2026-10-20 > "$T/state/reboot_pending_since"; echo '{"expected_kernel":"6.8.0-51-generic"}' > "$T/state/reboot_requested"
STUB_UNAME=6.8.0-51-generic run --post-boot
check '[[ $RC -eq 0 && "$(jq -r .status "$T/state/postboot_report.json")" == ok && ! -e "$T/state/reboot_requested" && ! -e "$T/state/reboot_pending_since" ]]' "after our reboot: all up, report ok, markers cleared"
reset_env; echo '{"expected_kernel":"6.8.0-51-generic"}' > "$T/state/reboot_requested"
STUB_UNAME=6.8.0-50-generic STUB_INACTIVE="rstudio-server" STUB_UNMOUNTED="/nfs/home" run --post-boot
check '[[ $RC -eq 1 ]] && jq -e ".note | test(\"rstudio-server not active\") and test(\"NFS /nfs/home not mounted\") and test(\"expected 6.8.0-51\")" "$T/state/postboot_report.json" >/dev/null' "failures named: service, NFS mount (noauto ignored), wrong kernel"
check 'grep -q "^MAIL to=admin@example.org subj=\[calc-test\] FAILED check after maintenance reboot" "$T/log" && grep -q "daemon.err" "$T/log"' "failure mailed to the admin and logged as error"

echo "## install / remove (in-place, rollback)"
reset_env; run --install-timer
check '[[ $RC -eq 0 && -f "$T/nr/biome-rstudio.conf" && -f "$T/systemd/biome-node-maintenance.service" ]]' "install writes needrestart fragment and units"
check 'grep -q "OnCalendar=\*-\*-\* 03..04:00/15:00" "$T/systemd/biome-node-maintenance.timer"' "timer covers 03:00-04:45 for the 0330-0500 window"
check 'grep -q "ExecStart=/usr/bin/env bash .*/scripts/biome_node_maintenance.sh" "$T/systemd/biome-node-maintenance.service"' "service runs the repo script"
check 'grep -q "ExecStart=/usr/bin/env bash .*/scripts/biome_node_maintenance.sh --post-boot" "$T/systemd/biome-node-postboot.service" && grep -q "systemctl enable biome-node-postboot.service" "$T/log"' "post-boot unit installed and enabled"
check 'grep -q "systemctl disable --now apt-daily-upgrade.timer" "$T/log" && grep -q "systemctl enable --now biome-node-maintenance.timer" "$T/log"' "stock upgrade timer disabled, ours enabled"
check '[[ "$(cat "$T/state/apt_upgrade_timer_was")" == enabled ]]' "previous apt-daily-upgrade.timer state saved"
STUB_APT_TIMER=disabled run --install-timer
check '[[ $RC -eq 0 && "$(cat "$T/state/apt_upgrade_timer_was")" == enabled ]]' "re-install is idempotent and keeps the original timer state"
run --remove-timer
check '[[ $RC -eq 0 && ! -e "$T/nr/biome-rstudio.conf" && ! -e "$T/systemd/biome-node-maintenance.timer" && ! -e "$T/systemd/biome-node-postboot.service" ]] && grep -q "systemctl enable --now apt-daily-upgrade.timer" "$T/log"' "remove = rollback: files gone, stock timer back"

echo "## needrestart fragment"
if command -v perl >/dev/null 2>&1; then
  res="$(perl -e 'our %nrconf; do $ARGV[0]; die $@ if $@;
                  my ($re) = grep { $nrconf{override_rc}{$_} == 0 } keys %{$nrconf{override_rc}};
                  print join(",", map { $_ =~ $re ? 1 : 0 } qw(rstudio-server.service nginx.service sssd.service)), "\n"' "$NR_TEMPLATE" 2>&1)"
  if [[ "$res" == "1,0,0" ]]; then pass "fragment parses; excludes rstudio-server.service only"; else fail "needrestart fragment: got '$res'"; fi
else
  echo "SKIP: perl not available"
fi

echo
if (( fails > 0 )); then echo "${fails} test(s) failed"; exit 1; fi
echo "all tests passed"
