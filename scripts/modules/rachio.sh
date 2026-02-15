#!/bin/bash
# rachio.sh — Rachio irrigation module (conditional)
#
# Only outputs when there's something worth knowing:
#   - Device offline or in standby
#   - Weather intelligence skip (rain detected)
#   - Currently watering
#   - Rain in forecast (likely skip)
#
# Prerequisites:
#   - Rachio API key in ~/.config/homelab/rachio.env
#   - Person ID and Device ID from the Rachio API
#
# Getting your IDs:
#   curl -s https://api.rach.io/1/public/person/info \
#     -H "Authorization: Bearer YOUR_API_KEY" | python3 -m json.tool

# ── CONFIGURATION ──
RACHIO_ENV="$HOME/.config/homelab/rachio.env"

if [[ -f "$RACHIO_ENV" ]]; then
    source "$RACHIO_ENV"
fi

# Set these after running the API call above
RACHIO_PERSON_ID="${RACHIO_PERSON_ID:-your-person-id-here}"
RACHIO_DEVICE_ID="${RACHIO_DEVICE_ID:-your-device-id-here}"
API_BASE="https://api.rach.io/1/public"

rachio_api() {
    local endpoint="$1"
    curl -s --connect-timeout 10 --max-time 15 \
        "${API_BASE}${endpoint}" \
        -H "Authorization: Bearer ${RACHIO_API_KEY}"
}

collect_rachio() {
    # Bail if not configured
    if [[ -z "$RACHIO_API_KEY" || "$RACHIO_DEVICE_ID" == "your-device-id-here" ]]; then
        return 0
    fi

    local output=""
    local has_news=false

    # Get device status
    local device_json
    device_json=$(rachio_api "/device/${RACHIO_DEVICE_ID}")
    local device_status
    device_status=$(echo "$device_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','UNKNOWN'))" 2>/dev/null)

    # Device offline is always noteworthy
    if [[ "$device_status" != "ONLINE" ]]; then
        output+="🚿 Rachio: OFFLINE ⚠️"
        echo "$output"
        return
    fi

    # Check standby mode
    local standby
    standby=$(echo "$device_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('on', True))" 2>/dev/null)
    if [[ "$standby" == "False" ]]; then
        output+="🚿 Rachio: Standby Mode"
        has_news=true
    fi

    # Get recent events (last 48 hours)
    local now_ms=$(( $(date +%s) * 1000 ))
    local two_days_ago_ms=$(( ($(date +%s) - 172800) * 1000 ))
    local events_json
    events_json=$(rachio_api "/device/${RACHIO_DEVICE_ID}/event?startTime=${two_days_ago_ms}&endTime=${now_ms}")

    # Check for weather skip in last 48h
    local skip_info
    skip_info=$(echo "$events_json" | python3 -c "
import json, sys
from datetime import datetime
events = json.load(sys.stdin)
for e in events:
    if e.get('subType') == 'WEATHER_INTELLIGENCE_SKIP':
        ts = e['eventDate'] / 1000
        dt = datetime.fromtimestamp(ts).strftime('%m/%d')
        print(f\"Rain skip {dt}\")
        break
" 2>/dev/null)

    # Check for completed run in last 48h
    local last_run
    last_run=$(echo "$events_json" | python3 -c "
import json, sys
from datetime import datetime
events = json.load(sys.stdin)
for e in events:
    if e.get('subType') == 'SCHEDULE_COMPLETED':
        ts = e['eventDate'] / 1000
        dt = datetime.fromtimestamp(ts).strftime('%m/%d %I:%M %p')
        summary = e.get('summary', '')
        print(f\"{summary.rstrip('.')} on {dt}\")
        break
" 2>/dev/null)

    # Check if currently watering
    local current
    current=$(rachio_api "/device/${RACHIO_DEVICE_ID}/current_schedule")
    local is_running
    is_running=$(echo "$current" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if data:
    print('yes')
else:
    print('no')
" 2>/dev/null)

    # Build output — only if there's something to report
    if [[ "$is_running" == "yes" ]]; then
        output+="🚿 Rachio: Watering now"
        has_news=true
    elif [[ -n "$skip_info" ]]; then
        if [[ -n "$output" ]]; then output+="\n"; fi
        output+="🚿 Rachio: ${skip_info}"
        if [[ -n "$last_run" ]]; then
            output+=" · Last: ${last_run}"
        fi
        has_news=true
    fi

    # Check for upcoming rain that might cause skip
    local forecast_json
    forecast_json=$(rachio_api "/device/${RACHIO_DEVICE_ID}/forecast?units=US")
    local rain_alert
    rain_alert=$(echo "$forecast_json" | python3 -c "
import json, sys
from datetime import datetime
data = json.load(sys.stdin)

# Check current conditions
current = data.get('current', {})
if current.get('precipProbability', 0) > 0.7:
    summary = current.get('weatherSummary', 'Rain')
    print(f\"Current: {summary}\")
    sys.exit(0)

# Check next 2 days forecast
forecast = sorted(data.get('forecast', []), key=lambda x: x.get('time', 0))
for day in forecast[:2]:
    if day.get('precipProbability', 0) > 0.5:
        dt = datetime.fromtimestamp(day['time']).strftime('%a %m/%d')
        prob = int(day['precipProbability'] * 100)
        precip = day.get('calculatedPrecip', 0)
        print(f\"Rain {dt} ({prob}%, {precip:.1f}in) — likely skip\")
        break
" 2>/dev/null)

    if [[ -n "$rain_alert" && "$has_news" == false ]]; then
        output+="🚿 Rachio: ${rain_alert}"
        has_news=true
    elif [[ -n "$rain_alert" && "$has_news" == true ]]; then
        output+=" · ${rain_alert}"
    fi

    # Only output if there's something noteworthy
    if [[ "$has_news" == true ]]; then
        echo -e "$output"
    fi
}
