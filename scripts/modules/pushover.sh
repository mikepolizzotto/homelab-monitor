#!/bin/bash
# pushover.sh — Send notifications via Pushover API
# Usage: source this file, then call send_pushover "title" "message" [priority]

PUSHOVER_ENV="$HOME/.config/homelab/pushover.env"

send_pushover() {
    local title="$1"
    local message="$2"
    local priority="${3:-0}"  # Default priority 0 (normal)

    if [[ ! -f "$PUSHOVER_ENV" ]]; then
        echo "ERROR: Pushover credentials not found at $PUSHOVER_ENV" >&2
        return 1
    fi

    source "$PUSHOVER_ENV"

    if [[ -z "$PUSHOVER_USER_KEY" || -z "$PUSHOVER_API_TOKEN" ]]; then
        echo "ERROR: Missing PUSHOVER_USER_KEY or PUSHOVER_API_TOKEN" >&2
        return 1
    fi

    local response
    response=$(curl -s -X POST https://api.pushover.net/1/messages.json \
        -d "token=$PUSHOVER_API_TOKEN" \
        -d "user=$PUSHOVER_USER_KEY" \
        -d "priority=$priority" \
        -d "title=$title" \
        --data-urlencode "message=$message" \
        2>/dev/null)

    local status
    status=$(echo "$response" | grep -o '"status":[0-9]' | grep -o '[0-9]')

    if [[ "$status" == "1" ]]; then
        return 0
    else
        echo "ERROR: Pushover send failed: $response" >&2
        return 1
    fi
}
