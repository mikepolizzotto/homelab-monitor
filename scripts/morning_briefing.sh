#!/bin/bash
# morning_briefing.sh — Daily Morning Briefing
#
# Collects data from all modules and sends a formatted
# summary via Pushover push notification.
#
# Schedule with cron or launchd (see launchd/ directory).

set -o pipefail

SCRIPT_DIR="$HOME/homelab/scripts"
LOG_DIR="$HOME/homelab/logs"
LOG_FILE="$LOG_DIR/briefing_$(date +%Y%m%d_%H%M%S).log"

# Source all modules
source "$SCRIPT_DIR/modules/pushover.sh"
source "$SCRIPT_DIR/modules/infra.sh"
source "$SCRIPT_DIR/modules/disks.sh"
source "$SCRIPT_DIR/modules/backups.sh"
source "$SCRIPT_DIR/modules/network.sh"
source "$SCRIPT_DIR/modules/homebridge.sh"
source "$SCRIPT_DIR/modules/weather.sh"
source "$SCRIPT_DIR/modules/rachio.sh"

echo "$(date): Starting morning briefing..." >> "$LOG_FILE"

# Collect data from each module
echo "$(date): Checking infra..." >> "$LOG_FILE"
infra_result=$(check_infra 2>>"$LOG_FILE")

echo "$(date): Checking network..." >> "$LOG_FILE"
network_result=$(check_network 2>>"$LOG_FILE")

echo "$(date): Checking disks..." >> "$LOG_FILE"
disk_result=$(check_disks 2>>"$LOG_FILE")

echo "$(date): Checking backups..." >> "$LOG_FILE"
backup_result=$(check_backups 2>>"$LOG_FILE")

echo "$(date): Checking Homebridge..." >> "$LOG_FILE"
hb_result=$(check_homebridge 2>>"$LOG_FILE")

echo "$(date): Checking weather..." >> "$LOG_FILE"
weather_result=$(check_weather 2>>"$LOG_FILE")

echo "$(date): Checking Rachio..." >> "$LOG_FILE"
rachio_result=$(collect_rachio 2>>"$LOG_FILE")

# Parse homebridge output
hb_climate=$(echo "$hb_result" | grep "^CLIMATE:" || echo "")
hb_air=$(echo "$hb_result" | grep "^AIR:" || echo "")
hb_alerts=$(echo "$hb_result" | grep "^⚠️" || echo "")

# Build message
msg=""
msg+="${weather_result}\n"
msg+="\n"
msg+="───────────────────────\n"
msg+="<b>SYSTEMS</b>\n"
msg+="${infra_result}\n"
msg+="\n"
msg+="${network_result}\n"
msg+="───────────────────────\n"
msg+="<b>STORAGE + BACKUPS</b>\n"
msg+="${disk_result}\n"
msg+="\n"
msg+="${backup_result}\n"
msg+="───────────────────────\n"
msg+="<b>HOME</b>\n"
msg+="${hb_climate}\n"
msg+="${hb_air}\n"

# Rachio — conditional, only shows when noteworthy
if [[ -n "$rachio_result" ]]; then
    msg+="${rachio_result}\n"
fi

if [[ -n "$hb_alerts" ]]; then
    msg+="\n"
    msg+="───────────────────────\n"
    msg+="<b>⚠️ ALERTS</b>\n"
    msg+="${hb_alerts}\n"
fi

message=$(echo -e "$msg")

echo "$(date): Sending briefing via Pushover..." >> "$LOG_FILE"
echo -e "$msg" >> "$LOG_FILE"

# Send via Pushover
source "$HOME/.config/homelab/pushover.env"

response=$(curl -s -X POST https://api.pushover.net/1/messages.json \
    -d "token=$PUSHOVER_API_TOKEN" \
    -d "user=$PUSHOVER_USER_KEY" \
    -d "priority=0" \
    -d "html=1" \
    -d "title=☀️ Morning Briefing — $(date '+%b %d')" \
    --data-urlencode "message=$message" \
    2>/dev/null)

send_status=$(echo "$response" | grep -o '"status":[0-9]' | grep -o '[0-9]')

if [[ "$send_status" == "1" ]]; then
    echo "$(date): Briefing sent successfully." >> "$LOG_FILE"
else
    echo "$(date): ERROR: $response" >> "$LOG_FILE"
fi

# Clean up old logs (keep 30 days)
find "$LOG_DIR" -name "briefing_*.log" -mtime +30 -delete 2>/dev/null
echo "$(date): Done." >> "$LOG_FILE"
