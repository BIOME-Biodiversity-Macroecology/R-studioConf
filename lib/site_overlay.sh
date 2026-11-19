# lib/site_overlay.sh
# shellcheck shell=bash
#
# Site overlay for committed config files (ADR-0011, config/SITE_OVERRIDE.md).
#
# Every committed config/<name>.vars.conf may have a gitignored companion
#   config/site/<name>.site.vars.conf
# holding THIS host's values. It is sourced after the committed file, so its
# assignments win, and the committed file stays byte-identical to upstream:
# `git pull --ff-only` is never blocked by host values again.
#
# Rule 19 (single source of truth for R/RStudio/Rprofile versions) is enforced
# here, not only documented: keys in SITE_OVERLAY_PROTECTED_KEYS keep their
# committed value even if a site file sets them (warned, never silent), and the
# files in SITE_OVERLAY_EXCLUDED_CONFS never take an overlay at all.
#
# No dependencies: sourced by lib/common_utils.sh and directly by the few
# scripts that do not load common_utils.sh. Safe to source more than once.
#
# API
#   site_overlay_path   CONF            -> prints the overlay path (rc 1 if CONF has none)
#   site_overlay_source CONF            -> sources CONF, then its overlay (global scope)
#   site_overlay_get    CONF KEY        -> prints KEY's effective value (subshell; nothing leaks)
#   site_overlay_render CONF DEST       -> writes CONF + overlay to DEST (atomic) for
#                                          deployed copies read by other programs

SITE_OVERLAY_PROTECTED_KEYS="${SITE_OVERLAY_PROTECTED_KEYS:-RPROFILE_VERSION DEFAULT_R_VERSION R_CORE_PACKAGES}"
SITE_OVERLAY_EXCLUDED_CONFS="${SITE_OVERLAY_EXCLUDED_CONFS:-pin_r_version.vars.conf}"

_site_overlay_warn() {
    if declare -F log >/dev/null 2>&1; then
        log "WARN" "$*" >&2
    else
        printf '[WARN] %s\n' "$*" >&2
    fi
}

_site_overlay_is_protected() {  # KEY
    [[ " ${SITE_OVERLAY_PROTECTED_KEYS} " == *" $1 "* ]]
}

site_overlay_path() {  # CONF
    local conf="$1" dir base
    base="${conf##*/}"
    [[ "$base" == *.vars.conf && "$base" != *.site.vars.conf ]] || return 1
    [[ " ${SITE_OVERLAY_EXCLUDED_CONFS} " == *" ${base} "* ]] && return 1
    dir="$(cd "$(dirname "$conf")" 2>/dev/null && pwd)" || return 1
    printf '%s/site/%s.site.vars.conf\n' "$dir" "${base%.vars.conf}"
}

# Sources CONF and then its overlay. Plain assignments in both files land in
# the global scope even when called from inside a function. Protected keys are
# restored to the committed value after the overlay (with a warning).
site_overlay_source() {  # CONF
    local __so_conf="$1" __so_site __so_k
    # shellcheck source=/dev/null
    source "$__so_conf" || return 1
    __so_site="$(site_overlay_path "$__so_conf")" || return 0
    [[ -f "$__so_site" ]] || return 0

    local -A __so_saved=()
    local -A __so_isset=()
    for __so_k in ${SITE_OVERLAY_PROTECTED_KEYS}; do
        if [[ -n "${!__so_k+x}" ]]; then
            __so_isset[$__so_k]=1
            __so_saved[$__so_k]="${!__so_k}"
        fi
    done

    # shellcheck source=/dev/null
    source "$__so_site" || return 1

    for __so_k in ${SITE_OVERLAY_PROTECTED_KEYS}; do
        if [[ -n "${__so_isset[$__so_k]:-}" ]]; then
            if [[ "${!__so_k-}" != "${__so_saved[$__so_k]}" ]]; then
                _site_overlay_warn "Ignoring ${__so_k} from ${__so_site}: it is a single-source-of-truth key, kept at '${__so_saved[$__so_k]}' from ${__so_conf}."
                printf -v "$__so_k" '%s' "${__so_saved[$__so_k]}"
            fi
        elif [[ -n "${!__so_k+x}" ]]; then
            _site_overlay_warn "Ignoring ${__so_k} from ${__so_site}: single-source-of-truth key, not set in ${__so_conf}."
            unset "$__so_k"
        fi
    done
    return 0
}

# Prints KEY's effective value (committed file + overlay). Runs in a subshell
# with `set +eu`, so a config that references an unset variable cannot abort
# the caller and nothing it defines leaks into the caller.
site_overlay_get() {  # CONF KEY
    local conf="$1" key="$2"
    [[ -f "$conf" ]] || return 0
    (
        set +eu
        site_overlay_source "$conf" >/dev/null || exit 0
        printf '%s' "${!key-}"
    )
}

# Writes the committed CONF followed by its overlay to DEST, so programs that
# read the deployed copy (sourced by templates, parsed line by line by
# telemetry_api.py, last assignment wins) see the same values the deploy
# scripts saw. Protected-key lines are dropped from the overlay part.
# Atomic (temp file in DEST's directory, then mv). Idempotent.
site_overlay_render() {  # CONF DEST
    local conf="$1" dest="$2" site tmp pat k
    [[ -f "$conf" ]] || { _site_overlay_warn "site_overlay_render: missing ${conf}"; return 1; }
    tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX")" || return 1
    {
        cat "$conf"
        site="$(site_overlay_path "$conf")" || site=""
        if [[ -n "$site" && -f "$site" ]]; then
            pat=""
            for k in ${SITE_OVERLAY_PROTECTED_KEYS}; do pat+="${pat:+|}${k}"; done
            printf '\n# ---- site overlay (config/site/%s), host-local values: last assignment wins ----\n' "${site##*/}"
            if grep -qE "^[[:space:]]*(export[[:space:]]+)?(${pat})=" "$site"; then
                _site_overlay_warn "site_overlay_render: dropping single-source-of-truth keys (${pat//|/ }) from ${site}."
            fi
            grep -vE "^[[:space:]]*(export[[:space:]]+)?(${pat})=" "$site" || true
        fi
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dest"
}
