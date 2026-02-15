#!/bin/bash
# backups.sh — Check S3-compatible backup status (Wasabi, AWS, MinIO, etc.)
#
# Uses AWS CLI with a named profile to check the most recent object
# in each backup bucket. Alerts if backups are stale (>36 hours).
#
# Prerequisites:
#   - AWS CLI configured with a named profile (e.g., ~/.aws/credentials)
#   - S3-compatible endpoint URL

check_backups() {
    local output=""
    local now_epoch=$(date "+%s")

    # ── CONFIGURATION ──
    # AWS CLI profile name (from ~/.aws/credentials)
    local AWS_PROFILE="wasabi"
    # S3-compatible endpoint (Wasabi, MinIO, etc.) — leave empty for AWS S3
    local S3_ENDPOINT="--endpoint-url https://s3.us-west-1.wasabisys.com"
    # Stale threshold in hours
    local STALE_HOURS=36

    # Define your backup buckets: "Label|bucket-name"
    declare -a BUCKETS=(
        "NAS1 → Wasabi|my-nas1-backups"
        "NAS2 → Wasabi|my-nas2-backups"
    )

    for bucket_info in "${BUCKETS[@]}"; do
        IFS='|' read -r label bucket <<< "$bucket_info"

        local latest_line
        latest_line=$(aws --profile "$AWS_PROFILE" s3 ls "s3://${bucket}/" --recursive $S3_ENDPOINT 2>/dev/null | sort | tail -1)

        if [[ -n "$latest_line" ]]; then
            local bk_date=$(echo "$latest_line" | awk '{print $1}')
            local bk_time=$(echo "$latest_line" | awk '{print $2}')

            local bk_epoch
            bk_epoch=$(date -j -u -f "%Y-%m-%d %H:%M:%S" "$bk_date $bk_time" "+%s" 2>/dev/null)

            if [[ -n "$bk_epoch" ]]; then
                local age_hrs=$(( (now_epoch - bk_epoch) / 3600 ))
                local display_time
                display_time=$(date -j -r "$bk_epoch" "+%-I:%M %p" 2>/dev/null || echo "$bk_time")

                if [[ $age_hrs -gt $STALE_HOURS ]]; then
                    output+="${label}  ${display_time} ⚠️ (${age_hrs}h ago)\n"
                else
                    output+="${label}  ${display_time} ✓\n"
                fi
            else
                output+="${label}  ${bk_date} ${bk_time} (parse error) ⚠️\n"
            fi
        else
            output+="${label}  UNKNOWN ⚠️\n"
        fi
    done

    echo -e "${output}"
}
