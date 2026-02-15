#!/bin/bash
# weather.sh — Weather via Open-Meteo API (free, no API key needed)
#
# Uses Open-Meteo's free forecast API for daily weather summary.
# Set your coordinates below (find yours at https://open-meteo.com).

check_weather() {
    # ── CONFIGURE YOUR LOCATION ──
    local lat="${WEATHER_LAT:-34.0522}"     # Default: Los Angeles
    local lon="${WEATHER_LON:--118.2437}"
    local tz="${WEATHER_TZ:-America/Los_Angeles}"

    local response
    response=$(curl -s "https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&daily=temperature_2m_max,temperature_2m_min,weathercode,precipitation_probability_max&temperature_unit=fahrenheit&timezone=${tz}&forecast_days=1" 2>/dev/null)

    if [[ -z "$response" ]]; then
        echo "WEATHER: Unavailable ⚠️"
        return 1
    fi

    local high low wcode precip_prob
    high=$(echo "$response" | grep -o '"temperature_2m_max":\[[0-9.]*\]' | grep -o '[0-9.]*' | tail -1)
    low=$(echo "$response" | grep -o '"temperature_2m_min":\[[0-9.]*\]' | grep -o '[0-9.]*' | tail -1)
    wcode=$(echo "$response" | grep -o '"weathercode":\[[0-9]*\]' | grep -o '[0-9]*' | tail -1)
    precip_prob=$(echo "$response" | grep -o '"precipitation_probability_max":\[[0-9]*\]' | grep -o '[0-9]*' | tail -1)

    high=$(printf "%.0f" "$high" 2>/dev/null || echo "$high")
    low=$(printf "%.0f" "$low" 2>/dev/null || echo "$low")

    # WMO weather code to icon + description
    local icon conditions
    case "$wcode" in
        0)  icon="☀️"; conditions="Clear skies";;
        1)  icon="🌤"; conditions="Mostly clear";;
        2)  icon="⛅"; conditions="Partly cloudy";;
        3)  icon="☁️"; conditions="Overcast";;
        45|48) icon="🌫"; conditions="Foggy";;
        51|53|55) icon="🌦"; conditions="Drizzle";;
        61|63|65) icon="🌧"; conditions="Rain";;
        66|67) icon="🌧"; conditions="Freezing rain";;
        71|73|75) icon="❄️"; conditions="Snow";;
        77) icon="❄️"; conditions="Snow grains";;
        80|81|82) icon="🌧"; conditions="Rain showers";;
        85|86) icon="❄️"; conditions="Snow showers";;
        95) icon="⛈"; conditions="Thunderstorm";;
        96|99) icon="⛈"; conditions="Thunderstorm with hail";;
        *) icon="❓"; conditions="Unknown (code ${wcode})";;
    esac

    local precip_text=""
    if [[ -n "$precip_prob" && "$precip_prob" -gt 20 ]]; then
        precip_text=" | ${precip_prob}% chance of rain"
    fi

    echo "WEATHER: ${icon} ${high}°/${low}°F, ${conditions}${precip_text}"
}
