#!/bin/bash
set -euo pipefail

LOG_FILE=/tmp/test.log
LOG_LEVEL=normal

_log() {
    local level="$1" color="$2" message="$3"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local plain_message
    plain_message=$(echo "$message" | sed 's/\x1B\[[0-9;]*[A-Za-z]//g')
    echo "[$timestamp] $level: $plain_message" >> "$LOG_FILE"
    case "$LOG_LEVEL" in
        quiet) [[ "$level" == "ERROR" ]] && echo -e "${color}${message}${NC}";;
        normal) [[ "$level" != "DEBUG" ]] && echo -e "${color}${message}${NC}";;
        verbose) echo -e "${color}${message}${NC}";;
    esac
}

log_debug() { _log "DEBUG" "" "$1"; }

main() {
    echo "Before call"
    if true; then
        log_debug "test message"
        echo "Inside if block after log_debug"
    fi
    echo "After if"
}

main && echo "SUCCESS" || echo "FAILED"
