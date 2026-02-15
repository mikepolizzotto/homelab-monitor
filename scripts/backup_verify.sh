#!/bin/bash
# backup_verify.sh — Weekly S3 Backup Integrity Verification
#
# Runs weekly via launchd/cron, sends report via Pushover.
# Checks: object counts, total size, growth delta, staleness, bucket accessibility.
#
# Tracks deltas against a saved baseline to detect anomalies:
#   - Object count drops >5%
#   - Zero growth (backups may have stopped)
#   - Size decrease (unexpected deletion)
#   - Stale backups (>48h since last object)

set -o pipefail

SCRIPT_DIR="$HOME/homelab/scripts"
DATA_DIR="$SCRIPT_DIR/data"
LOG_DIR="$HOME/homelab/logs"
LOG_FILE="$LOG_DIR/backup_verify_$(date +%Y%m%d_%H%M%S).log"
BASELINE_FILE="$DATA_DIR/backup_baseline.json"

# ── CONFIGURATION ──
# AWS CLI profile name (from ~/.aws/credentials)
AWS_PROFILE="wasabi"
# S3-compatible endpoint — leave empty for AWS S3
S3_ENDPOINT="--endpoint-url https://s3.us-west-1.wasabisys.com"
# Stale threshold in hours
STALE_HOURS=48
# Anomaly threshold: alert if object count drops more than this %
ANOMALY_DROP_PCT=5

# Define your backup buckets: "label|bucket-name"
declare -a BUCKETS=(
    "NAS1|my-nas1-backups"
    "NAS2|my-nas2-backups"
)

source "$SCRIPT_DIR/modules/pushover.sh"

log() { echo "$(date): $1" >> "$LOG_FILE"; }

format_size() {
    local bytes=$1
    if [[ ${bytes#-} -ge 1099511627776 ]]; then
        python3 -c "print(f'{$bytes/1099511627776:.1f} TiB')"
    elif [[ ${bytes#-} -ge 1073741824 ]]; then
        python3 -c "print(f'{$bytes/1073741824:.1f} GiB')"
    elif [[ ${bytes#-} -ge 1048576 ]]; then
        python3 -c "print(f'{$bytes/1048576:.1f} MiB')"
    elif [[ ${bytes#-} -ge 1024 ]]; then
        python3 -c "print(f'{$bytes/1024:.1f} KiB')"
    else
        echo "${bytes} B"
    fi
}

format_delta_size() {
    local bytes=$1
    local formatted
    formatted=$(format_size ${bytes#-})
    if [[ $bytes -gt 0 ]]; then
        echo "+${formatted}"
    elif [[ $bytes -lt 0 ]]; then
        echo "-${formatted}"
    else
        echo "±0"
    fi
}

delta_sign() {
    if [[ $1 -gt 0 ]]; then echo "+$1"
    elif [[ $1 -lt 0 ]]; then echo "$1"
    else echo "±0"
    fi
}

check_freshness() {
    local newest="$1"
    if [[ "$newest" == "NONE" ]]; then echo "⚠️ EMPTY"; return; fi
    local epoch
    epoch=$(date -j -u -f "%Y-%m-%d %H:%M:%S" "$newest" "+%s" 2>/dev/null)
    if [[ -z "$epoch" ]]; then echo "⚠️ PARSE ERROR"; return; fi
    local age_hrs=$(( ($(date +%s) - epoch) / 3600 ))
    if [[ $age_hrs -gt $STALE_HOURS ]]; then
        echo "⚠️ STALE (${age_hrs}h)"
    else
        echo "✓ (${age_hrs}h ago)"
    fi
}

log "Starting weekly backup verification..."

# ─── Collect bucket stats ───

declare -A bucket_objects bucket_sizes bucket_newest

for bucket_info in "${BUCKETS[@]}"; do
    IFS='|' read -r label bucket <<< "$bucket_info"
    log "Scanning ${bucket}..."

    listing=$(aws --profile "$AWS_PROFILE" s3 ls "s3://${bucket}/" --recursive $S3_ENDPOINT 2>>"$LOG_FILE")

    if [[ -z "$listing" ]]; then
        log "WARNING: Empty or inaccessible bucket: ${bucket}"
        bucket_objects[$label]=0
        bucket_sizes[$label]=0
        bucket_newest[$label]="NONE"
        continue
    fi

    bucket_objects[$label]=$(echo "$listing" | wc -l | tr -dc '0-9')
    bucket_sizes[$label]=$(echo "$listing" | awk '{sum += $3} END {printf "%.0f", sum}')
    bucket_newest[$label]=$(echo "$listing" | sort | tail -1 | awk '{print $1, $2}')

    log "${bucket}: ${bucket_objects[$label]} objects, ${bucket_sizes[$label]} bytes, newest: ${bucket_newest[$label]}"
done

# ─── Load previous baseline ───

declare -A prev_objects prev_sizes

if [[ -f "$BASELINE_FILE" ]]; then
    for bucket_info in "${BUCKETS[@]}"; do
        IFS='|' read -r label bucket <<< "$bucket_info"
        local key=$(echo "$label" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
        prev_objects[$label]=$(python3 -c "import json; d=json.load(open('$BASELINE_FILE')); print(d.get('${key}_objects', 0))" 2>/dev/null || echo 0)
        prev_sizes[$label]=$(python3 -c "import json; d=json.load(open('$BASELINE_FILE')); print(d.get('${key}_size', 0))" 2>/dev/null || echo 0)
    done
    log "Loaded baseline."
fi

# ─── Build report ───

alerts=""
msg="<b>Weekly Backup Verification</b>\n"
msg+="$(date '+%A, %B %d %Y')\n"

for bucket_info in "${BUCKETS[@]}"; do
    IFS='|' read -r label bucket <<< "$bucket_info"

    local objects=${bucket_objects[$label]:-0}
    local size=${bucket_sizes[$label]:-0}
    local newest=${bucket_newest[$label]:-NONE}
    local prev_obj=${prev_objects[$label]:-0}
    local prev_sz=${prev_sizes[$label]:-0}

    local obj_delta=$(( objects - prev_obj ))
    local size_delta=$(( size - prev_sz ))
    local fresh=$(check_freshness "$newest")

    msg+="\n───────────────────────\n"
    msg+="<b>${label}</b>\n"
    msg+="Objects: ${objects} ($(delta_sign $obj_delta))\n"
    msg+="Size: $(format_size $size) ($(format_delta_size $size_delta))\n"
    msg+="Newest: ${newest} ${fresh}\n"

    # Anomaly checks
    if [[ $prev_obj -gt 0 && $obj_delta -lt 0 ]]; then
        local loss_pct=$(( (-obj_delta) * 100 / prev_obj ))
        if [[ $loss_pct -gt $ANOMALY_DROP_PCT ]]; then
            alerts+="⚠️ ${label} lost ${obj_delta#-} objects (${loss_pct}% drop)\n"
        fi
    fi
    if [[ $obj_delta -eq 0 && $prev_obj -gt 0 ]]; then
        alerts+="⚠️ ${label}: zero growth since last check\n"
    fi
    if [[ $size_delta -lt 0 ]]; then
        alerts+="⚠️ ${label} size decreased by $(format_size ${size_delta#-})\n"
    fi
    if echo "$fresh" | grep -q "STALE\|EMPTY"; then
        alerts+="⚠️ ${label} backup stale: ${fresh}\n"
    fi
done

if [[ -n "$alerts" ]]; then
    msg+="\n───────────────────────\n"
    msg+="<b>⚠️ ANOMALIES</b>\n"
    msg+="${alerts}"
else
    msg+="\nAll checks passed ✓\n"
fi

message=$(echo -e "$msg")
log "Report built. Sending via Pushover..."

# ─── Send via Pushover ───

source "$HOME/.config/homelab/pushover.env"

priority="-1"  # Quiet when clean
[[ -n "$alerts" ]] && priority="1"  # High priority on anomalies

response=$(curl -s -X POST https://api.pushover.net/1/messages.json \
    -d "token=$PUSHOVER_API_TOKEN" \
    -d "user=$PUSHOVER_USER_KEY" \
    -d "priority=${priority}" \
    -d "html=1" \
    -d "title=🔒 Backup Verification — $(date '+%b %d')" \
    --data-urlencode "message=$message" \
    2>/dev/null)

send_status=$(echo "$response" | grep -o '"status":[0-9]' | grep -o '[0-9]')
[[ "$send_status" == "1" ]] && log "Report sent." || log "ERROR: $response"

# ─── Save new baseline ───

baseline_json="{"
baseline_json+="\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
for bucket_info in "${BUCKETS[@]}"; do
    IFS='|' read -r label bucket <<< "$bucket_info"
    local key=$(echo "$label" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
    baseline_json+=",\"${key}_objects\":${bucket_objects[$label]:-0}"
    baseline_json+=",\"${key}_size\":${bucket_sizes[$label]:-0}"
done
baseline_json+="}"

echo "$baseline_json" | python3 -m json.tool > "$BASELINE_FILE"

log "Baseline saved."
find "$LOG_DIR" -name "backup_verify_*.log" -mtime +90 -delete 2>/dev/null
log "Done."
