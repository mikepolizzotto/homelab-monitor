#!/bin/bash
# disks.sh — Check disk health across NAS devices
#
# Supports:
#   - Synology: runtime data from /run/synostorage/disks/ (no sudo needed)
#   - ZFS pools: health, capacity, scrub status
#
# Customize SSH aliases and drive letters for your environment.

check_disks() {
    local output=""

    # ── SYNOLOGY NAS ──
    # SSH alias for your Synology (set in ~/.ssh/config)
    local SYNOLOGY_SSH="nas1"
    # Drive letters present in your Synology (check /run/synostorage/disks/)
    local SYNOLOGY_DRIVES="sda sdb sdc sdd sde sdf"

    local syn_usage
    syn_usage=$(ssh -o ConnectTimeout=10 "$SYNOLOGY_SSH" \
        "df -h /volume1 2>/dev/null | tail -1 | awk '{print \$5}'" 2>/dev/null)

    # Drive temps and SMART from Synology runtime data
    local temp_min=999 temp_max=0
    local smart_ok=true
    local smart_details=""

    local disk_data
    disk_data=$(ssh -o ConnectTimeout=10 "$SYNOLOGY_SSH" \
        "for d in ${SYNOLOGY_DRIVES}; do
            t=\$(cat /run/synostorage/disks/\$d/temperature 2>/dev/null)
            s=\$(cat /run/synostorage/disks/\$d/smart 2>/dev/null)
            b=\$(cat /run/synostorage/disks/\$d/bad_sec_ct 2>/dev/null)
            echo \"\$d|\$t|\$s|\$b\"
        done" 2>/dev/null)

    if [[ -n "$disk_data" ]]; then
        while IFS='|' read -r drive temp smart bad_sec; do
            [[ -z "$temp" ]] && continue

            if [[ "$temp" -lt "$temp_min" ]]; then temp_min=$temp; fi
            if [[ "$temp" -gt "$temp_max" ]]; then temp_max=$temp; fi

            if [[ "$smart" != "normal" ]]; then
                smart_ok=false
                smart_details+="    ⚠️ $drive: SMART=$smart\n"
            fi

            if [[ -n "$bad_sec" && "$bad_sec" != "0" ]]; then
                smart_ok=false
                smart_details+="    ⚠️ $drive: $bad_sec bad sectors\n"
            fi
        done <<< "$disk_data"

        local health="healthy"
        if ! $smart_ok; then
            health="⚠️ ISSUES DETECTED"
        fi

        output+="Synology: RAID ${health}, ${syn_usage:-??} used, drives ${temp_min}-${temp_max}°C\n"
        if [[ -n "$smart_details" ]]; then
            output+="$smart_details"
        fi
    else
        output+="Synology: Disk data unavailable ⚠️\n"
    fi

    # ── ZFS NAS (QNAP or any ZFS system) ──
    # SSH alias for your ZFS-based NAS
    local ZFS_SSH="nas2"
    # Pool names to report on
    local ZFS_POOLS="zpool1 zpool2"

    local zfs_data
    zfs_data=$(ssh -o ConnectTimeout=15 "$ZFS_SSH" \
        "zpool list -o name,health,cap 2>/dev/null | tail -n +2" 2>/dev/null)

    if [[ -n "$zfs_data" ]]; then
        local zfs_summary=""
        local zfs_issues=false
        while IFS= read -r line; do
            local pool_name pool_health pool_cap
            pool_name=$(echo "$line" | awk '{print $1}')
            pool_health=$(echo "$line" | awk '{print $2}')
            pool_cap=$(echo "$line" | awk '{print $3}')

            if [[ "$pool_health" != "ONLINE" ]]; then
                zfs_issues=true
            fi

            # Only report pools you care about
            for p in $ZFS_POOLS; do
                if [[ "$pool_name" == "$p" ]]; then
                    zfs_summary+="${pool_name}: ${pool_health} ${pool_cap}, "
                fi
            done
        done <<< "$zfs_data"
        zfs_summary="${zfs_summary%, }"

        if $zfs_issues; then
            output+="ZFS NAS: ⚠️ ZFS issue — ${zfs_summary}\n"
        else
            output+="ZFS NAS: ZFS clean, ${zfs_summary}\n"
        fi
    else
        output+="ZFS NAS: status unavailable ⚠️\n"
    fi

    # ── Optional: system partition usage warning ──
    local mnt_ext_usage
    mnt_ext_usage=$(ssh -o ConnectTimeout=15 "$ZFS_SSH" \
        "df /mnt/ext 2>/dev/null | tail -1 | awk '{print \$5}'" 2>/dev/null)
    if [[ -n "$mnt_ext_usage" ]]; then
        local mnt_pct="${mnt_ext_usage%%%}"
        if [[ "$mnt_pct" -ge 95 ]]; then
            output+="⚠️ ZFS NAS /mnt/ext at ${mnt_ext_usage} — critical\n"
        elif [[ "$mnt_pct" -ge 90 ]]; then
            output+="ZFS NAS /mnt/ext at ${mnt_ext_usage} — monitor\n"
        fi
    fi

    echo -e "${output}"
}
