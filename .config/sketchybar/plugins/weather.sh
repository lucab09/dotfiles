#!/bin/sh

LOCATION_FILE="$HOME/.config/sketchybar/weather_location.json"

# Use saved location if available
if [ -f "$LOCATION_FILE" ]; then
  LAT=$(python3 -c "import json; d=json.load(open('$LOCATION_FILE')); print(d['lat'])")
  LON=$(python3 -c "import json; d=json.load(open('$LOCATION_FILE')); print(d['lon'])")
  CITY=$(python3 -c "import json; d=json.load(open('$LOCATION_FILE')); print(d['name'].split(',')[0].strip())")
fi

# Fallback: city-level via IP
if [ -z "$LAT" ] || [ -z "$LON" ]; then
  COORDS=$(curl -sf "https://ipinfo.io/loc" 2>/dev/null)
  LAT=$(echo "$COORDS" | cut -d',' -f1)
  LON=$(echo "$COORDS" | cut -d',' -f2)
fi

if [ -z "$LAT" ] || [ -z "$LON" ]; then
  sketchybar --set "$NAME" label="--"
  exit 0
fi

RESPONSE=$(curl -sf "https://api.open-meteo.com/v1/forecast?latitude=${LAT}&longitude=${LON}&current=temperature_2m,weather_code,is_day&temperature_unit=celsius")

TEMP=$(echo "$RESPONSE"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['current']['temperature_2m'])" 2>/dev/null)
CODE=$(echo "$RESPONSE"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['current']['weather_code'])" 2>/dev/null)
IS_DAY=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['current']['is_day'])" 2>/dev/null)

if [ -z "$TEMP" ]; then
  sketchybar --set "$NAME" label="--"
  exit 0
fi

# Map WMO weather code → Nerd Font icon (nf-md-weather_*)
# is_day=1 → day icons, is_day=0 → night variants for clear/partly
case "$CODE" in
  0)           [ "$IS_DAY" = "1" ] && ICON="󰖙" || ICON="󰖔" ;;  # clear
  1)           [ "$IS_DAY" = "1" ] && ICON="󰖕" || ICON="󰖔" ;;  # mainly clear
  2)           ICON="󰖕" ;;                                       # partly cloudy
  3)           ICON="󰖐" ;;                                       # overcast
  45|48)       ICON="󰖑" ;;                                       # fog
  51|53|55)    ICON="󰖖" ;;                                       # drizzle
  61|63|65)    ICON="󰖗" ;;                                       # rain
  66|67)       ICON="󰖗" ;;                                       # freezing rain
  71|73|75|77) ICON="󰼶" ;;                                       # snow
  80|81|82)    ICON="󰖗" ;;                                       # showers
  85|86)       ICON="󰼶" ;;                                       # snow showers
  95|96|99)    ICON="󰖓" ;;                                       # thunderstorm
  *)           ICON="󰖐" ;;
esac

# Label: temperature · city (if saved)
if [ -n "$CITY" ]; then
  LABEL="${TEMP}°C · ${CITY}"
else
  LABEL="${TEMP}°C"
fi

sketchybar --set "$NAME" icon="$ICON" label="$LABEL"
