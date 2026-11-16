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
case "${STUB_LDAP:-ok}" in
  down)  echo "ldap_sasl_interactive_bind_s: Can't contact LDAP server (-1)" >&2; exit 255 ;;
  hang)  sleep 30; exit 0 ;;
  none)  printf 'dn: CN=Uni1,OU=x,DC=example,DC=org\n\n'; exit 0 ;;
  bad)   printf 'dn: CN=Uni1,OU=x,DC=example,DC=org\nmail: not-an-address\n\n'; exit 0 ;;
  ok)    printf 'dn: CN=Uni01193179,OU=Str,DC=example,DC=org\nmail: %s\n\n' "${STUB_AD_MAIL:-mario.rossi7@example.org}"; exit 0 ;;
esac
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

echo "x" > "$H/var/log/biome-log/r_orphan_cleanup/notifications/mario.rossi7.log"
echo "x" > "$H/var/log/biome-log/r_orphan_cleanup/notifications/.sent/anna.verdi_20261101.log"
out="$(fx --check-notified 2>/dev/null)"
grep -q '^mario.rossi7 mario.rossi7@example.org ad$' <<<"$out" && pass "--check-notified resolves via AD" || fail "--check-notified: $out"
grep -q '^TOTAL 2  map=0  ad=2  pattern=0$' <<<"$out" && pass "--check-notified prints the source counts" || fail "--check-notified totals: $out"

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

if (( FAILS > 0 )); then
  printf '%b%d test(s) failed%b\n' "$C_RED" "$FAILS" "$C_RESET"
  exit 1
fi
printf '%bAll user e-mail resolver tests passed%b\n' "$C_GREEN" "$C_RESET"
