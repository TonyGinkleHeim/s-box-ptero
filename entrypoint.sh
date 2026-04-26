#!/usr/bin/env bash
# s&box Pterodactyl entrypoint (Wine runtime).
# - Seeds /opt/sbox-wine-prefix into /home/container/.wine on first boot.
# - Runs SteamCMD with credentials (app 1892930 is not anonymous).
# - Execs sbox-server.exe via wine, args built from panel env vars.
set -euo pipefail

CONTAINER_HOME="${CONTAINER_HOME:-/home/container}"
WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"
BAKED_WINEPREFIX="${SBOX_BAKED_WINEPREFIX:-/opt/sbox-wine-prefix}"

SBOX_INSTALL_DIR="${SBOX_INSTALL_DIR:-/home/container/sbox}"
SBOX_SERVER_EXE="${SBOX_SERVER_EXE:-${SBOX_INSTALL_DIR}/sbox-server.exe}"
SBOX_APP_ID="${SBOX_APP_ID:-1892930}"
SBOX_AUTO_UPDATE="${SBOX_AUTO_UPDATE:-1}"
SBOX_BRANCH="${SBOX_BRANCH:-}"
SBOX_STEAMCMD_TIMEOUT="${SBOX_STEAMCMD_TIMEOUT:-900}"

STEAM_USERNAME="${STEAM_USERNAME:-}"
STEAM_PASSWORD="${STEAM_PASSWORD:-}"
STEAM_GUARD="${STEAM_GUARD:-}"

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

# ─── Seed prebaked Wine prefix on first boot ────────────────────────────────
seed_runtime_files() {
    mkdir -p "${WINEPREFIX}" "${SBOX_INSTALL_DIR}"
    if [ ! -f "${WINEPREFIX}/system.reg" ] && [ -d "${BAKED_WINEPREFIX}/drive_c" ]; then
        log_info "seeding Wine prefix from ${BAKED_WINEPREFIX}"
        cp -r "${BAKED_WINEPREFIX}/." "${WINEPREFIX}/"
    fi
}

# ─── Project resolver ───────────────────────────────────────────────────────
canonicalize_existing_path() {
    [ -n "${1:-}" ] && [ -e "${1}" ] || return 1
    local d b; d="$(dirname "$1")"; b="$(basename "$1")"
    ( cd "${d}" 2>/dev/null || exit 1; printf '%s/%s' "$(pwd -P)" "${b}" )
}
path_is_within_root() { case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac; }
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

# ─── SteamCMD runner with credential login ──────────────────────────────────
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
        HOME="${CONTAINER_HOME}" LD_LIBRARY_PATH="${CONTAINER_HOME}/Steam" "${bin}" "$@"
    fi
}

update_sbox() {
    if [ -z "${STEAM_USERNAME}" ] || [ -z "${STEAM_PASSWORD}" ]; then
        log_warn "STEAM_USERNAME / STEAM_PASSWORD not set; skipping SteamCMD update"
        [ ! -f "${SBOX_SERVER_EXE}" ] && { log_error "no server exe present and no creds to fetch one"; return 1; }
        return 0
    fi

    local -a args=(
        +@ShutdownOnFailedCommand 1
        +@NoPromptForPassword 1
        +@sSteamCmdForcePlatformType windows
        +force_install_dir "${SBOX_INSTALL_DIR}"
    )
    if [ -n "${STEAM_GUARD}" ]; then
        args+=( +set_steam_guard_code "${STEAM_GUARD}" )
        args+=( +login "${STEAM_USERNAME}" "${STEAM_PASSWORD}" "${STEAM_GUARD}" )
    else
        args+=( +login "${STEAM_USERNAME}" "${STEAM_PASSWORD}" )
    fi
    args+=( +app_update "${SBOX_APP_ID}" )
    [ -n "${SBOX_BRANCH}" ] && args+=( -beta "${SBOX_BRANCH}" )
    args+=( validate +quit )

    : > "${UPDATE_LOG}"
    log_info "running SteamCMD app_update for ${SBOX_APP_ID} (branch=${SBOX_BRANCH:-public})"
    set +e
    run_steamcmd_with_timeout "${SBOX_STEAMCMD_TIMEOUT}" "${args[@]}" 2>&1 | tee -a "${UPDATE_LOG}"
    local rc=${PIPESTATUS[0]}
    set -e
    if [ "${rc}" -ne 0 ]; then
        log_warn "SteamCMD update failed (rc=${rc}); see ${UPDATE_LOG}"
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

    local -a redacted=(); local skip_next=0
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
        update_sbox || { log_error "SteamCMD update failed and no existing server files"; exit 1; }
    fi
    run_sbox "$@"
fi

exec "$@"
