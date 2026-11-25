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
# here, not only documented: the protected keys keep their committed value even
# if a site file sets them (warned, never silent), and the excluded files never
# take an overlay at all. Both lists are fixed in code (functions below), not
# read from the environment or from a variable a site file could reassign.
#
# No dependencies: sourced by lib/common_utils.sh and directly by the few
# scripts that do not load common_utils.sh. Safe to source more than once.
#
# API
#   site_overlay_path   CONF            -> prints the overlay path (rc 1 if CONF has none)
#   site_overlay_source CONF            -> sources CONF, then its overlay (global scope)
#   site_overlay_get    CONF KEY        -> prints KEY's effective value (subshell; nothing leaks);
#                                          rc 1 if CONF or its overlay cannot be sourced
#   site_overlay_render CONF DEST       -> writes CONF + the overlay's effective values to DEST
#                                          (atomic) for deployed copies read by other programs

_site_overlay_protected_keys() { printf '%s' "RPROFILE_VERSION DEFAULT_R_VERSION R_CORE_PACKAGES"; }
_site_overlay_excluded_confs() { printf '%s' "pin_r_version.vars.conf"; }
_SITE_OVERLAY_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

_site_overlay_warn() {
    if declare -F log >/dev/null 2>&1; then
        log "WARN" "$*" >&2
    else
        printf '[WARN] %s\n' "$*" >&2
    fi
}

_site_overlay_is_protected() {  # KEY
    [[ " $(_site_overlay_protected_keys) " == *" $1 "* ]]
}

site_overlay_path() {  # CONF
    local conf="$1" dir base
    base="${conf##*/}"
    [[ "$base" == *.vars.conf && "$base" != *.site.vars.conf ]] || return 1
    [[ " $(_site_overlay_excluded_confs) " == *" ${base} "* ]] && return 1
    dir="$(cd "$(dirname "$conf")" 2>/dev/null && pwd)" || return 1
    printf '%s/site/%s.site.vars.conf\n' "$dir" "${base%.vars.conf}"
}

# Sources CONF and then its overlay. Plain assignments in both files land in
# the global scope even when called from inside a function. Protected keys are
# restored to the committed value after the overlay (with a warning).
site_overlay_source() {  # CONF
    local __so_conf="$1" __so_site __so_k __so_keys
    # shellcheck source=/dev/null
    source "$__so_conf" || return 1
    __so_site="$(site_overlay_path "$__so_conf")" || return 0
    [[ -f "$__so_site" ]] || return 0

    # captured before the site file runs: it cannot change the list
    __so_keys="$(_site_overlay_protected_keys)"
    local -A __so_saved=()
    local -A __so_isset=()
    for __so_k in ${__so_keys}; do
        if [[ -n "${!__so_k+x}" ]]; then
            __so_isset[$__so_k]=1
            __so_saved[$__so_k]="${!__so_k}"
        fi
    done

    # shellcheck source=/dev/null
    source "$__so_site" || return 1

    for __so_k in ${__so_keys}; do
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
# with `set +eu`, so nothing CONF defines leaks into the caller. Exit 1 when
# CONF or its overlay cannot be sourced (syntax error, failing last command):
# a broken config is reported, never replaced by the caller's default.
# A missing CONF prints nothing and succeeds (callers keep their default).
site_overlay_get() {  # CONF KEY
    local conf="$1" key="$2"
    [[ -f "$conf" ]] || return 0
    (
        set +eu
        site_overlay_source "$conf" >/dev/null || exit 1
        printf '%s' "${!key-}"
    )
}

# NUL-separated "name\0declare -p\0" for every variable CONF defines, sourced in
# a clean bash (nothing from the caller's environment but PATH and HOME).
# WITH_OVERLAY=1 sources it through site_overlay_source.
_site_overlay_dump() {  # CONF WITH_OVERLAY
    env -i PATH="${PATH}" HOME="${HOME:-/root}" bash --noprofile --norc -c '
        set +eu
        source "$1" || exit 3
        declare -A __pre=()
        for __v in $(compgen -v); do __pre[$__v]="$(declare -p "$__v" 2>/dev/null)"; done
        if [[ "$3" == 1 ]]; then site_overlay_source "$2" || exit 3; else source "$2" || exit 3; fi
        for __v in $(compgen -v); do
            case "$__v" in __pre|__v|__d|BASH*|_|PIPESTATUS|FUNCNAME|LINENO|RANDOM|SRANDOM|SECONDS|EPOCH*|COLUMNS|LINES|OLDPWD|PWD|SHLVL|SITE_OVERLAY_*|_SITE_OVERLAY_*) continue ;; esac
            __d="$(declare -p "$__v" 2>/dev/null)" || continue
            [[ "${__pre[$__v]-}" == "$__d" ]] && continue
            printf "%s\0%s\0" "$__v" "$__d"
        done' _ "$_SITE_OVERLAY_LIB" "$1" "$2"
}

# Writes the committed CONF followed by the values its overlay changes, to
# DEST. The overlay part is not copied: it is evaluated (committed file, then
# overlay, through site_overlay_source) and every variable whose value differs
# from the committed file alone is written as a plain line:
#   KEY="value"           (+ "export KEY" when exported; arrays as declare -g)
# so programs that read the deployed copy see what the deploy scripts saw:
# templates that source it, and telemetry_api.py, which parses KEY=value lines
# (last one wins) without expanding ${...} or understanding `export`.
# Protected keys are restored by site_overlay_source, so they never appear.
# Atomic (temp file in DEST's directory, then mv). Idempotent.
site_overlay_render() {  # CONF DEST
    local conf="$1" dest="$2" site tmp name decl flags rhs
    [[ -f "$conf" ]] || { _site_overlay_warn "site_overlay_render: missing ${conf}"; return 1; }
    site="$(site_overlay_path "$conf")" || site=""
    local -A base=() eff=()
    if [[ -n "$site" && -f "$site" ]]; then
        while IFS= read -r -d '' name && IFS= read -r -d '' decl; do base[$name]="$decl"; done \
            < <(_site_overlay_dump "$conf" 0)
        while IFS= read -r -d '' name && IFS= read -r -d '' decl; do eff[$name]="$decl"; done \
            < <(_site_overlay_dump "$conf" 1)
        if ((${#eff[@]} == 0)); then
            _site_overlay_warn "site_overlay_render: ${conf} with ${site} cannot be sourced"; return 1
        fi
        for name in "${!base[@]}"; do
            [[ -n "${eff[$name]+x}" ]] || _site_overlay_warn "site_overlay_render: ${site} unsets ${name}: not carried to ${dest}"
        done
    fi
    tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX")" || return 1
    cat "$conf" > "$tmp" || { rm -f "$tmp"; return 1; }
    {
        if [[ -n "$site" && -f "$site" ]]; then
            printf '\n# ---- site overlay (config/site/%s): effective host values, last assignment wins ----\n' "${site##*/}"
            while IFS= read -r name; do
                [[ -n "$name" ]] || continue
                decl="${eff[$name]}"
                [[ "${base[$name]-}" == "$decl" ]] && continue
                flags="${decl#declare }"; flags="${flags%% *}"
                rhs="${decl#declare * }"; rhs="${rhs#*=}"
                case "$flags" in
                    *A*) printf 'declare -gA %s=%s\n' "$name" "$rhs" ;;
                    *a*) printf 'declare -ga %s=%s\n' "$name" "$rhs" ;;
                    *)   printf '%s=%s\n' "$name" "$rhs"
                         if [[ "$flags" == *x* ]]; then printf 'export %s\n' "$name"; fi ;;
                esac
            done < <(printf '%s\n' "${!eff[@]}" | LC_ALL=C sort)
        fi
    } >> "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dest"
}
