#!/usr/bin/env bash
# s&box Pterodactyl entrypoint (Wine runtime). Ported from HyberHost/gameforge-sbox-egg.
set -euo pipefail

CONTAINER_HOME="${CONTAINER_HOME:-/home/container}"
WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"
BAKED_WINEPREFIX="${SBOX_BAKED_WINEPREFIX:-/opt/sbox-wine-prefix}"
BAKED_SERVER_TEMPLATE="${SBOX_BAKED_SERVER_TEMPLATE:-/opt/sbox-server-template}"

SBOX_INSTALL_DIR="${SBOX_INSTALL_DIR:-/home/container/sbox}"
SBOX_SERVER_EXE="${SBOX_SERVER_EXE:-${SBOX_INSTALL_DIR}/sbox-server.exe}"
SBOX_APP_ID="${SBOX_APP_ID:-1892930}"
SBOX_AUTO_UPDATE="${SBOX_AUTO_UPDATE:-1}"
SBOX_BRANCH="${SBOX_BRANCH:-}"
SBOX_STEAMCMD_TIMEOUT="${SBOX_STEAMCMD_TIMEOUT:-600}"

GAME="${GAME:-}"
MAP="${MAP:-}"
SERVER_NAME="${SERVER_NAME:-}"
HOSTNAME_FALLBACK="${HOSTNAME:-}"
QUERY_PORT="${QUERY_PORT:-}"
MAX_PLAYERS="${MAX_PLAYERS:-}"
ENABLE_DIRECT_CONNECT="${ENABLE_DIRECT_CONNECT:-0}"
TOKEN="${TOKEN:-}"
SBOX_PROJECT="${SBOX_PROJECT:-}"
SBOX_PROJECTS_DIR="${SBOX_PROJECTS_DIR:-${CONTAINER_HOME}/projects}"
SBOX_EXTRA_ARGS="${SBOX_EXTRA_ARGS:-}"

LOG_DIR="${CONTAINER_HOME}/logs"
LOG_FILE="${LOG_DIR}/sbox-server.log"
ERROR_LOG="${LOG_DIR}/sbox-error.log"
UPDATE_LOG="${LOG_DIR}/sbox-update.log"
mkdir -p "${LOG_DIR}"

log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" | tee -a "${LOG_FILE}"; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" | tee -a "${LOG_FILE}" >&2; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "${ERROR_LOG}" >&2; }

# ─── Seed prebaked Wine prefix + s&box files on first boot ──────────────────
seed_runtime_files() {
    local seed_sbox=0
    local seed_reason=""
    local baked_server_exe="${BAKED_SERVER_TEMPLATE}/sbox-server.exe"

    if [ ! -d "${SBOX_INSTALL_DIR}" ]; then
        seed_sbox=1
        seed_reason="missing install directory"
    elif [ -z "$(find "${SBOX_INSTALL_DIR}" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        seed_sbox=1
        seed_reason="empty install directory"
    fi

    mkdir -p "${WINEPREFIX}"
    [ "${seed_sbox}" = "1" ] && mkdir -p "${SBOX_INSTALL_DIR}"

    if [ ! -f "${WINEPREFIX}/system.reg" ] && [ -d "${BAKED_WINEPREFIX}/drive_c" ]; then
        log_info "seeding Wine prefix from ${BAKED_WINEPREFIX}"
        cp -r "${BAKED_WINEPREFIX}/." "${WINEPREFIX}/"
    fi

    if [ "${seed_sbox}" = "1" ] && [ -f "${baked_server_exe}" ]; then
        log_info "seeding s&box files from ${BAKED_SERVER_TEMPLATE} (${seed_reason})"
        cp -r "${BAKED_SERVER_TEMPLATE}/." "${SBOX_INSTALL_DIR}/"
    elif [ "${seed_sbox}" = "1" ]; then
        log_warn "${SBOX_INSTALL_DIR} requires reseed (${seed_reason}) but prebaked template is missing ${baked_server_exe}"
    fi
}

# ─── Path helpers (project file is in /home/container/projects only) ────────
canonicalize_existing_path() {
    local input_path="$1"
    [ -n "${input_path}" ] && [ -e "${input_path}" ] || return 1
    local d b; d="$(dirname "${input_path}")"; b="$(basename "${input_path}")"
    ( cd "${d}" 2>/dev/null || exit 1; printf '%s/%s' "$(pwd -P)" "${b}" )
}
path_is_within_root() {
    case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac
}
resolve_project_target() {
    [ -z "${SBOX_PROJECT}" ] && { printf '%s' ""; return 0; }
    local projects_root candidate resolved
    projects_root="$(canonicalize_existing_path "${SBOX_PROJECTS_DIR}" || true)"
    [ -z "${projects_root}" ] && { printf '%s' ""; return 0; }

    if [[ "${SBOX_PROJECT}" = /* ]]; then candidate="${SBOX_PROJECT}"; else candidate="${SBOX_PROJECTS_DIR}/${SBOX_PROJECT}"; fi
    if [ -f "${candidate}" ]; then
        resolved="$(canonicalize_existing_path "${candidate}" || true)"
        if [ -n "${resolved}" ] && [[ "${resolved}" = *.sbproj ]] && path_is_within_root "${resolved}" "${projects_root}"; then
            printf '%s' "${resolved}"; return 0
        fi
    fi
    if [[ "${candidate}" != *.sbproj ]] && [ -f "${candidate}.sbproj" ]; then
        resolved="$(canonicalize_existing_path "${candidate}.sbproj" || true)"
        [ -n "${resolved}" ] && path_is_within_root "${resolved}" "${projects_root}" && { printf '%s' "${resolved}"; return 0; }
    fi
    printf '%s' ""
}

# ─── SteamCMD on Alpine base ────────────────────────────────────────────────
resolve_steamcmd_binary() {
    for c in /usr/bin/steamcmd /usr/games/steamcmd; do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
run_steamcmd_with_timeout() {
    local timeout_seconds="$1"; shift
    local bin; bin="$(resolve_steamcmd_binary || true)"
    [ -z "${bin}" ] && { log_warn "SteamCMD binary not found"; return 1; }
    mkdir -p "${CONTAINER_HOME}/.steam" "${CONTAINER_HOME}/Steam"
    ln -sfn "${CONTAINER_HOME}/Steam" "${CONTAINER_HOME}/.steam/root"
    ln -sfn "${CONTAINER_HOME}/Steam" "${CONTAINER_HOME}/.steam/steam"
    [[ "${timeout_seconds}" == *.* ]] && timeout_seconds="${timeout_seconds%%.*}"
    [ -z "${timeout_seconds}" ] && timeout_seconds=0
    if [ "${timeout_seconds}" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        HOME="${CONTAINER_HOME}" LD_LIBRARY_PATH="/lib:/usr/lib/games/steam" timeout "${timeout_seconds}" "${bin}" "$@"
    else
        HOME="${CONTAINER_HOME}" LD_LIBRARY_PATH="/lib:/usr/lib/games/steam" "${bin}" "$@"
    fi
}

update_sbox() {
    local -a probe_args=( +@ShutdownOnFailedCommand 1 +@NoPromptForPassword 1 +quit )
    local -a steam_args=(
        +@ShutdownOnFailedCommand 1
        +@NoPromptForPassword 1
        +@sSteamCmdForcePlatformType windows
        +force_install_dir "${SBOX_INSTALL_DIR}"
        +login anonymous
        +app_update "${SBOX_APP_ID}"
    )
    [ -n "${SBOX_BRANCH}" ] && steam_args+=( -beta "${SBOX_BRANCH}" )
    local -a steam_args_retry=("${steam_args[@]}")
    steam_args+=( validate +quit )
    steam_args_retry+=( +quit )

    : > "${UPDATE_LOG}"
    set +e
    run_steamcmd_with_timeout "${SBOX_STEAMCMD_TIMEOUT}" "${probe_args[@]}" 2>&1 | tee -a "${UPDATE_LOG}"
    local rc=${PIPESTATUS[0]}
    set -e
    if [ "${rc}" -ne 0 ]; then
        log_warn "SteamCMD probe failed (rc=${rc}); skipping auto-update"
        [ ! -f "${SBOX_SERVER_EXE}" ] && { log_error "${SBOX_SERVER_EXE} not present"; return 1; }
        return 0
    fi

    log_info "running SteamCMD app_update for ${SBOX_APP_ID}"
    set +e
    run_steamcmd_with_timeout "${SBOX_STEAMCMD_TIMEOUT}" "${steam_args[@]}" 2>&1 | tee -a "${UPDATE_LOG}"
    rc=${PIPESTATUS[0]}
    set -e
    if [ "${rc}" -ne 0 ]; then
        if grep -q "Missing configuration" "${UPDATE_LOG}"; then
            log_warn "SteamCMD missing-configuration; retry without validate"
            set +e
            run_steamcmd_with_timeout "${SBOX_STEAMCMD_TIMEOUT}" "${steam_args_retry[@]}" 2>&1 | tee -a "${UPDATE_LOG}"
            rc=${PIPESTATUS[0]}
            set -e
            [ "${rc}" -eq 0 ] && return 0
        fi
        log_warn "SteamCMD update failed (rc=${rc})"
        [ -f "${SBOX_SERVER_EXE}" ] && return 0
        return 1
    fi
}

# ─── Launch sbox-server.exe via Wine ────────────────────────────────────────
run_sbox() {
    local -a cli_args=("$@")
    local -a args=()
    local -a extra=()
    local project_target resolved_server_name="${SERVER_NAME}"
    local cli_has_game_flag=0

    [ ! -f "${SBOX_SERVER_EXE}" ] && { log_error "${SBOX_SERVER_EXE} not found"; exit 1; }

    project_target="$(resolve_project_target)"

    for a in "${cli_args[@]}"; do [ "$a" = "+game" ] && cli_has_game_flag=1; done

    if [ -n "${project_target}" ]; then
        args+=( +game "${project_target}" )
        [ -n "${MAP}" ] && args+=( "${MAP}" )
    elif [ -n "${GAME}" ]; then
        args+=( +game "${GAME}" )
        [ -n "${MAP}" ] && args+=( "${MAP}" )
    elif [ "${cli_has_game_flag}" = "1" ]; then
        :
    else
        log_error "missing startup target; set GAME (and optional MAP) or SBOX_PROJECT"
        exit 1
    fi

    if [ -z "${resolved_server_name}" ] && [ -n "${HOSTNAME_FALLBACK}" ] && [[ ! "${HOSTNAME_FALLBACK}" =~ ^[0-9a-f]{12,64}$ ]]; then
        resolved_server_name="${HOSTNAME_FALLBACK}"
    fi
    [ -n "${resolved_server_name}" ] && args+=( +hostname "${resolved_server_name}" )
    [ -n "${TOKEN}" ] && args+=( +net_game_server_token "${TOKEN}" )
    [ -n "${MAX_PLAYERS}" ] && [ "${MAX_PLAYERS}" -gt 0 ] && args+=( +maxplayers "${MAX_PLAYERS}" )
    [ "${ENABLE_DIRECT_CONNECT}" = "1" ] && args+=( +net_hide_address 0 +port "${SERVER_PORT:-27015}" )
    [ -n "${QUERY_PORT:-}" ] && args+=( +net_query_port "${QUERY_PORT}" )
    if [ -n "${SBOX_EXTRA_ARGS}" ]; then read -ra extra <<< "${SBOX_EXTRA_ARGS}"; args+=( "${extra[@]}" ); fi
    [ "${#cli_args[@]}" -gt 0 ] && args+=( "${cli_args[@]}" )

    unset DOTNET_ROOT DOTNET_ROOT_X86 DOTNET_ROOT_X64
    local -a launch_env=(
        LD_LIBRARY_PATH=/usr/lib:/lib
        DOTNET_EnableWriteXorExecute=0
        DOTNET_TieredCompilation=0
        DOTNET_ReadyToRun=0
        DOTNET_ZapDisable=1
    )

    local -a redacted=()
    local skip_next=0
    for a in "${args[@]}"; do
        if [ "${skip_next}" = "1" ]; then redacted+=( "[REDACTED]" ); skip_next=0; continue; fi
        if [ "$a" = "+net_game_server_token" ]; then redacted+=( "$a" ); skip_next=1; continue; fi
        redacted+=( "$a" )
    done
    log_info "Command: wine \"${SBOX_SERVER_EXE}\" ${redacted[*]}"

    cd "${SBOX_INSTALL_DIR}"
    exec env "${launch_env[@]}" wine "${SBOX_SERVER_EXE}" "${args[@]}" \
        > >(tee -a "${LOG_FILE}") \
        2> >(tee -a "${ERROR_LOG}" >&2)
}

# ─── Main ───────────────────────────────────────────────────────────────────
[ "${1:-}" = "start-sbox" ] && shift

seed_runtime_files

if [ "${1:-}" = "" ] || [[ "${1}" = +* ]]; then
    if [ "${SBOX_AUTO_UPDATE}" = "1" ] || [ ! -f "${SBOX_SERVER_EXE}" ]; then
        log_info "running SteamCMD update on boot..."
        update_sbox || log_warn "update_sbox failed; continuing if files exist"
    fi
    run_sbox "$@"
fi

exec "$@"
