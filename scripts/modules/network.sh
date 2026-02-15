#!/bin/bash
# network.sh — Network status, security checks
#
# Checks: client count, unknown device detection, WAN status,
#          firewall rules, SSH failures, firewall drops.
#
# Designed for UniFi Dream Machine but adaptable to other routers
# that expose /proc/net/arp and iptables.

DATA_DIR="$HOME/homelab/scripts/data"
KNOWN_DEVICES_FILE="$DATA_DIR/known_devices.json"

# ── CONFIGURATION ──
# SSH aliases (set in ~/.ssh/config)
ROUTER_SSH="router"
NAS1_SSH="nas1"
NAS2_SSH="nas2"
VM_SSH="homebridge"

# WAN interface name on your router
WAN_INTERFACE="eth8"
# Firewall chain to inspect
FW_CHAIN="UBIOS_LAN_IN_USER"
# Expected minimum firewall rules
FW_EXPECTED=15

check_network() {
    local output=""

    # --- Client count ---
    local client_count
    client_count=$(ssh -o ConnectTimeout=10 "$ROUTER_SSH" \
        "cat /proc/net/arp 2>/dev/null | grep -v '00:00:00:00:00:00' | grep -cv 'IP address'" 2>/dev/null)
    client_count="${client_count:-?}"

    # --- Unknown device detection ---
    local new_devices=0
    local new_device_details=""

    local current_clients
    current_clients=$(ssh -o ConnectTimeout=10 "$ROUTER_SSH" \
        "cat /proc/net/arp 2>/dev/null | grep -v '00:00:00:00:00:00' | tail -n +2 | awk '{print \$1,\$4}'" 2>/dev/null)

    if [[ -f "$KNOWN_DEVICES_FILE" ]]; then
        while IFS= read -r line; do
            local mac=$(echo "$line" | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
            if [[ -n "$mac" ]] && ! grep -qi "$mac" "$KNOWN_DEVICES_FILE" 2>/dev/null; then
                local ip=$(echo "$line" | awk '{print $1}')
                new_devices=$((new_devices + 1))
                new_device_details+="⚠️ New: ${ip} (${mac})\n"
            fi
        done <<< "$current_clients"
    else
        new_devices="N/A"
    fi

    # --- WAN ---
    local wan_status
    wan_status=$(ssh -o ConnectTimeout=10 "$ROUTER_SSH" \
        "ip addr show dev ${WAN_INTERFACE} 2>/dev/null | grep -c 'inet ' || echo 0" 2>/dev/null)
    local wan_display
    if [[ "$wan_status" -ge 1 ]]; then
        wan_display="stable"
    else
        wan_display="⚠️ issue"
    fi

    # --- Firewall rules ---
    local fw_rules
    fw_rules=$(ssh -o ConnectTimeout=10 "$ROUTER_SSH" \
        "iptables -L ${FW_CHAIN} -n 2>/dev/null | grep -cE '(DROP|RETURN)'" 2>/dev/null)
    fw_rules="${fw_rules:-0}"

    local fw_display
    if [[ "$fw_rules" -ge $(( FW_EXPECTED - 2 )) ]]; then
        fw_display="${fw_rules}/${FW_EXPECTED} ✓"
    else
        fw_display="⚠️ ${fw_rules}/${FW_EXPECTED}"
    fi

    # --- SSH failures (last 24h) ---
    local ssh_failures=0
    local yesterday today
    yesterday=$(date -v-1d "+%b %e" 2>/dev/null || date -d "yesterday" "+%b %e" 2>/dev/null)
    today=$(date "+%b %e" 2>/dev/null)

    for host in "$NAS1_SSH" "$NAS2_SSH" "$VM_SSH"; do
        local fails
        fails=$(ssh -o ConnectTimeout=10 "$host" \
            "grep -E 'Failed password|Invalid user' /var/log/auth.log 2>/dev/null | grep -cE '${today}|${yesterday}'" 2>/dev/null || echo 0)
        fails=$(echo "${fails:-0}" | tr -dc '0-9')
        fails=${fails:-0}
        ssh_failures=$(( ssh_failures + fails ))
    done

    # --- Firewall drops (delta since last run) ---
    local fw_drops
    fw_drops=$(ssh -o ConnectTimeout=10 "$ROUTER_SSH" \
        "iptables -L ${FW_CHAIN} -n -v 2>/dev/null | grep 'DROP' | awk '{sum+=\$1} END {print sum+0}'" 2>/dev/null)
    fw_drops="${fw_drops:-0}"

    local drops_file="$DATA_DIR/fw_drops_last.txt"
    local last_drops=0
    local drop_delta="$fw_drops"

    if [[ -f "$drops_file" ]]; then
        last_drops=$(cat "$drops_file" 2>/dev/null || echo 0)
        drop_delta=$((fw_drops - last_drops))
        if [[ $drop_delta -lt 0 ]]; then
            drop_delta=$fw_drops
        fi
    fi
    echo "$fw_drops" > "$drops_file"

    # Build output
    output+="${client_count} clients | WAN ${wan_display} | FW ${fw_display}\n"

    # Security line (only if noteworthy)
    local sec_items=""
    if [[ "$new_devices" -gt 0 && "$new_devices" != "N/A" ]]; then
        sec_items+="${new_devices} new devices | "
    fi
    if [[ "$ssh_failures" -gt 0 ]]; then
        sec_items+="SSH fails: ${ssh_failures} | "
    fi
    if [[ "$drop_delta" -gt 5000 ]]; then
        sec_items+="⚠️ FW drops +${drop_delta} | "
    fi

    if [[ -n "$sec_items" ]]; then
        sec_items="${sec_items% | }"
        output+="${sec_items}\n"
    fi

    if [[ -n "$new_device_details" ]]; then
        output+="${new_device_details}"
    fi

    echo -e "$output"
}

# Utility: generate a known devices baseline from your router's ARP table
generate_baseline() {
    mkdir -p "$DATA_DIR"
    echo "Generating known devices baseline..."
    ssh -o ConnectTimeout=10 "$ROUTER_SSH" \
        "cat /proc/net/arp 2>/dev/null | grep -v '00:00:00:00:00:00' | tail -n +2 | awk '{print \$1,\$4}'" \
        > "$DATA_DIR/known_devices_raw.txt" 2>/dev/null

    local macs=()
    while IFS= read -r line; do
        local mac=$(echo "$line" | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
        local ip=$(echo "$line" | awk '{print $1}')
        [[ -n "$mac" ]] && macs+=("{\"mac\":\"$mac\",\"ip\":\"$ip\",\"added\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}")
    done < "$DATA_DIR/known_devices_raw.txt"

    echo "[" > "$KNOWN_DEVICES_FILE"
    local first=true
    for entry in "${macs[@]}"; do
        if $first; then
            echo "  $entry" >> "$KNOWN_DEVICES_FILE"
            first=false
        else
            echo "  ,$entry" >> "$KNOWN_DEVICES_FILE"
        fi
    done
    echo "]" >> "$KNOWN_DEVICES_FILE"

    echo "Baseline saved: $(wc -l < "$DATA_DIR/known_devices_raw.txt") devices → $KNOWN_DEVICES_FILE"
}
