#!/usr/bin/env bash
set -euo pipefail
# tests/test_user_email_resolver.sh — templates/orphan_cleanup_helpers.sh.template
# resolve_user_email_source / resolve_user_email / ad_lookup_user_mail:
# order map -> AD -> pattern, private Kerberos ccache, timeout and fallback.
# Stubs kinit, ldapsearch, kdestroy and hostname; no network, no real AD.
# Run: bash tests/test_user_email_resolver.sh

readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_RESET='\033[0m'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="${ROOT}/templates/orphan_cleanup_helpers.sh.template"
NOTIFY="${ROOT}/templates/notify_r_orphans.sh.template"
T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
FAILS=0
pass() { printf '%bPASS%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
fail() { printf '%bFAIL%b %s\n' "$C_RED" "$C_RESET" "$*"; FAILS=$((FAILS + 1)); }
check() {  # NAME EXPECTED ACTUAL
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

for bin in timeout awk mktemp; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing required binary: $bin" >&2; exit 1; }
done

mkdir -p "$T/bin"
cat > "$T/bin/hostname" <<'EOF'
#!/usr/bin/env bash
echo "biome-calc04"
EOF
cat > "$T/bin/kinit" <<'EOF'
#!/usr/bin/env bash
echo "kinit $* ccache=${KRB5CCNAME:-unset}" >> "$STUB_LOG"
[[ "${STUB_KINIT_FAIL:-}" == 1 ]] && exit 1
f="${KRB5CCNAME#FILE:}"
[[ -d "$(dirname "$f")" ]] && : > "$f"
exit 0
EOF
cat > "$T/bin/ldapsearch" <<'EOF'
#!/usr/bin/env bash
echo "ldapsearch $* ccache=${KRB5CCNAME:-unset}" >> "$STUB_LOG"
h=""; prev=""; for a in "$@"; do [[ "$prev" == -H ]] && h="$a"; prev="$a"; done
if [[ -n "${STUB_LDAP_DOWN_HOSTS:-}" && " ${STUB_LDAP_DOWN_HOSTS} " == *" ${h#ldap://} "* ]]; then
  echo "SASL(-1): generic failure: GSSAPI Error: Unspecified GSS failure. (Server not found in Kerberos database)" >&2; exit 254
fi
case "${STUB_LDAP:-ok}" in
  down)  echo "ldap_sasl_interactive_bind_s: Can't contact LDAP server (-1)" >&2; exit 255 ;;
  hang)  sleep 30; exit 0 ;;
  none)  printf 'dn: CN=Uni1,OU=x,DC=example,DC=org\n\n'; exit 0 ;;
  empty) exit 0 ;;
  bad)   printf 'dn: CN=Uni1,OU=x,DC=example,DC=org\nmail: not-an-address\n\n'; exit 0 ;;
  ok)    printf 'dn: CN=Uni01193179,OU=Str,DC=example,DC=org\nmail: %s\n\n' "${STUB_AD_MAIL:-mario.rossi7@example.org}"; exit 0 ;;
esac
EOF
cat > "$T/bin/host" <<'EOF'
#!/usr/bin/env bash
# host -t SRV _ldap._tcp.<domain>: two DCs when STUB_SRV=1, else NXDOMAIN
echo "host $*" >> "$STUB_LOG"
if [[ "${STUB_SRV:-}" == 1 ]]; then
  echo "${3} has SRV record 0 100 389 dc2.example.org."
  echo "${3} has SRV record 0 100 389 dc3.example.org."
  echo "${3} has SRV record 0 50 389 dc1.example.org."
  exit 0
fi
echo "Host ${3} not found: 3(NXDOMAIN)"; exit 1
EOF
cat > "$T/bin/kdestroy" <<'EOF'
#!/usr/bin/env bash
echo "kdestroy ccache=${KRB5CCNAME:-unset}" >> "$STUB_LOG"
rm -f "${KRB5CCNAME#FILE:}"
EOF
chmod +x "$T/bin/"*

cat > "$T/map.txt" <<'EOF'
# username   address
anna.bianchi  anna.b@other.example.org
EOF

export STUB_LOG="$T/stub.log"

# run 'SHELL_CODE' with the helpers sourced, a clean env and the stubs first in PATH.
# Extra VAR=value arguments go into the environment.
run() {
  local code="$1"; shift
  : > "$STUB_LOG"
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" STUB_LOG="$STUB_LOG" \
      USER_EMAIL_MAP_FILE="$T/map.txt" "$@" \
      bash -c "set -u; source '$SUT'; $code"
}
AD=(USER_MAIL_AD_URI=ldap://ad.example.org "USER_MAIL_AD_BASE_DN=dc=example,dc=org" USER_MAIL_AD_TIMEOUT=2)

# 1. map wins, AD not queried
out="$(run 'resolve_user_email_source anna.bianchi example.org' "${AD[@]}")"
check "map entry wins" "anna.b@other.example.org map" "$out"
check "map entry: no AD query" "" "$(grep -c ldapsearch "$STUB_LOG" | grep -v '^0$' || true)"

# 2. AD mail attribute
out="$(run 'resolve_user_email_source mario.rossi7 example.org' "${AD[@]}" MAIL_DOMAINS_USER="example.org students.example.org")"
check "AD mail used before the pattern" "mario.rossi7@example.org ad" "$out"
grep -q 'kinit -k BIOME-CALC04\$ ' "$STUB_LOG" && pass "kinit uses the host principal HOST\$" || fail "kinit principal: $(cat "$STUB_LOG")"
grep -q '(sAMAccountName=mario.rossi7) mail' "$STUB_LOG" && pass "ldapsearch filter on sAMAccountName" || fail "ldapsearch filter: $(cat "$STUB_LOG")"
grep -q -- '-H ldap://ad.example.org -b dc=example,dc=org' "$STUB_LOG" && pass "ldapsearch uses URI and base DN from the conf" || fail "ldapsearch args: $(cat "$STUB_LOG")"
cc="$(sed -n 's/^kinit .*ccache=FILE:\(.*\)$/\1/p' "$STUB_LOG" | head -1)"
if [[ -n "$cc" && "$cc" != /tmp/krb5cc_* ]] && grep -q "ldapsearch .*ccache=FILE:${cc}$" "$STUB_LOG"; then
  pass "kinit and ldapsearch share one private ccache"
else
  fail "private ccache: $(cat "$STUB_LOG")"
fi
[[ ! -e "$(dirname "$cc")" ]] && pass "private ccache removed after the lookup" || fail "ccache dir left behind: $(dirname "$cc")"

# 2b. USER_MAIL_AD_DEBUG=1 explains an empty AD result on stderr, stdout unchanged
why() { run "USER_MAIL_AD_DEBUG=1 resolve_user_email_source mario.rossi7 example.org 2>&1 >/dev/null" "${AD[@]}" "$@"; }
[[ "$(why STUB_LDAP=down)" == *"ldapsearch failed on every DC tried: ldap://ad.example.org rc 255: ldap_sasl_interactive_bind_s"* ]] && pass "debug: ldapsearch error reported" || fail "debug down: $(why STUB_LDAP=down)"
[[ "$(why STUB_KINIT_FAIL=1)" == *"kinit -k BIOME-CALC04\$ failed"* ]] && pass "debug: kinit failure reported" || fail "debug kinit: $(why STUB_KINIT_FAIL=1)"
[[ "$(why STUB_LDAP=hang)" == *"ldap://ad.example.org rc 124"* ]] && pass "debug: timeout reported" || fail "debug hang: $(why STUB_LDAP=hang)"
[[ "$(why STUB_LDAP=none)" == *"account has no mail attribute"* ]] && pass "debug: missing mail reported" || fail "debug none: $(why STUB_LDAP=none)"
[[ "$(why STUB_LDAP=empty)" == *"no AD account with sAMAccountName=mario.rossi7"* ]] && pass "debug: unknown account reported" || fail "debug empty: $(why STUB_LDAP=empty)"
check "debug off: stderr silent" "" "$(run 'resolve_user_email_source mario.rossi7 example.org 2>&1 >/dev/null' "${AD[@]}" STUB_LDAP=down)"

# 2c. DCs from the SRV record, tried in priority order with -N (no reverse DNS)
out="$(run 'resolve_user_email_source mario.rossi7 example.org' "${AD[@]}" STUB_SRV=1 STUB_LDAP_DOWN_HOSTS="dc1.example.org")"
check "SRV: first DC down, second answers" "mario.rossi7@example.org ad" "$out"
check "SRV: DCs tried in priority order" "ldap://dc1.example.org ldap://dc2.example.org" "$(sed -n 's/^ldapsearch .*-H \([^ ]*\) .*/\1/p' "$STUB_LOG" | tr '\n' ' ' | sed 's/ $//')"
grep -q '^ldapsearch -N ' "$STUB_LOG" && pass "ldapsearch runs with -N (no SASL host canonicalisation)" || fail "no -N: $(cat "$STUB_LOG")"
out="$(run 'resolve_user_email_source mario.rossi7 example.org' "${AD[@]}" STUB_SRV=1 STUB_LDAP_DOWN_HOSTS="dc1.example.org dc2.example.org dc3.example.org" USER_MAIL_AD_MAX_DCS=2)"
check "SRV: every DC down -> pattern" "mario.rossi7@example.org pattern" "$out"
check "SRV: at most USER_MAIL_AD_MAX_DCS DCs tried" "2" "$(grep -c '^ldapsearch ' "$STUB_LOG")"
w="$(why STUB_SRV=1 STUB_LDAP_DOWN_HOSTS="dc1.example.org dc2.example.org dc3.example.org")"
[[ "$w" == *"ldap://dc1.example.org rc 254"*"Server not found in Kerberos database"*"ldap://dc3.example.org rc 254"* ]] \
  && pass "debug: per-DC GSSAPI errors reported" || fail "debug SRV: $w"

# 3. resolve_user_email keeps the legacy interface (address only)
out="$(run 'resolve_user_email mario.rossi7 example.org' "${AD[@]}")"
check "resolve_user_email prints the address only" "mario.rossi7@example.org" "$out"

# 4. AD disabled (no URI) -> multi-domain pattern, no Kerberos at all
out="$(run 'resolve_user_email_source mario.rossi7 example.org' MAIL_DOMAINS_USER="example.org students.example.org")"
check "AD disabled: multi-domain pattern" "mario.rossi7@example.org,mario.rossi7@students.example.org pattern" "$out"
check "AD disabled: no kinit" "" "$(cat "$STUB_LOG")"

# 5. AD disabled and no MAIL_DOMAINS_USER -> default domain
out="$(run 'resolve_user_email_source mario.rossi7 example.org')"
check "single-domain fallback" "mario.rossi7@example.org pattern" "$out"

# 6. unsubstituted envsubst tokens from an old deploy count as empty
out="$(run 'resolve_user_email_source mario.rossi7 example.org' 'USER_MAIL_AD_URI=${USER_MAIL_AD_URI}' 'USER_MAIL_AD_BASE_DN=${USER_MAIL_AD_BASE_DN}' 'MAIL_DOMAINS_USER=${MAIL_DOMAINS_USER}')"
check "literal \${...} tokens disable AD and the domain list" "mario.rossi7@example.org pattern" "$out"

# 7. AD account without mail attribute -> pattern
out="$(run 'resolve_user_email_source mario.rossi7 example.org' "${AD[@]}" STUB_LDAP=none)"
check "no mail attribute: pattern fallback" "mario.rossi7@example.org pattern" "$out"

# 8. malformed mail attribute is not used
out="$(run 'resolve_user_email_source mario.rossi7 example.org' "${AD[@]}" STUB_LDAP=bad)"
check "malformed AD mail rejected" "mario.rossi7@example.org pattern" "$out"

# 9. AD unreachable -> pattern
out="$(run 'resolve_user_email_source mario.rossi7 example.org' "${AD[@]}" STUB_LDAP=down)"
check "AD unreachable: pattern fallback" "mario.rossi7@example.org pattern" "$out"

# 10. kinit fails (no keytab / not root) -> pattern, ldapsearch not run
out="$(run 'resolve_user_email_source mario.rossi7 example.org' "${AD[@]}" STUB_KINIT_FAIL=1)"
check "kinit failure: pattern fallback" "mario.rossi7@example.org pattern" "$out"
grep -q ldapsearch "$STUB_LOG" && fail "ldapsearch ran without a ticket" || pass "no ldapsearch without a ticket"

# 11. AD hangs -> bounded by the timeout, then pattern
start=$(date +%s)
out="$(run 'resolve_user_email_source mario.rossi7 example.org' "${AD[@]}" STUB_LDAP=hang)"
elapsed=$(( $(date +%s) - start ))
check "AD hang: pattern fallback" "mario.rossi7@example.org pattern" "$out"
(( elapsed <= 6 )) && pass "AD hang bounded by USER_MAIL_AD_TIMEOUT (${elapsed}s)" || fail "AD hang took ${elapsed}s"

# 12. LDAP filter injection: username outside the safe charset is never sent
out="$(run 'resolve_user_email_source "x*)(mail=*" example.org' "${AD[@]}")"
check "unsafe username: no AD query" "" "$(cat "$STUB_LOG")"
[[ "$out" == *" pattern" ]] && pass "unsafe username falls back to pattern" || fail "unsafe username: '$out'"

# 13. missing ldapsearch -> pattern (PATH without the stub and without ldap-utils)
mkdir -p "$T/nobin"
for b in bash env awk mktemp rm tr timeout hostname dirname cat sleep; do
  p="$(command -v "$b")"; ln -sf "$p" "$T/nobin/$b"
done
ln -sf "$T/bin/kinit" "$T/nobin/kinit"; ln -sf "$T/bin/hostname" "$T/nobin/hostname"
: > "$STUB_LOG"
out="$(env -i PATH="$T/nobin" HOME="$T" STUB_LOG="$STUB_LOG" USER_EMAIL_MAP_FILE="$T/map.txt" "${AD[@]}" \
       "$T/nobin/bash" -c "set -u; source '$SUT'; resolve_user_email_source mario.rossi7 example.org")"
check "ldapsearch missing: pattern fallback" "mario.rossi7@example.org pattern" "$out"

# 14. works with set +u in a subshell (how biome_node_maintenance.sh calls it)
out="$(env -i PATH="$T/bin:/usr/bin:/bin" STUB_LOG="$STUB_LOG" USER_EMAIL_MAP_FILE="$T/map.txt" \
       bash -c "set -euo pipefail; ( set +u; source '$SUT'; USER_MAIL_AD_URI=ldap://ad.example.org USER_MAIL_AD_BASE_DN=dc=x resolve_user_email_source mario.rossi7 '' )")"
check "subshell with set +u" "mario.rossi7@example.org ad" "$out"

# 15. notify_r_orphans uses the shared resolver and logs the source
grep -q 'resolve_user_email_source "\$USERNAME"' "$NOTIFY" && pass "notify_r_orphans uses resolve_user_email_source" || fail "notify_r_orphans does not use resolve_user_email_source"
grep -q 'source=\${MAIL_SOURCE}' "$NOTIFY" && pass "notify_r_orphans logs the address source" || fail "notify_r_orphans does not log the source"

# 16. the conf template exposes the AD keys
for k in USER_MAIL_AD_URI USER_MAIL_AD_BASE_DN USER_MAIL_AD_TIMEOUT; do
  grep -q "^${k}=\"\${${k}}\"" "${ROOT}/templates/r_orphan_cleanup.conf.template" \
    && pass "r_orphan_cleanup.conf.template has ${k}" || fail "r_orphan_cleanup.conf.template lacks ${k}"
  grep -q "\\\\\${${k}}" "${ROOT}/scripts/50_setup_nodes.sh" \
    && pass "50_setup_nodes.sh substitutes ${k}" || fail "50_setup_nodes.sh does not substitute ${k}"
done

# ── scripts/fix_user_mail_ad_inplace.sh (in-place hotfix) ─────────────────────
FIX="${ROOT}/scripts/fix_user_mail_ad_inplace.sh"
H="$T/host"
mkdir -p "$H/etc/biome-calc/conf" "$H/etc/biome-calc/script" "$H/var/log/biome-log/r_orphan_cleanup/notifications/.sent"
cat > "$H/etc/biome-calc/conf/r_orphan_cleanup.conf" <<'EOF'
SMTP_HOST="smtp.example.org"
MAIL_DOMAIN="example.org"
MAIL_DOMAINS_USER="example.org students.example.org"
EOF
echo "# old helpers" > "$H/etc/biome-calc/script/orphan_cleanup_helpers.sh"
echo "# old notify" > "$H/etc/biome-calc/script/notify_r_orphans.sh"
: > "$H/etc/biome-calc/conf/user_email_map.txt"
cat > "$T/site.conf" <<'EOF'
USER_MAIL_AD_URI="ldap://ad.example.org"
USER_MAIL_AD_BASE_DN="dc=example,dc=org"
EOF
orig_sum="$(cat "$H/etc/biome-calc/conf/r_orphan_cleanup.conf" "$H/etc/biome-calc/script/"* | sha256sum)"
fx() {
  : > "$STUB_LOG"
  env PATH="$T/bin:$PATH" FIX_USER_MAIL_ROOT="$H" FIX_USER_MAIL_BACKUP_ROOT="$T/bk" \
      FIX_USER_MAIL_SITE_VARS="$T/site.conf" STUB_LOG="$STUB_LOG" bash "$FIX" "$@"
}

fx >/dev/null 2>&1 && pass "hotfix dry-run exits 0" || fail "hotfix dry-run failed"
check "hotfix dry-run writes nothing" "$orig_sum" "$(cat "$H/etc/biome-calc/conf/r_orphan_cleanup.conf" "$H/etc/biome-calc/script/"* | sha256sum)"

if fx --commit >/dev/null 2>&1; then pass "hotfix --commit exits 0"; else fail "hotfix --commit failed"; fi
grep -q '^USER_MAIL_AD_URI="ldap://ad.example.org"$' "$H/etc/biome-calc/conf/r_orphan_cleanup.conf" \
  && pass "hotfix sets USER_MAIL_AD_URI" || fail "hotfix did not set USER_MAIL_AD_URI"
grep -q '^SMTP_HOST="smtp.example.org"$' "$H/etc/biome-calc/conf/r_orphan_cleanup.conf" \
  && pass "hotfix keeps the other conf lines" || fail "hotfix lost conf lines"
cmp -s "$SUT" "$H/etc/biome-calc/script/orphan_cleanup_helpers.sh" && pass "hotfix installs the new helpers" || fail "helpers not installed"
cmp -s "$NOTIFY" "$H/etc/biome-calc/script/notify_r_orphans.sh" && pass "hotfix installs the new notify script" || fail "notify not installed"
bk="$(find "$T/bk" -maxdepth 1 -name 'user-mail-ad-hotfix-*' | head -1)"
[[ -f "$bk/MANIFEST" ]] && pass "hotfix writes a backup with MANIFEST" || fail "no backup manifest"

fx --commit 2>&1 | grep -q "Already applied" && pass "hotfix is idempotent" || fail "second --commit was not a no-op"
check "idempotent: one AD block only" "1" "$(grep -c '^USER_MAIL_AD_URI=' "$H/etc/biome-calc/conf/r_orphan_cleanup.conf")"

out="$(fx --check-notified 2>/dev/null)"
grep -q '^TOTAL 0  map=0  ad=0  pattern=0$' <<<"$out" && pass "--check-notified with no notices reports TOTAL 0" || fail "--check-notified empty: $out"
echo "x" > "$H/var/log/biome-log/r_orphan_cleanup/notifications/mario.rossi7.log"
echo "x" > "$H/var/log/biome-log/r_orphan_cleanup/notifications/.sent/anna.verdi_20261101.log"
out="$(fx --check-notified 2>/dev/null)"
grep -q '^mario.rossi7 mario.rossi7@example.org ad$' <<<"$out" && pass "--check-notified resolves via AD" || fail "--check-notified: $out"
grep -q '^TOTAL 2  map=0  ad=2  pattern=0$' <<<"$out" && pass "--check-notified prints the source counts" || fail "--check-notified totals: $out"
mkdir -p "$H/var/log/r_orphan_cleanup/notifications"
echo "x" > "$H/var/log/r_orphan_cleanup/notifications/luca.neri.log"
out="$(fx --check-notified 2>/dev/null)"
grep -q '^luca.neri [^ ]*@example.org ad$' <<<"$out" && pass "--check-notified also scans the legacy /var/log/r_orphan_cleanup dir" || fail "--check-notified legacy dir: $out"

fx --rollback "$bk" >/dev/null 2>&1 && pass "hotfix --rollback exits 0" || fail "hotfix --rollback failed"
check "rollback restores every file" "$orig_sum" "$(cat "$H/etc/biome-calc/conf/r_orphan_cleanup.conf" "$H/etc/biome-calc/script/"* | sha256sum)"

: > "$T/empty.conf"
if env FIX_USER_MAIL_ROOT="$H" FIX_USER_MAIL_BACKUP_ROOT="$T/bk" FIX_USER_MAIL_SITE_VARS="$T/empty.conf" \
     bash "$FIX" --commit >/dev/null 2>&1; then
  fail "hotfix without AD settings must refuse"
else
  pass "hotfix refuses without USER_MAIL_AD_URI/BASE_DN"
fi
if fx --uri 'ldap://x" ; rm -rf /' --commit >/dev/null 2>&1; then fail "hotfix accepted a quoted value"; else pass "hotfix rejects quotes in values"; fi

# ── scripts/tools/simulate_user_notice.sh (fake send, real resolver) ─────────
SIM="${ROOT}/scripts/tools/simulate_user_notice.sh"
printf 'SMTP_HOST="smtp.example.org"\nSMTP_PORT="25"\nSENDER_EMAIL="noreply@example.org"\nDNS_SERVERS="192.0.2.10"\nMAIL_DOMAIN="example.org"\nMAIL_DOMAINS_USER="example.org"\nADMIN_EMAIL="admin@example.org"\n' > "$T/deployed.conf"
out="$(env PATH="$T/bin:$PATH" STUB_LOG="$STUB_LOG" CONF_SRC="$T/deployed.conf" AD_URI=ldap://ad.example.org AD_BASE=dc=example,dc=org \
       bash "$SIM" mario.rossi7 2>/dev/null)"
grep -q 'to=mario.rossi7@example.org | source=ad' <<<"$out" && pass "simulator logs the AD address and source" || fail "simulator: $out"
grep -q '^FAKE send_email.sh .*-T mario.rossi7@example.org ' <<<"$out" && pass "simulator calls only the fake send" || fail "simulator send: $out"
sim_dir0="$(sed -n 's/.*kept in \([^ ]*\).*/\1/p' <<<"$out")"
[[ -n "$sim_dir0" && "$sim_dir0" == /tmp/user-notice-sim.* ]] && rm -rf "$sim_dir0"
# AD keys only in the deployed conf (after --commit), none in the environment
cp "$T/deployed.conf" "$T/deployed_ad.conf"
printf 'USER_MAIL_AD_URI="ldap://ad.example.org"\nUSER_MAIL_AD_BASE_DN="dc=example,dc=org"\n' >> "$T/deployed_ad.conf"
out="$(env -u AD_URI -u AD_BASE PATH="$T/bin:$PATH" STUB_LOG="$STUB_LOG" CONF_SRC="$T/deployed_ad.conf" \
       bash "$SIM" mario.rossi7 2>/dev/null)"
grep -q 'source=ad' <<<"$out" && pass "simulator keeps the AD keys of the deployed conf" || fail "simulator conf AD keys: $out"
sim_dir="$(sed -n 's/.*kept in \([^ ]*\).*/\1/p' <<<"$out")"
[[ -n "$sim_dir" && "$sim_dir" == /tmp/user-notice-sim.* ]] && rm -rf "$sim_dir"

if (( FAILS > 0 )); then
  printf '%b%d test(s) failed%b\n' "$C_RED" "$FAILS" "$C_RESET"
  exit 1
fi
printf '%bAll user e-mail resolver tests passed%b\n' "$C_GREEN" "$C_RESET"
