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
#   * under sudo the host's config files are evaluated as the checkout owner
#     (runuser), never as root: they are bash, and whoever can edit them must
#     not gain root through this script. Their results are copied back as
#     plain files only.
#   * a file edited while the script runs is not overwritten: every target is
#     compared with the copy that was evaluated, before the backup and again
#     before each write; a failed or interrupted write rolls back what was
#     already written.
#   * rollback validates the backup first (MANIFEST paths limited to
#     config/<name>.vars.conf and config/site/<name>.site.vars.conf, backup
#     of this checkout, every saved file present) and refuses, without
#     touching anything, if a file was edited after the migration; --force
#     overrides that check and the HEAD check, never the path checks.
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
#   bash scripts/fix_config_site_overlay_inplace.sh --snapshot FILE  # read-only
#            effective configuration of every config/*.vars.conf (committed
#            file + overlay), one "file: declare -p" line per variable, sorted;
#            take one before and one after: `diff` must be empty.
#   Options: --drop-key KEY        accept upstream for KEY (repeatable)
#            --upstream-ref REF    ref to compare other edits with (default origin/main)
#            --force               rollback even if HEAD moved since the backup or a
#                                  migrated file was edited after the migration
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
SNAPSHOT_OUT=""
FORCE=false
UPSTREAM_REF=""
DROP_KEYS=()
while (($#)); do
  case "$1" in
    --commit)       MODE="commit" ;;
    --rollback)     MODE="rollback"; ROLLBACK_DIR="${2:-}"; shift || true ;;
    --snapshot)     [[ -n "${2:-}" ]] || { log_error "--snapshot needs an output FILE"; exit 2; }
                    MODE="snapshot"; SNAPSHOT_OUT="$2"; shift ;;
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

for bin in git awk grep sed diff cmp sha256sum mktemp cp mv flock date stat tar find; do
  command -v "$bin" >/dev/null 2>&1 || { log_error "Missing required binary: $bin"; exit 1; }
done
if [[ "$(id -u)" -eq 0 ]]; then
  command -v runuser >/dev/null 2>&1 || { log_error "Missing required binary: runuser"; exit 1; }
fi

# Root may run this on a checkout owned by ladmin: tell git it is fine.
g() { git -c safe.directory="$REPO" -C "$REPO" "$@"; }
is_root() { [[ "$(id -u)" -eq 0 ]]; }
is_dropped() { local k; for k in "${DROP_KEYS[@]}"; do [[ "$k" == "$1" ]] && return 0; done; return 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK:?}"; }
trap cleanup EXIT

fsha() {  # FILE -> sha256 of its content, "absent" when it does not exist
  if [[ -e "$1" || -L "$1" ]]; then sha256sum < "$1" | cut -d' ' -f1; else printf 'absent'; fi
}

# Writes SRC over DST atomically. Owner: DST's (or its directory's when new).
# Mode: MODE-REF's when given, else DST's, else MODE-if-new. Returns 1 on any
# failure (callers run it in conditionals, where set -e does not apply).
install_atomic() {  # SRC DST [MODE-if-new] [MODE-REF]
  local src="$1" dst="$2" mode="${3:-600}" ref="${4:-}" tmp
  [[ ! -L "$dst" ]] || { log_error "${dst} is a symlink: not written"; return 1; }
  tmp="$(mktemp "$(dirname "$dst")/.$(basename "$dst").XXXXXX")" || return 1
  if ! cat "$src" > "$tmp"; then rm -f "$tmp"; return 1; fi
  if [[ -n "$ref" ]]; then chmod --reference="$ref" "$tmp" || { rm -f "$tmp"; return 1; }
  elif [[ -e "$dst" ]]; then chmod --reference="$dst" "$tmp" || { rm -f "$tmp"; return 1; }
  else chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  if is_root; then
    if [[ -e "$dst" ]]; then chown --reference="$dst" "$tmp" || { rm -f "$tmp"; return 1; }
    else chown --reference="$(dirname "$dst")" "$tmp" || { rm -f "$tmp"; return 1; }
    fi
  fi
  mv -f "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}

# The only paths a MANIFEST may name: a top-level tracked config or its overlay.
valid_rel() {  # REL
  [[ "$1" =~ ^config/[A-Za-z0-9_][A-Za-z0-9_.-]*\.vars\.conf$ \
  || "$1" =~ ^config/site/[A-Za-z0-9_][A-Za-z0-9_.-]*\.site\.vars\.conf$ ]] && [[ "$1" != *..* ]]
}

# ── Rollback ────────────────────────────────────────────────────────────────
# MANIFEST: "# key: value" header, then "F <relpath>" (saved under files/),
# "N <relpath>" (did not exist before: removed on rollback), and after the
# write "A <sha256|absent> <relpath>" (content the migration left there).
# Everything is validated before the first file is touched; then each step is
# checked and the first failure stops the rollback with exit 1.
do_rollback() {  # DIR FORCE(true|false)
  local dir="$1" force="${2:-false}" tag a b rel bk_repo here there
  local -a errs=() edited=()
  [[ -n "$dir" && -f "${dir}/MANIFEST" ]] || { log_error "No MANIFEST in '${dir}'"; return 1; }
  bk_repo="$(awk -F': ' '/^# repo: /{print $2; exit}' "${dir}/MANIFEST")"
  here="$(cd "$REPO" && pwd -P)"
  there="$(cd "$bk_repo" 2>/dev/null && pwd -P || printf '%s' "$bk_repo")"
  if [[ -z "$bk_repo" || "$there" != "$here" ]]; then
    log_error "Backup ${dir} belongs to another checkout (${bk_repo:-none recorded}), not ${REPO}: nothing restored."
    return 1
  fi
  for d in "${REPO}/config" "${REPO}/config/site"; do
    [[ ! -L "$d" ]] || errs+=("${d} is a symlink")
  done
  while read -r tag a b; do
    case "$tag" in
      ''|'#'*) continue ;;
      F|N) rel="$a"; [[ -z "$b" ]] || { errs+=("bad line: ${tag} ${a} ${b}"); continue; } ;;
      A)   rel="$b"; [[ "$a" =~ ^([0-9a-f]{64}|absent)$ ]] || { errs+=("bad line: A ${a} ${b}"); continue; } ;;
      *)   errs+=("unknown MANIFEST line: ${tag} ${a} ${b}"); continue ;;
    esac
    if ! valid_rel "$rel"; then errs+=("path not allowed in a MANIFEST: ${rel}"); continue; fi
    if [[ "$tag" == F && ( ! -f "${dir}/files/${rel}" || -L "${dir}/files/${rel}" ) ]]; then
      errs+=("saved file missing from the backup: files/${rel}")
    fi
    if [[ -L "${REPO}/${rel}" ]]; then errs+=("${rel} is a symlink in the checkout"); fi
    if [[ "$tag" == A && "$(fsha "${REPO}/${rel}")" != "$a" ]]; then edited+=("$rel"); fi
  done < "${dir}/MANIFEST"
  if ((${#errs[@]})); then
    for a in "${errs[@]}"; do log_error "$a"; done
    log_error "Backup ${dir} is not valid: nothing restored."
    return 1
  fi
  if ((${#edited[@]})); then
    if [[ "$force" == true ]]; then
      log_warn "Edited after the migration, overwritten (--force): ${edited[*]}"
    else
      for a in "${edited[@]}"; do log_error "${a}: changed since the migration; restoring would lose that edit"; done
      log_error "Nothing restored. Save the edits, then re-run with --force."
      return 1
    fi
  fi
  while read -r tag a b; do
    case "$tag" in
      F) mkdir -p "$(dirname "${REPO}/${a}")" || return 1
         install_atomic "${dir}/files/${a}" "${REPO}/${a}" 600 "${dir}/files/${a}" \
           || { log_error "Could not restore ${a}: rollback incomplete"; return 1; }
         log_ok "Restored ${a}" ;;
      N) rm -f "${REPO}/${a}" || { log_error "Could not remove ${a}: rollback incomplete"; return 1; }
         log_ok "Removed ${a} (did not exist before)" ;;
      *) : ;;
    esac
  done < "${dir}/MANIFEST"
  return 0
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
  do_rollback "$ROLLBACK_DIR" "$FORCE" || exit 1
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
# Under sudo the files are bash written on the host: they are evaluated as the
# owner of the checkout's config/ in a scratch directory of that user, and only
# regular files come back (copied without following links, then checked).
EVAL_USER=""
if is_root; then
  EVAL_USER="$(stat -c %U "${REPO}/config" 2>/dev/null || true)"
  [[ "$EVAL_USER" == root || "$EVAL_USER" == UNKNOWN ]] && EVAL_USER=""
fi
state() {  # DIR NAME OUT
  local u rc=0
  rm -rf "$3"
  if [[ -z "$EVAL_USER" ]]; then
    env -i PATH="$PATH" HOME="${HOME:-/root}" bash --noprofile --norc -c "$EVAL_SRC" _ "$OVERLAY_LIB" "$1" "$2" "$3"
    return
  fi
  u="$(cd / && runuser -u "$EVAL_USER" -- mktemp -d)" || return 1
  (
    cd / || exit 1
    tar -C "$1" -cf - . | runuser -u "$EVAL_USER" -- tar -C "$u" --no-same-owner -xf - \
      && runuser -u "$EVAL_USER" -- tee "${u}/.site_overlay.sh" < "$OVERLAY_LIB" >/dev/null \
      && runuser -u "$EVAL_USER" -- env -i PATH="$PATH" HOME="$u" bash --noprofile --norc -c "$EVAL_SRC" \
           _ "${u}/.site_overlay.sh" "$u" "$2" "${u}/.out"
  ) || rc=$?
  if ((rc == 0)); then
    cp -rP "${u}/.out" "$3" || rc=1
    if ((rc == 0)) && [[ -n "$(find "$3" -mindepth 1 ! -type f -print -quit)" ]]; then
      log_error "Evaluation of ${2} returned something other than plain files: refused"; rc=1
    fi
  fi
  (cd / && runuser -u "$EVAL_USER" -- rm -rf "$u") || true
  return "$rc"
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

if [[ "$MODE" == "snapshot" ]]; then
  : > "$SNAPSHOT_OUT" || { log_error "Cannot write ${SNAPSHOT_OUT}"; exit 1; }
  n=0
  for c in "${REPO}"/config/*.vars.conf; do
    [[ -f "$c" ]] || continue
    name="${c##*/}"
    [[ "$name" == *.site.vars.conf ]] && continue
    if ! state "${REPO}/config" "$name" "${WORK}/snap.${name}"; then
      log_error "${name}: cannot be sourced"; exit 1
    fi
    for p in "${WORK}/snap.${name}"/*; do
      [[ -e "$p" ]] || continue
      while IFS= read -r line; do printf '%s: %s\n' "$name" "$line"; done < "$p"
    done >> "$SNAPSHOT_OUT"
    n=$((n + 1))
  done
  LC_ALL=C sort -o "$SNAPSHOT_OUT" "$SNAPSHOT_OUT"
  log_ok "Snapshot of ${n} config file(s), $(wc -l < "$SNAPSHOT_OUT") variable(s): ${SNAPSHOT_OUT}"
  exit 0
fi

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
# Every file this run writes, as "<rel> <copy evaluated in WORK/before>":
# the target must still have that content, else a concurrent edit would be lost.
TARGETS=()
for f in "${MIG[@]}"; do
  TARGETS+=("config/${f}")
  TARGETS+=("${SITEREL[$f]}")
done
expected_of() {  # REL -> path of the evaluated copy (may not exist)
  printf '%s/before/%s' "$WORK" "${1#config/}"
}
unchanged_since_eval() {  # REL
  [[ "$(fsha "${REPO}/${1}")" == "$(fsha "$(expected_of "$1")")" ]]
}

if [[ "${FIX_SITE_OVERLAY_TEST_FAULT:-}" == concurrent_edit ]]; then   # tests only
  echo 'CONCURRENT_EDIT="1"' >> "${REPO}/config/${MIG[0]}"
fi
moved=()
for rel in "${TARGETS[@]}"; do unchanged_since_eval "$rel" || moved+=("$rel"); done
if ((${#moved[@]})); then
  for rel in "${moved[@]}"; do log_error "${rel}: changed since this run read it (edited meanwhile?)"; done
  log_error "Nothing written: re-run the dry-run and then --commit."
  exit 1
fi

BK="${BACKUP_ROOT}/config-site-overlay-${TS}-$$"
( umask 077 && mkdir -p "${BK}/files/config/site" "${BK}/review" ) \
  || { log_error "Cannot create backup ${BK} (run with sudo, or set FIX_SITE_OVERLAY_BACKUP_ROOT)"; exit 1; }
backup_fail() { log_error "Backup failed (${1}): nothing written. Partial backup left in ${BK}"; exit 1; }
MANIFEST_LINES=()
for rel in "${TARGETS[@]}"; do
  if [[ -e "${REPO}/${rel}" ]]; then
    if [[ "${FIX_SITE_OVERLAY_TEST_FAULT:-}" == backup_copy ]]; then   # tests only
      backup_fail "cp ${rel}"
    fi
    cp -p "${REPO}/${rel}" "${BK}/files/${rel}" || backup_fail "cp ${rel}"
    cmp -s "${BK}/files/${rel}" "$(expected_of "$rel")" || backup_fail "${rel} differs from what was evaluated"
    MANIFEST_LINES+=("F ${rel}")
  else
    MANIFEST_LINES+=("N ${rel}")
  fi
done
{
  printf '# repo: %s\n# head: %s\n# created: %s\n' "$REPO" "$HEAD_SHA" "$TS"
  printf '%s\n' "${MANIFEST_LINES[@]}"
} > "${BK}/MANIFEST" || backup_fail "MANIFEST"
g diff HEAD > "${BK}/worktree.diff" || backup_fail "worktree.diff"
g status --porcelain > "${BK}/status.txt" || backup_fail "status.txt"
printf '%s\n' "${UNTRACKED[@]}" > "${BK}/untracked.txt" || backup_fail "untracked.txt"
for p in "${OTHER[@]}"; do
  mkdir -p "${BK}/review/$(dirname "$p")" || backup_fail "review/"
  g diff HEAD -- "$p" > "${BK}/review/${p}.patch" || backup_fail "review/${p}.patch"
done
log_ok "Backup: ${BK}"

# exec bit as at HEAD (git tracks only that): a mode-only edit is restored too
head_exec_bit() {  # REL FILE
  local m
  m="$(g ls-tree HEAD -- "$1" | awk '{print $1}')"
  case "$m" in
    100755) chmod u+x "$2" ;;
    100644) chmod a-x "$2" ;;
    *) return 0 ;;
  esac
}
written() {  # REL: record what the migration left there (checked on rollback)
  printf 'A %s %s\n' "$(fsha "${REPO}/${1}")" "$1" >> "${BK}/MANIFEST"
}
write_all() {  # called in a conditional: every step checked by hand
  local f n=0
  if [[ ! -d "${REPO}/config/site" ]]; then
    mkdir -p "${REPO}/config/site" || return 1
    # created as root under sudo: give it the checkout's owner, like config/
    if is_root; then chown --reference="${REPO}/config" "${REPO}/config/site" || return 1; fi
    chmod 700 "${REPO}/config/site" || return 1
  fi
  for f in "${MIG[@]}"; do
    if [[ -n "${NEWSITE[$f]:-}" ]]; then
      unchanged_since_eval "${SITEREL[$f]}" || { log_error "${SITEREL[$f]}: changed since this run read it"; return 1; }
      install_atomic "${NEWSITE[$f]}" "${REPO}/${SITEREL[$f]}" 600 || { log_error "Could not write ${SITEREL[$f]}"; return 1; }
      written "${SITEREL[$f]}" || return 1
      log_ok "Wrote ${SITEREL[$f]}"
    fi
    n=$((n + 1))
    if [[ "${FIX_SITE_OVERLAY_TEST_FAULT:-}" == write_fail && $n -eq 2 ]]; then   # tests only
      log_error "Could not write config/${f} (injected fault)"; return 1
    fi
    unchanged_since_eval "config/${f}" || { log_error "config/${f}: changed since this run read it"; return 1; }
    install_atomic "${WORK}/after/${f}" "${REPO}/config/${f}" || { log_error "Could not restore config/${f}"; return 1; }
    head_exec_bit "config/${f}" "${REPO}/config/${f}" || { log_error "Could not set the mode of config/${f}"; return 1; }
    written "config/${f}" || return 1
    log_ok "Restored config/${f} to HEAD"
  done
}
abort_writes() {  # REASON
  trap - INT TERM HUP
  log_error "$1: rolling back what was written"
  do_rollback "$BK" true || { log_error "AUTOMATIC ROLLBACK FAILED: restore by hand from ${BK}"; exit 1; }
  log_error "All changes rolled back from ${BK}"
  exit 1
}
trap 'abort_writes "Interrupted"' INT TERM HUP
write_all || abort_writes "Write failed"
trap - INT TERM HUP

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
  abort_writes "Verification failed after write for: ${bad[*]}"
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
