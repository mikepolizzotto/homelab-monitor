#!/bin/bash
# homebridge.sh — Pull device states from Homebridge API
#
# Parses HomeKit accessory data for:
#   - Climate (Nest/Ecobee thermostat)
#   - Air quality (Dyson/other purifiers)
#   - Alerts (garage door, security system, cameras)
#
# Requires Homebridge UI with API enabled.

# ── CONFIGURATION ──
HB_HOST="${HOMEBRIDGE_HOST:-192.168.1.100}"
HB_PORT="${HOMEBRIDGE_PORT:-8581}"
HB_USER="${HOMEBRIDGE_USER:-admin}"
HB_PASS="${HOMEBRIDGE_PASS:-admin}"
HB_BASE="http://${HB_HOST}:${HB_PORT}"

# Get auth token
hb_get_token() {
    local response
    response=$(curl -s -X POST "${HB_BASE}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${HB_USER}\",\"password\":\"${HB_PASS}\"}" 2>/dev/null)

    echo "$response" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

# Get all accessories
hb_get_accessories() {
    local token="$1"
    curl -s "${HB_BASE}/api/accessories" \
        -H "Authorization: Bearer ${token}" 2>/dev/null
}

# Parse climate data from thermostat accessories
parse_climate() {
    local accessories="$1"
    local temp humidity hvac_mode

    temp=$(echo "$accessories" | grep -o '"CurrentTemperature":[0-9.]*' | head -1 | cut -d: -f2)
    humidity=$(echo "$accessories" | grep -o '"CurrentRelativeHumidity":[0-9.]*' | head -1 | cut -d: -f2)

    # HVAC mode: 0=Off, 1=Heat, 2=Cool, 3=Auto
    local hvac_val
    hvac_val=$(echo "$accessories" | grep -o '"TargetHeatingCoolingState":[0-9]' | head -1 | cut -d: -f2)
    case "$hvac_val" in
        0) hvac_mode="Off";;
        1) hvac_mode="Heating";;
        2) hvac_mode="Cooling";;
        3) hvac_mode="Auto";;
        *) hvac_mode="Unknown";;
    esac

    # Convert Celsius to Fahrenheit
    if [[ -n "$temp" ]]; then
        temp=$(echo "$temp" | awk '{printf "%.0f", ($1 * 9/5) + 32}')
    fi
    if [[ -n "$humidity" ]]; then
        humidity=$(printf "%.0f" "$humidity")
    fi

    echo "CLIMATE: ${temp:-?}°F indoor, ${humidity:-?}% humidity, HVAC: ${hvac_mode}"
}

# Parse air quality data from purifier accessories
parse_air_quality() {
    local accessories="$1"

    local pm25 voc aq_val filter_life

    pm25=$(echo "$accessories" | grep -o '"PM2_5Density":[0-9.]*' | head -1 | cut -d: -f2)

    # HomeKit AirQuality: 1=Excellent, 2=Good, 3=Fair, 4=Inferior, 5=Poor
    aq_val=$(echo "$accessories" | grep -o '"AirQuality":[0-9]' | head -1 | cut -d: -f2)
    local aq_label
    case "$aq_val" in
        1) aq_label="Excellent";;
        2) aq_label="Good";;
        3) aq_label="Fair";;
        4) aq_label="Inferior ⚠️";;
        5) aq_label="Poor ⚠️";;
        *) aq_label="Unknown";;
    esac

    voc=$(echo "$accessories" | grep -o '"VOCDensity":[0-9.]*' | head -1 | cut -d: -f2)
    local voc_display=""
    if [[ -n "$voc" ]]; then
        voc_display=" (VOC ${voc}/10)"
    fi

    filter_life=$(echo "$accessories" | grep -o '"FilterLifeLevel":[0-9.]*' | head -1 | cut -d: -f2)
    local filter_display
    if [[ -n "$filter_life" ]]; then
        filter_display="Filter: ${filter_life}%"
    else
        filter_display="Filter: ?"
    fi

    echo "AIR: ${aq_label}${voc_display} | PM2.5 ${pm25:-?} | ${filter_display}"
}

# Parse alerts (garage door, security system, cameras)
parse_alerts() {
    local accessories="$1"
    local alerts=""

    # Garage door: CurrentDoorState 0=Open, 1=Closed, 2=Opening, 3=Closing, 4=Stopped
    local garage_state
    garage_state=$(echo "$accessories" | grep -o '"CurrentDoorState":[0-9]' | head -1 | cut -d: -f2)
    if [[ "$garage_state" == "0" ]]; then
        alerts+="⚠️ GARAGE: Currently OPEN\n"
    fi

    # Security system: 0=StayArm, 1=AwayArm, 2=NightArm, 3=Disarmed, 4=AlarmTriggered
    local alarm_state
    alarm_state=$(echo "$accessories" | grep -o '"SecuritySystemCurrentState":[0-9]' | head -1 | cut -d: -f2)
    if [[ "$alarm_state" == "4" ]]; then
        alerts+="⚠️ ALARM: Triggered!\n"
    fi

    # Camera faults
    local cam_faults
    cam_faults=$(echo "$accessories" | grep -c '"StatusFault":1' 2>/dev/null)
    if [[ "${cam_faults:-0}" -gt 0 ]]; then
        alerts+="⚠️ CAMERAS: ${cam_faults} camera(s) reporting fault\n"
    fi

    if [[ -n "$alerts" ]]; then
        echo -e "$alerts"
    fi
}

# Main function
check_homebridge() {
    local token
    token=$(hb_get_token)

    if [[ -z "$token" ]]; then
        echo "CLIMATE: Homebridge API unavailable ⚠️"
        echo "AIR: Homebridge API unavailable ⚠️"
        return 1
    fi

    local accessories
    accessories=$(hb_get_accessories "$token")

    if [[ -z "$accessories" ]]; then
        echo "CLIMATE: No accessory data ⚠️"
        echo "AIR: No accessory data ⚠️"
        return 1
    fi

    parse_climate "$accessories"
    parse_air_quality "$accessories"
    parse_alerts "$accessories"
}
