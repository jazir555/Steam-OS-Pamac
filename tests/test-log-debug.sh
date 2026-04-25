#!/bin/bash
set -euo pipefail

LOG_LEVEL="normal"

_log() {
    local level="$1" color="$2" message="$3"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    local plain_message
    plain_message=$(echo "$message" | sed 's/\x1B\[[0-9;]*[A-Za-z]//g')

    echo "[$timestamp] $level: $plain_message" >> /dev/null

    case "$LOG_LEVEL" in
        "quiet") [[ "$level" == "ERROR" ]] && echo -e "${color}${message}${NC}" ;;
        "normal") [[ "$level" != "DEBUG" ]] && echo -e "${color}${message}${NC}" ;;
        "verbose") echo -e "${color}${message}${NC}" ;;
    esac
}

echo "Calling _log with level=DEBUG..."
_log DEBUG "" "This is a debug message"
echo "Survived the debug log call"

echo "Calling _log with level=INFO..."
_log INFO "" "This is an info message"
echo "Survived the info log call"

echo "ALL PASSED"
