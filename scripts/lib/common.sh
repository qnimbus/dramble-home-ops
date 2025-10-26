#!/usr/bin/env bash
# set -Eeuo pipefail

# Log messages with different levels
function log() {
    local level="${1:-info}"
    shift

    # Define log levels with their priorities
    local -A level_priority=(
        [debug]=1
        [info]=2
        [warn]=3
        [error]=4
    )

    # Get the current log level's priority
    local current_priority=${level_priority[$level]:-2} # Default to "info" priority

    # Get the configured log level from the environment, default to "info"
    local configured_level=${LOG_LEVEL:-info}
    local configured_priority=${level_priority[$configured_level]:-2}

    # Skip log messages below the configured log level
    if ((current_priority < configured_priority)); then
        return
    fi

    local msg="$1"
    shift

    # Prepare additional data with gum styling
    local data=""
    if [[ $# -gt 0 ]]; then
        for item in "$@"; do
            if [[ "${item}" == *=* ]]; then
                local key="${item%%=*}"
                local value="${item#*=}"
                if command -v gum &>/dev/null; then
                    data+="$(gum style --foreground="#6C7086" "${key}=")\"${value}\" "
                else
                    data+="${key}=\"${value}\" "
                fi
            else
                data+="${item} "
            fi
        done
    fi

    # Determine output stream based on log level
    local output_stream="/dev/stdout"
    if [[ "$level" == "error" ]]; then
        output_stream="/dev/stderr"
    fi

    # Format log message with gum if available, fallback to plain text
    if command -v gum &>/dev/null; then
        local timestamp=$(gum style --foreground="#6C7086" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")")
        local level_styled
        case "$level" in
            debug)
                level_styled=$(gum style --foreground="#89B4FA" --bold "${level^^}")
                ;;
            info)
                level_styled=$(gum style --foreground="#94E2D5" --bold "${level^^}")
                ;;
            warn)
                level_styled=$(gum style --foreground="#F9E2AF" --bold "${level^^}")
                ;;
            error)
                level_styled=$(gum style --foreground="#F38BA8" --bold "${level^^}")
                ;;
            *)
                level_styled=$(gum style --foreground="#94E2D5" --bold "${level^^}")
                ;;
        esac
        
        printf "%s %s %s %s\n" "${timestamp}" "${level_styled}" "${msg}" "${data}" >"${output_stream}"
    else
        # Fallback to original ANSI color codes if gum is not available
        local -A colors=(
            [debug]="\033[1m\033[38;5;63m"  # Blue
            [info]="\033[1m\033[38;5;87m"   # Cyan
            [warn]="\033[1m\033[38;5;192m"  # Yellow
            [error]="\033[1m\033[38;5;198m" # Red
        )
        local color="${colors[$level]:-${colors[info]}}"
        printf "%s %b%s%b %s %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            "${color}" "${level^^}" "\033[0m" "${msg}" "${data}" >"${output_stream}"
    fi

    # Exit if the log level is error
    if [[ "$level" == "error" ]]; then
        exit 1
    fi
}

# Check if required environment variables are set
function check_env() {
    local envs=("${@}")
    local missing=()
    local values=()

    for env in "${envs[@]}"; do
        if [[ -z "${!env-}" ]]; then
            missing+=("${env}")
        else
            values+=("${env}=${!env}")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log error "Missing required env variables" "envs=${missing[*]}"
    fi

    log debug "Env variables are set" "envs=${values[*]}"
}

# Check if required CLI tools are installed
function check_cli() {
    local deps=("${@}")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "${dep}" &>/dev/null; then
            missing+=("${dep}")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log error "Missing required deps" "deps=${missing[*]}"
    fi

    log debug "Deps are installed" "deps=${deps[*]}"
}
