#!/bin/bash
# infra.sh — Check device availability and service status
#
# Configure your devices in the array below.
# Format: "Name|IP_or_hostname|ssh_alias|special_check"
#   - ssh_alias: SSH config alias (or "none" for ping-only)
#   - special_check: "homebridge" to also check the service, or "none"

check_infra() {
    local output=""

    # ── CONFIGURE YOUR DEVICES HERE ──
    declare -a devices=(
        "server|localhost|none|none"
        "nas1|192.168.1.100|nas1|none"
        "nas2|192.168.1.101|nas2|none"
        "homebridge|192.168.1.102|homebridge|homebridge"
        "router|192.168.1.1|router|none"
    )

    for device_info in "${devices[@]}"; do
        IFS='|' read -r name ip ssh_alias special <<< "$device_info"

        local dev_status="✗"
        local extra=""

        if [[ "$ip" == "localhost" ]]; then
            dev_status="✓"
        elif [[ "$ssh_alias" != "none" ]]; then
            if ssh -o ConnectTimeout=15 -o BatchMode=yes "$ssh_alias" "echo ok" &>/dev/null; then
                dev_status="✓"
            else
                if ping -c 2 -W 3 "$ip" &>/dev/null; then
                    dev_status="⚠️ SSH fail"
                else
                    dev_status="✗ DOWN"
                fi
            fi
        else
            if ping -c 2 -W 3 "$ip" &>/dev/null; then
                dev_status="✓"
            fi
        fi

        # Optional: check if Homebridge service is running
        if [[ "$special" == "homebridge" && "$dev_status" == "✓" ]]; then
            local svc
            svc=$(ssh -o ConnectTimeout=5 "$ssh_alias" "systemctl is-active homebridge" 2>/dev/null)
            if [[ "$svc" != "active" ]]; then
                extra=" (svc ${svc:-?}) ⚠️"
            fi
        fi

        output+="${name} ${dev_status}${extra}  "
    done

    # Trim trailing spaces
    output="${output%  }"
    echo "$output"
}
