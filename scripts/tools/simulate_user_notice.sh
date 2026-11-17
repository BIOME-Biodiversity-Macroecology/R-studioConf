#!/usr/bin/env bash
set -euo pipefail
# scripts/tools/simulate_user_notice.sh
#
# Simulated orphan-cleanup notice for one or more users: runs the REAL
# notify_r_orphans.sh and the REAL resolver (map -> AD -> pattern, ADR-0010)
# from this checkout, but with a FAKE send_email.sh that only records what it
# would send. Nothing is mailed, nothing under /etc or /var/log is written.
#
# Usage:
#   sudo bash scripts/tools/simulate_user_notice.sh USER [USER...]
#   Env: AD_URI, AD_BASE (default: USER_MAIL_AD_URI / USER_MAIL_AD_BASE_DN from
#        config/site/setup_nodes.site.vars.conf), CONF_SRC (deployed conf to copy,
#        default /etc/biome-calc/conf/r_orphan_cleanup.conf)
# Output: notify.log lines (to=, source=map|ad|pattern), the fake send calls and
#         the mail bodies, in a mktemp directory left for inspection.

readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SITE_VARS="${W}/config/site/setup_nodes.site.vars.conf"
CONF_SRC="${CONF_SRC:-/etc/biome-calc/conf/r_orphan_cleanup.conf}"

(($#)) || { echo "Usage: $0 USER [USER...]" >&2; exit 2; }
for bin in sed mktemp; do
  command -v "$bin" >/dev/null 2>&1 || { printf '%b[FAIL]%b missing %s\n' "$C_RED" "$C_RESET" "$bin" >&2; exit 1; }
done
[[ -f "$CONF_SRC" ]] || { printf '%b[FAIL]%b not found: %s\n' "$C_RED" "$C_RESET" "$CONF_SRC" >&2; exit 1; }
site_value() { [[ -f "$SITE_VARS" ]] && grep -E "^${1}=" "$SITE_VARS" | tail -1 | cut -d= -f2- | tr -d '"' || true; }
AD_URI="${AD_URI:-$(site_value USER_MAIL_AD_URI)}"
AD_BASE="${AD_BASE:-$(site_value USER_MAIL_AD_BASE_DN)}"
[[ -n "$AD_URI" && -n "$AD_BASE" ]] \
  || printf '%b[WARN]%b AD_URI/AD_BASE not set: only map and pattern will be used\n' "$C_YELLOW" "$C_RESET" >&2
[[ "$(id -u)" -eq 0 ]] \
  || printf '%b[WARN]%b not root: the host keytab is unreadable, the AD step will fall back\n' "$C_YELLOW" "$C_RESET" >&2

S="$(mktemp -d /tmp/user-notice-sim.XXXXXX)"
cp "$CONF_SRC" "$S/conf"
cat >> "$S/conf" <<EOF
USER_MAIL_AD_URI="${AD_URI}"
USER_MAIL_AD_BASE_DN="${AD_BASE}"
USER_MAIL_AD_TIMEOUT="10"
SEND_EMAIL_SCRIPT="$S/fake_send.sh"
LOG_DIR="$S/log"
NOTIFY_DIR="$S/notif"
EOF
cat > "$S/fake_send.sh" <<EOF
#!/usr/bin/env bash
echo "FAKE send_email.sh \$*" >> "$S/sent.txt"
while [ \$# -gt 0 ]; do [ "\$1" = "-m" ] && cp "\$2" "$S/body_\$\$.txt"; shift; done
exit 0
EOF
chmod +x "$S/fake_send.sh"
mkdir -p "$S/notif" "$S/log"
for u in "$@"; do
  echo "$(date '+%F %T') | PROCESSO ORFANO TERMINATO | SIMULATED TEST, nothing was killed" > "$S/notif/$u.log"
done
sed -e "s#^CONF_FILE=.*#CONF_FILE=\"$S/conf\"#" \
    -e "s#^HELPERS=.*#HELPERS=\"$W/templates/orphan_cleanup_helpers.sh.template\"#" \
    "$W/templates/notify_r_orphans.sh.template" > "$S/notify.sh"
bash "$S/notify.sh" --mail || true

echo "== notify.log";  cat "$S/log/notify.log"
echo "== fake send";   cat "$S/sent.txt" 2>/dev/null || echo "(nothing would be sent)"
printf '%b== kept in %s (bodies: body_*.txt); remove with: rm -rf %s%b\n' "$C_GREEN" "$S" "$S" "$C_RESET"
