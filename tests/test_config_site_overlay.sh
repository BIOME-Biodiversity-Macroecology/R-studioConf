#!/usr/bin/env bash
set -euo pipefail
# tests/test_config_site_overlay.sh — ADR-0011 site overlay for every
# config/<name>.vars.conf (lib/site_overlay.sh) and the in-place migration
# scripts/fix_config_site_overlay_inplace.sh, which moves host values out of
# locally modified TRACKED config files into gitignored config/site/ so that
# `git pull --ff-only` works again on calc01-04.
#
# Everything runs in throwaway git repositories under mktemp: no root, no
# /etc, no network. The invariant under test is "the effective configuration
# every script sees is the same before and after the migration".
# Run: bash tests/test_config_site_overlay.sh

readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_RESET='\033[0m'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib/site_overlay.sh"
SUT="${ROOT}/scripts/fix_config_site_overlay_inplace.sh"
T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
FAILS=0
pass() { printf '%bPASS%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
fail() { printf '%bFAIL%b %s\n' "$C_RED" "$C_RESET" "$*"; FAILS=$((FAILS + 1)); }
check() {  # NAME EXPECTED ACTUAL
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
contains() {  # NAME NEEDLE HAYSTACK
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1 (missing '$2' in: ${3:0:600})"; fi
}
lacks() {  # NAME NEEDLE HAYSTACK
  if [[ "$3" != *"$2"* ]]; then pass "$1"; else fail "$1 (unexpected '$2')"; fi
}

for bin in git mktemp sha256sum awk; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing required binary: $bin" >&2; exit 1; }
done
[[ -f "$LIB" ]] || { fail "lib/site_overlay.sh exists"; echo "1 failure(s)"; exit 1; }
[[ -f "$SUT" ]] || { fail "scripts/fix_config_site_overlay_inplace.sh exists"; echo "1 failure(s)"; exit 1; }

# shellcheck source=../lib/site_overlay.sh disable=SC1091
source "$LIB"

# ════════════════════════════════════════════════════════════════════════════
# 1. Library: path, source, get, render
# ════════════════════════════════════════════════════════════════════════════
L="$T/lib"; mkdir -p "$L/config/site"
cat > "$L/config/demo.vars.conf" <<'EOF'
# demo
BASE_DIR="/nfs/home"
TMP_DIR="${BASE_DIR}/Rtmp"
TIMEOUT_MIN="2880"
RPROFILE_VERSION="12.11"
EOF

check "path: X.vars.conf -> site/X.site.vars.conf" \
  "$L/config/site/demo.site.vars.conf" "$(site_overlay_path "$L/config/demo.vars.conf")"
if site_overlay_path "$L/config/r_env_manager.conf" >/dev/null 2>&1; then
  fail "path: non-.vars.conf has no overlay"
else
  pass "path: non-.vars.conf has no overlay"
fi

out="$( ( site_overlay_source "$L/config/demo.vars.conf"; printf '%s|%s' "$TIMEOUT_MIN" "$TMP_DIR" ) 2>&1)"
check "source: no site file -> committed values" "2880|/nfs/home/Rtmp" "$out"

cat > "$L/config/site/demo.site.vars.conf" <<'EOF'
TIMEOUT_MIN="10080"
BASE_DIR="/srv/home"
TMP_DIR="${BASE_DIR}/Rtmp"
EOF
out="$( ( site_overlay_source "$L/config/demo.vars.conf" 2>/dev/null; printf '%s|%s' "$TIMEOUT_MIN" "$TMP_DIR" ) )"
check "source: site value wins, derived line re-evaluated" "10080|/srv/home/Rtmp" "$out"

fn_scope() { site_overlay_source "$L/config/demo.vars.conf" 2>/dev/null; }
out="$( ( fn_scope; printf '%s' "$TIMEOUT_MIN" ) )"
check "source: called inside a function, values reach the caller" "10080" "$out"

echo 'RPROFILE_VERSION="99.0"' >> "$L/config/site/demo.site.vars.conf"
out="$( ( site_overlay_source "$L/config/demo.vars.conf"; printf 'V=%s' "$RPROFILE_VERSION" ) 2>&1)"
contains "source: protected key in site is ignored (rule 19)" "V=12.11" "$out"
contains "source: protected key override is warned about" "RPROFILE_VERSION" "${out%V=*}"

cat > "$L/config/pin_r_version.vars.conf" <<'EOF'
DEFAULT_R_VERSION="4.6.0"
PIN_EXTRA="a"
EOF
echo 'PIN_EXTRA="b"' > "$L/config/site/pin_r_version.site.vars.conf"
out="$( ( site_overlay_source "$L/config/pin_r_version.vars.conf" 2>/dev/null; printf '%s' "$PIN_EXTRA" ) )"
check "source: excluded SSOT file never takes a site overlay" "a" "$out"

out="$( ( set -u; site_overlay_get "$L/config/demo.vars.conf" TIMEOUT_MIN 2>/dev/null ) )"
check "get: overlay value under set -u" "10080" "$out"
out="$( ( set -u; site_overlay_get "$L/config/demo.vars.conf" NOPE 2>/dev/null ) )"
check "get: unknown key -> empty" "" "$out"
out="$( ( set -u; site_overlay_get "$L/config/demo.vars.conf" RPROFILE_VERSION 2>/dev/null ) )"
check "get: protected key -> committed value" "12.11" "$out"

site_overlay_render "$L/config/demo.vars.conf" "$L/deployed.conf" 2>/dev/null
out="$( ( unset TIMEOUT_MIN RPROFILE_VERSION; source "$L/deployed.conf"; printf '%s|%s|%s' "$TIMEOUT_MIN" "$TMP_DIR" "$RPROFILE_VERSION" ) )"
check "render: deployed copy carries the overlay, not the protected key" "10080|/srv/home/Rtmp|12.11" "$out"
h1="$(sha256sum < "$L/deployed.conf")"
site_overlay_render "$L/config/demo.vars.conf" "$L/deployed.conf" 2>/dev/null
check "render: idempotent" "$h1" "$(sha256sum < "$L/deployed.conf")"
# line-based parsers (telemetry_api.py) keep the LAST assignment
last="$(grep -E '^TIMEOUT_MIN=' "$L/deployed.conf" | tail -1)"
check "render: overlay line comes after the committed line" 'TIMEOUT_MIN="10080"' "$last"

# ════════════════════════════════════════════════════════════════════════════
# 2. Migration fixture: a host checkout with locally modified tracked files
# ════════════════════════════════════════════════════════════════════════════
G() { git -C "$REPO" "$@"; }
eff() {  # REPO CONF -> effective state (what scripts see), one declare -p per key
  bash --noprofile --norc -c '
    set +u
    source "$1"
    __before="$(compgen -v)"
    site_overlay_source "$2/config/$3" 2>/dev/null
    for v in $(compgen -v | sort); do
      case "$v" in __before|v|BASH*|_|PIPESTATUS|FUNCNAME|LINENO|RANDOM|SRANDOM|SECONDS|EPOCH*|COLUMNS|LINES|OLDPWD|PWD|SHLVL) continue ;; esac
      grep -qx "$v" <<<"$__before" && continue
      declare -p "$v"
    done' _ "$LIB" "$1" "$2"
}
treehash() {  # REPO -> hash of every file except .git
  (cd "$1" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
}

new_repo() {  # DIR
  REPO="$1"; mkdir -p "$REPO/config" "$REPO/scripts/tools"
  cat > "$REPO/config/configure_rstudio.vars.conf" <<'EOF'
# RStudio settings
R_PROJECTS_ROOT="/nfs/home"
GLOBAL_RSTUDIO_TMP_DIR="${R_PROJECTS_ROOT}/Rtmp"
RSESSION_TIMEOUT_MINUTES="2880" # 2 days
RSERVER_WWW_PORT="8787"
EOF
  cat > "$REPO/config/setup_nodes.vars.conf" <<'EOF'
NFS_HOME="/nfs/home"
SMTP_HOST="smtp.example.org"
RPROFILE_VERSION="12.11"
OLD_KEY="x"
EOF
  cat > "$REPO/config/install_secure_access.vars.conf" <<'EOF'
# path of this file's directory, as install_nginx.vars.conf computes it
_CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
WEB_TERMINAL_PORT="2222"
NEXTCLOUD_TARGET_URL="https://192.168.1.100"
EOF
  cat > "$REPO/config/pin_r_version.vars.conf" <<'EOF'
DEFAULT_R_VERSION="4.6.0"
EOF
  printf '#!/usr/bin/env bash\necho report\n' > "$REPO/scripts/tools/hw_report.sh"
  printf '#!/usr/bin/env bash\necho upstream\n' > "$REPO/scripts/tools/deployment_summary.sh"
  printf 'config/site/\n' > "$REPO/.gitignore"
  G init -q -b main
  G -c user.email=t@t -c user.name=t add -A
  G -c user.email=t@t -c user.name=t commit -qm base
}

# --- host A: the calc02 shape -------------------------------------------------
new_repo "$T/hostA"
A="$T/hostA"
# "upstream" ref (think origin/main) where deployment_summary got a fix that
# the host also applied by hand
G checkout -qb upstream
echo 'echo upstream fix' >> "$A/scripts/tools/deployment_summary.sh"
G -c user.email=t@t -c user.name=t commit -qam "upstream fix"
G checkout -q main
# local edits in tracked config (site values + one comment change)
sed -i -e 's/^RSESSION_TIMEOUT_MINUTES=.*/RSESSION_TIMEOUT_MINUTES="10080" # 7 days on this host/' \
       -e 's|^R_PROJECTS_ROOT=.*|R_PROJECTS_ROOT="/srv/projects"|' \
       -e 's/^# RStudio settings/# RStudio settings (edited on host)/' "$A/config/configure_rstudio.vars.conf"
echo 'EXTRA_LOCAL_KEY="it'"'"'s a \"quoted\" $value with spaces"' >> "$A/config/configure_rstudio.vars.conf"
sed -i 's|^NEXTCLOUD_TARGET_URL=.*|NEXTCLOUD_TARGET_URL="https://10.0.0.5"|' "$A/config/install_secure_access.vars.conf"
# setup_nodes already has a site file (mail keys) — must be kept
mkdir -p "$A/config/site"
printf 'SMTP_HOST="smtp.real.example"\n' > "$A/config/site/setup_nodes.site.vars.conf"
sed -i 's|^NFS_HOME=.*|NFS_HOME="/nfs/home2"|' "$A/config/setup_nodes.vars.conf"
# script edits: one differs from upstream, one equals upstream ref
echo 'echo local hotfix' >> "$A/scripts/tools/hw_report.sh"
echo 'untracked' > "$A/rstudio_download_page.html"
# the same change the "upstream" ref (made below, before any local edit) has
echo 'echo upstream fix' >> "$A/scripts/tools/deployment_summary.sh"

declare -A BEFORE
for f in configure_rstudio.vars.conf setup_nodes.vars.conf install_secure_access.vars.conf; do
  BEFORE[$f]="$(eff "$A" "$f")"
done
SITE_SMTP_BEFORE="$(sha256sum < "$A/config/site/setup_nodes.site.vars.conf")"

export FIX_SITE_OVERLAY_BACKUP_ROOT="$T/backups"
run() {  # REPO ARGS... -> sets OUT, RC
  set +e
  OUT="$(FIX_SITE_OVERLAY_REPO="$1" bash "$SUT" "${@:2}" 2>&1)"; RC=$?
  set -e
}

# --- dry-run changes nothing ---------------------------------------------------
h0="$(treehash "$A")"
run "$A" --upstream-ref upstream
check "dry-run: exit 0" 0 "$RC"
check "dry-run: tree untouched" "$h0" "$(treehash "$A")"
contains "dry-run: lists key to move" "RSESSION_TIMEOUT_MINUTES" "$OUT"
contains "dry-run: lists new local key" "EXTRA_LOCAL_KEY" "$OUT"
contains "dry-run: reports script edit for review" "scripts/tools/hw_report.sh" "$OUT"
contains "dry-run: recognises script edit already upstream" "deployment_summary.sh" "$OUT"
contains "dry-run: reports untracked file" "rstudio_download_page.html" "$OUT"
contains "dry-run: reports comment-only change kept in backup" "comment" "$OUT"
[[ ! -d "$T/backups" ]] && pass "dry-run: no backup written" || fail "dry-run: no backup written"

# --- snapshot: read-only effective-config dump, for before/after on a host ---
h_snap="$(treehash "$A")"
run "$A" --snapshot "$T/snap.before"
check "snapshot: exit 0" 0 "$RC"
check "snapshot: tree untouched" "$h_snap" "$(treehash "$A")"
contains "snapshot: has the host value" 'configure_rstudio.vars.conf: declare -- RSESSION_TIMEOUT_MINUTES="10080"' "$(cat "$T/snap.before" 2>/dev/null)"
lacks "snapshot: no absolute checkout path" "$A/config" "$(cat "$T/snap.before" 2>/dev/null)"

# --- commit -------------------------------------------------------------------
run "$A" --commit --upstream-ref upstream
check "commit: exit 0" 0 "$RC"
for f in configure_rstudio.vars.conf setup_nodes.vars.conf install_secure_access.vars.conf; do
  if G diff --quiet HEAD -- "config/$f"; then pass "commit: $f restored to upstream"; else fail "commit: $f restored to upstream"; fi
  check "commit: effective config of $f unchanged" "${BEFORE[$f]}" "$(eff "$A" "$f")"
done
check "commit: pin_r_version untouched" "4.6.0" "$(grep -o '4.6.0' "$A/config/pin_r_version.vars.conf")"
contains "commit: existing site keys kept" 'SMTP_HOST="smtp.real.example"' "$(cat "$A/config/site/setup_nodes.site.vars.conf")"
contains "commit: new site key appended" 'NFS_HOME="/nfs/home2"' "$(cat "$A/config/site/setup_nodes.site.vars.conf")"
contains "commit: literal derived-able line kept" 'R_PROJECTS_ROOT="/srv/projects"' "$(cat "$A/config/site/configure_rstudio.site.vars.conf")"
lacks "commit: path-derived variable is not frozen into the site file" "_CONF_DIR" \
  "$(cat "$A/config/site/install_secure_access.site.vars.conf")"
lacks "commit: no scratch path leaks into any site file" "/tmp" "$(cat "$A"/config/site/*)"
check "commit: site file mode 600" 600 "$(stat -c '%a' "$A/config/site/configure_rstudio.site.vars.conf")"
check "commit: script edit left in place" "echo local hotfix" "$(tail -1 "$A/scripts/tools/hw_report.sh")"
[[ -f "$A/rstudio_download_page.html" ]] && pass "commit: untracked file left in place" || fail "commit: untracked file left in place"
BK="$(find "$T/backups" -mindepth 1 -maxdepth 1 -type d -name 'config-site-overlay-*' | head -1)"
[[ -n "$BK" && -f "$BK/MANIFEST" ]] && pass "commit: backup + MANIFEST written" || fail "commit: backup + MANIFEST written"
[[ -f "$BK/review/scripts/tools/hw_report.sh.patch" ]] && pass "commit: script patch saved for review" || fail "commit: script patch saved for review"
contains "commit: says pull is still blocked by script edits" "still" "$OUT"
run "$A" --snapshot "$T/snap.after"
if cmp -s "$T/snap.before" "$T/snap.after"; then
  pass "snapshot: identical before and after the migration"
else
  fail "snapshot: identical before and after the migration ($(diff "$T/snap.before" "$T/snap.after" 2>&1 | head -5))"
fi

# --- idempotent ---------------------------------------------------------------
h1="$(treehash "$A")"
run "$A" --commit --upstream-ref upstream
check "second commit: exit 0" 0 "$RC"
contains "second commit: nothing to migrate" "nothing to migrate" "$OUT"
check "second commit: tree unchanged" "$h1" "$(treehash "$A")"

# --- rollback -----------------------------------------------------------------
run "$A" --rollback "$BK"
check "rollback: exit 0" 0 "$RC"
check "rollback: tree back to pre-migration state" "$h0" "$(treehash "$A")"
check "rollback: pre-existing site file restored byte for byte" "$SITE_SMTP_BEFORE" "$(sha256sum < "$A/config/site/setup_nodes.site.vars.conf")"
[[ ! -e "$A/config/site/configure_rstudio.site.vars.conf" ]] && pass "rollback: created site file removed" || fail "rollback: created site file removed"

# --- rollback refuses when HEAD moved -------------------------------------------
run "$A" --commit --upstream-ref upstream
BK2="$(find "$T/backups" -mindepth 1 -maxdepth 1 -type d -name 'config-site-overlay-*' -newer "$BK/MANIFEST" | head -1)"
G -c user.email=t@t -c user.name=t commit -q --allow-empty -m "pulled"
run "$A" --rollback "$BK2"
check "rollback after HEAD moved: refused" 1 "$RC"
run "$A" --rollback "$BK2" --force
check "rollback after HEAD moved: --force allowed" 0 "$RC"

# ════════════════════════════════════════════════════════════════════════════
# 3. Refusals: nothing is written when a change cannot be carried over safely
# ════════════════════════════════════════════════════════════════════════════
new_repo "$T/hostB"; B="$T/hostB"
sed -i 's/^RPROFILE_VERSION=.*/RPROFILE_VERSION="12.10"/' "$B/config/setup_nodes.vars.conf"
sed -i 's|^RSERVER_WWW_PORT=.*|RSERVER_WWW_PORT="8788"|' "$B/config/configure_rstudio.vars.conf"
hB="$(treehash "$B")"
run "$B" --commit
check "protected key edited locally: commit refused" 1 "$RC"
contains "protected key edited locally: named" "RPROFILE_VERSION" "$OUT"
check "protected key refusal: tree untouched (all or nothing)" "$hB" "$(treehash "$B")"
run "$B" --commit --drop-key RPROFILE_VERSION
check "protected key with --drop-key: commit ok" 0 "$RC"
check "protected key with --drop-key: upstream value now effective" '12.11' \
  "$(site_overlay_get "$B/config/setup_nodes.vars.conf" RPROFILE_VERSION 2>/dev/null)"
check "protected key with --drop-key: other key still migrated" '8788' \
  "$(site_overlay_get "$B/config/configure_rstudio.vars.conf" RSERVER_WWW_PORT 2>/dev/null)"
BKB="$(grep -l "# repo: $B\$" "$T"/backups/config-site-overlay-*/MANIFEST 2>/dev/null | head -1 || true)"
[[ -n "$BKB" ]] && contains "dropped value kept in backup" 'RPROFILE_VERSION="12.10"' "$(cat "$(dirname "$BKB")/files/config/setup_nodes.vars.conf")" \
  || fail "dropped value kept in backup (no backup found)"

new_repo "$T/hostC"; C="$T/hostC"
sed -i '/^OLD_KEY=/d' "$C/config/setup_nodes.vars.conf"
hC="$(treehash "$C")"
run "$C" --commit
check "key deleted locally: commit refused" 1 "$RC"
contains "key deleted locally: named" "OLD_KEY" "$OUT"
check "key deleted locally: tree untouched" "$hC" "$(treehash "$C")"

# --- post-write verification failure rolls back automatically ------------------
new_repo "$T/hostD"; D="$T/hostD"
sed -i 's|^RSERVER_WWW_PORT=.*|RSERVER_WWW_PORT="9999"|' "$D/config/configure_rstudio.vars.conf"
hD="$(treehash "$D")"
set +e
OUT="$(FIX_SITE_OVERLAY_TEST_FAULT=post_write FIX_SITE_OVERLAY_REPO="$D" bash "$SUT" --commit 2>&1)"; RC=$?
set -e
check "fault after write: exit 1" 1 "$RC"
contains "fault after write: automatic rollback announced" "rolled back" "$OUT"
check "fault after write: tree restored" "$hD" "$(treehash "$D")"

# --- clean checkout: nothing to do ---------------------------------------------
new_repo "$T/hostE"
run "$T/hostE" --commit
check "clean checkout: exit 0" 0 "$RC"
contains "clean checkout: nothing to migrate" "nothing to migrate" "$OUT"

# ════════════════════════════════════════════════════════════════════════════
# 4. Every T1 reader of the four host-edited files goes through the overlay
# ════════════════════════════════════════════════════════════════════════════
readers=(
  scripts/20_configure_rstudio.sh scripts/30_install_nginx.sh scripts/update_nginx_templates.sh
  scripts/32_setup_letsencrypt.sh scripts/03_install_secure_access.sh scripts/50_setup_nodes.sh
  scripts/99_audit_r_environment.sh scripts/99_check_pkg_drift.sh scripts/99_check_rprofile_health.sh
  scripts/fix_login_script_rlibs_inplace.sh scripts/99_check_user_renviron_overrides.sh
)
for r in "${readers[@]}"; do
  if grep -q 'site_overlay_' "${ROOT}/$r"; then pass "reader uses overlay: $r"; else fail "reader uses overlay: $r"; fi
done
if grep -q 'site_overlay_render' "${ROOT}/scripts/50_setup_nodes.sh"; then
  pass "50_setup_nodes deploys setup_nodes.vars.conf with its overlay"
else
  fail "50_setup_nodes deploys setup_nodes.vars.conf with its overlay"
fi
if grep -q 'site_overlay.sh' "${ROOT}/lib/common_utils.sh"; then
  pass "common_utils.sh loads site_overlay.sh"
else
  fail "common_utils.sh loads site_overlay.sh"
fi

echo
if ((FAILS)); then echo "${FAILS} failure(s)"; exit 1; fi
echo "all passed"
