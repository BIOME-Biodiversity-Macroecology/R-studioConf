#!/usr/bin/env bash
set -euo pipefail
# scripts/fix_config_site_overlay_inplace.sh
#
# IN-PLACE MIGRATION (ADR-0011): move this host's values out of locally
# modified TRACKED config files into the gitignored site overlay
#   config/<name>.vars.conf  ->  config/site/<name>.site.vars.conf
# and restore the tracked files to the commit the checkout is on (HEAD).
#
# Why: on calc01-04 the checkout /home/ladmin/configServices/R-studioConf has
#   host values edited straight into tracked files (configure_rstudio,
#   install_nginx, install_secure_access, setup_nodes .vars.conf). Every
#   upstream change to those files then blocks `git pull --ff-only`
#   (calc02 on 2026-11-19: 9 commits behind because of PRs #65-#68).
#   Since ADR-0011 every reader sources config/site/<name>.site.vars.conf
#   after the committed file (lib/site_overlay.sh), so the values can live
#   there and the tracked files can stay identical to upstream.
#
# What it changes (nothing else, no service restart, no git commit/pull):
#   * WRITE config/site/<name>.site.vars.conf: an existing file is kept and a
#           marked block is appended; a new file is created with mode 600.
#   * RESTORE config/<name>.vars.conf to its content at HEAD (owner/mode kept).
#   Other modified tracked files (scripts/tools/*.sh, ...) and untracked files
#   are REPORTED, never changed: their diff is saved under review/ in the
#   backup, with a note when the same change is already in --upstream-ref.
#   config/pin_r_version.vars.conf is reported too: it is the single source of
#   truth for the R version (rule 19) and never takes a site overlay.
#
# Safety:
#   * dry-run by default; --commit applies; --rollback DIR restores.
#   * the invariant is checked, not assumed: for every migrated file the
#     effective configuration (every variable after sourcing the committed
#     file and then the overlay) must be identical before and after. It is
#     checked on a scratch copy before any write, and again on the real
#     checkout after the write; a failure there rolls back automatically.
#   * all or nothing: if any file cannot be carried over exactly (a key
#     deleted locally, a single-source-of-truth key edited locally) nothing
#     is written. --drop-key KEY accepts the upstream value for that key
#     instead (the local file stays in the backup).
#   * backup + MANIFEST in ${BACKUP_ROOT}/config-site-overlay-<ts>/ BEFORE any
#     write; files are written to a temp name in their directory, then mv.
#   * one run at a time (flock on .git/biome-site-overlay.lock); refuses
#     during a merge/rebase/cherry-pick.
#
# Measure (baseline before --commit, value after):
#   git -C <checkout> status --porcelain | wc -l      # modified + untracked
#   git -C <checkout> diff --name-only HEAD -- config/ # tracked config edits (target: 0)
#   git -C <checkout> pull --ff-only --dry-run        # needs a fetch first
#   The script prints the same counts before and after.
#
# Usage:
#   bash scripts/fix_config_site_overlay_inplace.sh                 # dry-run
#   sudo bash scripts/fix_config_site_overlay_inplace.sh --commit
#   sudo bash scripts/fix_config_site_overlay_inplace.sh --rollback DIR [--force]
#   Options: --drop-key KEY        accept upstream for KEY (repeatable)
#            --upstream-ref REF    ref to compare other edits with (default origin/main)
#            --force               rollback even if HEAD moved since the backup
#            -h|--help
#   Env:     FIX_SITE_OVERLAY_REPO        (default: this checkout)
#            FIX_SITE_OVERLAY_BACKUP_ROOT (default /var/backups/biome-calc)
#
# Exit codes:
#   0 migrated, nothing to migrate, dry-run or rolled back
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
OVERLAY_LIB="${WORKSPACE_ROOT}/lib/site_overlay.sh"
[[ -f "$OVERLAY_LIB" ]] || { log_error "Missing ${OVERLAY_LIB}"; exit 1; }
# shellcheck source=../lib/site_overlay.sh disable=SC1091
source "$OVERLAY_LIB"

REPO="${FIX_SITE_OVERLAY_REPO:-${WORKSPACE_ROOT}}"
BACKUP_ROOT="${FIX_SITE_OVERLAY_BACKUP_ROOT:-/var/backups/biome-calc}"

usage() { sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'; }

MODE="dry-run"
ROLLBACK_DIR=""
FORCE=false
UPSTREAM_REF=""
DROP_KEYS=()
while (($#)); do
  case "$1" in
    --commit)       MODE="commit" ;;
    --rollback)     MODE="rollback"; ROLLBACK_DIR="${2:-}"; shift || true ;;
    --force)        FORCE=true ;;
    --drop-key)     [[ -n "${2:-}" ]] || { log_error "--drop-key needs a KEY"; exit 2; }
                    DROP_KEYS+=("$2"); shift ;;
    --upstream-ref) [[ -n "${2:-}" ]] || { log_error "--upstream-ref needs a REF"; exit 2; }
                    UPSTREAM_REF="$2"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

for bin in git awk grep sed diff cmp sha256sum mktemp cp mv flock date stat; do
  command -v "$bin" >/dev/null 2>&1 || { log_error "Missing required binary: $bin"; exit 1; }
done

# Root may run this on a checkout owned by ladmin: tell git it is fine.
g() { git -c safe.directory="$REPO" -C "$REPO" "$@"; }
is_root() { [[ "$(id -u)" -eq 0 ]]; }
is_dropped() { local k; for k in "${DROP_KEYS[@]}"; do [[ "$k" == "$1" ]] && return 0; done; return 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK:?}"; }
trap cleanup EXIT

# Writes SRC over DST atomically, keeping DST's owner and mode when it exists.
install_atomic() {  # SRC DST [MODE-if-new]
  local src="$1" dst="$2" mode="${3:-600}" tmp
  tmp="$(mktemp "$(dirname "$dst")/.$(basename "$dst").XXXXXX")"
  cat "$src" > "$tmp"
  if [[ -e "$dst" ]]; then
    chmod --reference="$dst" "$tmp"
    if is_root; then chown --reference="$dst" "$tmp"; fi
  else
    chmod "$mode" "$tmp"
    if is_root; then chown --reference="$(dirname "$dst")" "$tmp"; fi
  fi
  mv -f "$tmp" "$dst"
}

# ── Rollback ────────────────────────────────────────────────────────────────
# MANIFEST: "# key: value" header, then "F <relpath>" (saved under files/) or
# "N <relpath>" (did not exist before: removed on rollback).
do_rollback() {  # DIR
  local dir="$1" tag rel
  [[ -n "$dir" && -f "${dir}/MANIFEST" ]] || { log_error "No MANIFEST in '${dir}'"; return 1; }
  while read -r tag rel; do
    case "$tag" in
      F) install_atomic "${dir}/files/${rel}" "${REPO}/${rel}"; log_ok "Restored ${rel}" ;;
      N) rm -f "${REPO}/${rel}"; log_ok "Removed ${rel} (did not exist before)" ;;
      *) : ;;
    esac
  done < "${dir}/MANIFEST"
}

g rev-parse --is-inside-work-tree >/dev/null 2>&1 || { log_error "Not a git checkout: ${REPO}"; exit 1; }
GIT_DIR_ABS="$(g rev-parse --absolute-git-dir)"
exec 9>"${GIT_DIR_ABS}/biome-site-overlay.lock"
flock -n 9 || { log_error "Another run holds ${GIT_DIR_ABS}/biome-site-overlay.lock"; exit 1; }
HEAD_SHA="$(g rev-parse HEAD)"

if [[ "$MODE" == "rollback" ]]; then
  [[ -f "${ROLLBACK_DIR}/MANIFEST" ]] || { log_error "No MANIFEST in '${ROLLBACK_DIR}'"; exit 1; }
  bk_head="$(awk -F': ' '/^# head: /{print $2; exit}' "${ROLLBACK_DIR}/MANIFEST")"
  if [[ "$bk_head" != "$HEAD_SHA" && "$FORCE" != true ]]; then
    log_error "HEAD moved since the backup (${bk_head:0:12} -> ${HEAD_SHA:0:12}): the restored files would"
    log_error "be local edits against a newer commit. Re-run with --force if that is what you want."
    exit 1
  fi
  do_rollback "$ROLLBACK_DIR" || exit 1
  log_ok "Rollback complete (${ROLLBACK_DIR})"
  exit 0
fi

for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
  [[ -e "${GIT_DIR_ABS}/${marker}" ]] && { log_error "Git operation in progress (${marker}); finish or abort it first."; exit 1; }
done

if [[ -z "$UPSTREAM_REF" ]] && g rev-parse -q --verify 'origin/main^{commit}' >/dev/null; then
  UPSTREAM_REF="origin/main"
fi
if [[ -n "$UPSTREAM_REF" ]] && ! g rev-parse -q --verify "${UPSTREAM_REF}^{commit}" >/dev/null; then
  log_error "Unknown --upstream-ref ${UPSTREAM_REF}"; exit 2
fi

# ── Inventory ───────────────────────────────────────────────────────────────
MIG=()      # config/*.vars.conf to migrate (basenames)
OTHER=()    # other modified tracked paths: report only
while IFS= read -r -d '' p; do
  base="${p##*/}"
  if [[ "$p" == config/*.vars.conf && "$p" != config/*/* && -f "${REPO}/${p}" ]] \
     && site_overlay_path "${REPO}/${p}" >/dev/null; then
    MIG+=("$base")
  else
    OTHER+=("$p")
  fi
done < <(g diff -z --name-only HEAD)
mapfile -t UNTRACKED < <(g ls-files --others --exclude-standard)
DIRTY_BEFORE=$(( ${#MIG[@]} + ${#OTHER[@]} ))

log_head "Checkout ${REPO} at ${HEAD_SHA:0:12}${UPSTREAM_REF:+ (compared with ${UPSTREAM_REF})}"
log_info "Baseline: ${DIRTY_BEFORE} modified tracked file(s) (${#MIG[@]} config to migrate, ${#OTHER[@]} for review), ${#UNTRACKED[@]} untracked"

# ── Effective configuration ─────────────────────────────────────────────────
# state DIR NAME OUT: sources DIR/NAME + overlay in a clean bash and writes one
# file per variable (its `declare -p`) into OUT. Two states are equal when the
# directories are equal.
EVAL_SRC='
set +eu
source "$1"
declare -A __pre=()
for __v in $(compgen -v); do __pre[$__v]="$(declare -p "$__v" 2>/dev/null)"; done
__phys="$(cd "$2" && pwd -P)"
site_overlay_source "$2/$3" >/dev/null 2>&1 || exit 3
mkdir -p "$4"
for __v in $(compgen -v); do
  case "$__v" in __pre|__v|__d|__phys|BASH*|_|PIPESTATUS|FUNCNAME|LINENO|RANDOM|SRANDOM|SECONDS|EPOCH*|COLUMNS|LINES|OLDPWD|PWD|SHLVL|SITE_OVERLAY_*) continue ;; esac
  __d="$(declare -p "$__v" 2>/dev/null)" || continue
  [[ "${__pre[$__v]-}" == "$__d" ]] && continue
  # A value derived from the file location (_CONF_DIR="$(cd "$(dirname
  # "${BASH_SOURCE[0]}")" && pwd)") is not a host value: compare it relative to
  # the evaluated directory, so scratch copies and the checkout compare equal.
  __d="${__d//"$__phys"/@CONFDIR@}"; __d="${__d//"$2"/@CONFDIR@}"
  printf "%s\n" "$__d" > "$4/$__v"
done
'
state() {  # DIR NAME OUT
  rm -rf "$3"
  env -i PATH="$PATH" HOME="${HOME:-/root}" bash --noprofile --norc -c "$EVAL_SRC" _ "$OVERLAY_LIB" "$1" "$2" "$3"
}
rhs() { local d; d="$(cat "$1")"; d="${d#declare * }"; printf '%s' "${d#*=}"; }
show() {  # KEY VALUE -> masked when the key looks secret
  if [[ "$1" =~ (PASS|SECRET|TOKEN) ]]; then printf '***'; else printf '%s' "$2"; fi
}
# value-form site line from a `declare -p` file
value_line() {
  local d flags assign
  d="$(cat "$1")"; d="${d#declare }"; flags="${d%% *}"; assign="${d#* }"
  case "$flags" in
    *A*) printf 'declare -gA %s\n' "$assign" ;;
    *a*) printf 'declare -ga %s\n' "$assign" ;;
    *x*) printf 'export %s\n' "$assign" ;;
    *)   printf '%s\n' "$assign" ;;
  esac
}
# states differ? (ignoring dropped keys)
states_differ() {  # A B
  local f k
  for f in "$1"/* "$2"/*; do
    [[ -e "$f" ]] || continue
    k="${f##*/}"; is_dropped "$k" && continue
    cmp -s "$1/$k" "$2/$k" 2>/dev/null || return 0
  done
  return 1
}

REFUSE=()
declare -A NEWSITE=()   # basename -> candidate site file in WORK
declare -A SITEREL=()   # basename -> site path relative to REPO
TS="$(date +%Y%m%d-%H%M%S)"

if ((${#MIG[@]})); then
  cp -a "${REPO}/config" "${WORK}/before"
  cp -a "${REPO}/config" "${WORK}/after"
  mkdir -p "${WORK}/after/site"
fi

for f in "${MIG[@]}"; do
  log_head "config/${f}"
  g show "HEAD:config/${f}" > "${WORK}/after/${f}"
  site_abs="$(site_overlay_path "${WORK}/after/${f}")"
  site_name="${site_abs##*/}"
  SITEREL[$f]="config/site/${site_name}"

  state "${WORK}/before" "$f" "${WORK}/s.local.${f}" || { REFUSE+=("${f}: cannot be sourced as it is on the host"); continue; }
  state "${WORK}/after"  "$f" "${WORK}/s.base.${f}"  || { REFUSE+=("${f}: upstream version cannot be sourced with the existing site file"); continue; }

  changed=(); removed=()
  for p in "${WORK}/s.local.${f}"/*; do
    [[ -e "$p" ]] || continue
    k="${p##*/}"
    cmp -s "$p" "${WORK}/s.base.${f}/${k}" 2>/dev/null || changed+=("$k")
  done
  for p in "${WORK}/s.base.${f}"/*; do
    [[ -e "$p" ]] || continue
    k="${p##*/}"
    [[ -e "${WORK}/s.local.${f}/${k}" ]] || removed+=("$k")
  done

  move=()
  for k in "${changed[@]}"; do
    old="(unset)"; [[ -e "${WORK}/s.base.${f}/${k}" ]] && old="$(rhs "${WORK}/s.base.${f}/${k}")"
    new="$(rhs "${WORK}/s.local.${f}/${k}")"
    if is_dropped "$k"; then
      log_warn "${k}: local $(show "$k" "$new") DROPPED (--drop-key), upstream $(show "$k" "$old") applies"
    elif _site_overlay_is_protected "$k"; then
      REFUSE+=("${f}: ${k} is a single-source-of-truth key (rule 19) edited locally (${new} vs upstream ${old}); change it upstream, or --drop-key ${k}")
    else
      log_info "${k}: $(show "$k" "$old") -> $(show "$k" "$new")"
      move+=("$k")
    fi
  done
  for k in "${removed[@]}"; do
    if is_dropped "$k"; then
      log_warn "${k}: deleted locally, DROPPED (--drop-key): upstream value applies"
    else
      REFUSE+=("${f}: ${k} was deleted locally; a site file cannot unset it safely. Use --drop-key ${k} to accept upstream")
    fi
  done

  # Non-assignment lines added on the host (comments, commands): not carried.
  added="$(diff --unchanged-line-format='' --old-line-format='' --new-line-format='%L' \
            "${WORK}/after/${f}" "${WORK}/before/${f}" || true)"
  n_other=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    k="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' <<<"$line")"
    # assignment lines of keys handled above (moved, dropped or refused)
    [[ -n "$k" && " ${changed[*]-} ${removed[*]-} " == *" $k "* ]] && continue
    n_other=$((n_other + 1))
  done <<<"$added"
  if ((n_other)); then
    log_warn "${n_other} other changed line(s) (comment or non-assignment): not carried over, kept in the backup"
  fi

  # Build the site block: the host's literal line where possible (keeps
  # "${OTHER}/x" expressions), else the exact value. Then prove equality.
  cand="${WORK}/cand.${f}"
  build_block() {  # literal|value
    local mode="$1" k ln lit
    local -a lines=() tail_lines=()
    for k in "${move[@]}"; do
      lit=""
      if [[ "$mode" == literal ]]; then
        ln="$(grep -nE "^[[:space:]]*(export[[:space:]]+)?${k}=" "${WORK}/before/${f}" | tail -1 || true)"
        if [[ -n "$ln" && "$ln" != *'\' && "$ln" != *"=("* ]]; then lit="$ln"; fi
      fi
      if [[ -n "$lit" ]]; then
        lines+=("${lit%%:*}:${lit#*:}")
      else
        tail_lines+=("$(value_line "${WORK}/s.local.${f}/${k}")")
      fi
    done
    {
      [[ -f "${REPO}/${SITEREL[$f]}" ]] && cat "${REPO}/${SITEREL[$f]}"
      printf '\n# ---- migrated from tracked config/%s (HEAD %s, %s) by fix_config_site_overlay_inplace.sh ----\n' \
        "$f" "${HEAD_SHA:0:12}" "$TS"
      if ((${#lines[@]})); then printf '%s\n' "${lines[@]}" | sort -t: -k1,1n | cut -d: -f2-; fi
      if ((${#tail_lines[@]})); then printf '%s\n' "${tail_lines[@]}"; fi
    } > "$cand"
  }

  if ((${#move[@]} == 0)); then
    log_info "No value to carry over: the file is only restored to upstream"
    continue
  fi
  ok=false
  for mode in literal value; do
    build_block "$mode"
    # a value that embeds the config path cannot be written as a literal
    grep -q '@CONFDIR@' "$cand" && continue
    cp "$cand" "${WORK}/after/site/${site_name}"
    state "${WORK}/after" "$f" "${WORK}/s.after.${f}" || continue
    if ! states_differ "${WORK}/s.local.${f}" "${WORK}/s.after.${f}"; then ok=true; break; fi
  done
  if [[ "$ok" == true ]]; then
    NEWSITE[$f]="$cand"
    log_ok "Effective configuration identical with ${SITEREL[$f]} (${#move[@]} key(s), checked on a scratch copy)"
  else
    REFUSE+=("${f}: could not reproduce the host's effective configuration from a site file")
  fi
done

# ── Report other edits ──────────────────────────────────────────────────────
if ((${#OTHER[@]} + ${#UNTRACKED[@]})); then
  log_head "Not changed by this script: review by hand"
  for p in "${OTHER[@]}"; do
    if [[ ! -e "${REPO}/${p}" ]]; then
      log_warn "${p}: deleted locally"
    elif [[ -n "$UPSTREAM_REF" ]] && [[ "$(g rev-parse -q --verify "${UPSTREAM_REF}:${p}" 2>/dev/null || true)" == "$(g hash-object -- "$p")" ]]; then
      log_info "${p}: same content as ${UPSTREAM_REF}: the fix is upstream, 'git checkout -- ${p}' is safe before the pull"
    elif [[ "$p" == config/pin_r_version.vars.conf ]]; then
      log_warn "${p}: R version single source of truth (rule 19), never overlaid: change it upstream"
    else
      log_warn "${p}: local edit not in ${UPSTREAM_REF:-upstream}: review (diff saved under review/ on --commit)"
    fi
  done
  for p in "${UNTRACKED[@]}"; do log_info "untracked: ${p}"; done
fi

if ((${#REFUSE[@]})); then
  log_head "Refused: nothing written"
  for r in "${REFUSE[@]}"; do log_error "$r"; done
  exit 1
fi

if ((${#MIG[@]} == 0)); then
  log_ok "Config: nothing to migrate (no locally modified config/*.vars.conf)"
  ((${#OTHER[@]})) && log_warn "git pull --ff-only is still blocked by ${#OTHER[@]} modified tracked file(s) listed above"
  exit 0
fi

if [[ "$MODE" == "dry-run" ]]; then
  log_head "DRY-RUN: nothing changed"
  log_info "Would migrate ${#MIG[@]} file(s); re-run with --commit to apply."
  exit 0
fi

# ── Commit ──────────────────────────────────────────────────────────────────
BK="${BACKUP_ROOT}/config-site-overlay-${TS}-$$"
( umask 077 && mkdir -p "${BK}/files/config/site" "${BK}/review" ) \
  || { log_error "Cannot create backup ${BK} (run with sudo, or set FIX_SITE_OVERLAY_BACKUP_ROOT)"; exit 1; }
{
  printf '# repo: %s\n# head: %s\n# created: %s\n' "$REPO" "$HEAD_SHA" "$TS"
  for f in "${MIG[@]}"; do
    cp -p "${REPO}/config/${f}" "${BK}/files/config/${f}"; printf 'F config/%s\n' "$f"
    rel="${SITEREL[$f]}"
    if [[ -f "${REPO}/${rel}" ]]; then
      cp -p "${REPO}/${rel}" "${BK}/files/${rel}"; printf 'F %s\n' "$rel"
    else
      printf 'N %s\n' "$rel"
    fi
  done
} > "${BK}/MANIFEST" || { log_error "Backup failed: nothing written"; exit 1; }
g diff HEAD > "${BK}/worktree.diff" || true
g status --porcelain > "${BK}/status.txt" || true
printf '%s\n' "${UNTRACKED[@]}" > "${BK}/untracked.txt"
for p in "${OTHER[@]}"; do
  mkdir -p "${BK}/review/$(dirname "$p")"
  g diff HEAD -- "$p" > "${BK}/review/${p}.patch" || true
done
log_ok "Backup: ${BK}"

if [[ ! -d "${REPO}/config/site" ]]; then
  mkdir -p "${REPO}/config/site"
  # created as root under sudo: give it the checkout's owner, like config/
  if is_root; then chown --reference="${REPO}/config" "${REPO}/config/site"; fi
  chmod 700 "${REPO}/config/site"
fi
for f in "${MIG[@]}"; do
  if [[ -n "${NEWSITE[$f]:-}" ]]; then
    install_atomic "${NEWSITE[$f]}" "${REPO}/${SITEREL[$f]}" 600
    log_ok "Wrote ${SITEREL[$f]}"
  fi
  install_atomic "${WORK}/after/${f}" "${REPO}/config/${f}"
  log_ok "Restored config/${f} to HEAD"
done

if [[ "${FIX_SITE_OVERLAY_TEST_FAULT:-}" == post_write ]]; then   # tests only
  for f in "${MIG[@]}"; do
    [[ -n "${NEWSITE[$f]:-}" ]] && { echo 'FIX_SITE_OVERLAY_INJECTED_FAULT=1' >> "${REPO}/${SITEREL[$f]}"; break; }
  done
fi

# Verify on the real checkout: same effective configuration, file at HEAD.
bad=()
for f in "${MIG[@]}"; do
  if ! state "${REPO}/config" "$f" "${WORK}/s.final.${f}" \
     || states_differ "${WORK}/s.local.${f}" "${WORK}/s.final.${f}" \
     || ! g diff --quiet HEAD -- "config/${f}"; then
    bad+=("$f")
  fi
done
if ((${#bad[@]})); then
  log_error "Verification failed after write for: ${bad[*]}"
  do_rollback "$BK" || { log_error "AUTOMATIC ROLLBACK FAILED: restore by hand from ${BK}"; exit 1; }
  log_error "All changes rolled back from ${BK}"
  exit 1
fi

log_head "Done"
remaining="$(g diff --name-only HEAD | wc -l)"
log_ok "Effective configuration verified identical for ${#MIG[@]} file(s)"
log_info "Modified tracked files: ${DIRTY_BEFORE} before, ${remaining} after"
if ((remaining)); then
  log_warn "git pull --ff-only is still blocked by ${remaining} modified tracked file(s) listed above (diffs in ${BK}/review/)"
else
  log_ok "Tracked files clean: git pull --ff-only can proceed"
fi
log_info "Rollback: sudo bash $0 --rollback ${BK}"
