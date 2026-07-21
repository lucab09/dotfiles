#!/bin/sh

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
GEOLOCATE_APP="$PLUGIN_DIR/Geolocate.app"
GEO_CACHE="$HOME/Library/Caches/sketchybar-geolocation.json"

# Posizione reale del Mac via CoreLocation. Deve girare come vera .app
# (lanciata con `open`), altrimenti il permesso non viene mai richiesto:
# `open` non inoltra lo stdout, quindi legge il risultato da un file di cache.
if [ -d "$GEOLOCATE_APP" ]; then
  open -W -g "$GEOLOCATE_APP" 2>/dev/null
  COORDS=$(cat "$GEO_CACHE" 2>/dev/null)
  LAT=$(echo "$COORDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['lat'])" 2>/dev/null)
  LON=$(echo "$COORDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['lon'])" 2>/dev/null)
fi

# Fallback: geolocalizzazione IP a livello di città, se CoreLocation non è disponibile.
if [ -z "$LAT" ] || [ -z "$LON" ]; then
  IPCOORDS=$(curl -sf "https://ipinfo.io/loc" 2>/dev/null)
  LAT=$(echo "$IPCOORDS" | cut -d',' -f1)
  LON=$(echo "$IPCOORDS" | cut -d',' -f2)
fi

if [ -z "$LAT" ] || [ -z "$LON" ]; then
  sketchybar --set "$NAME" label="--"
  exit 0
fi

CITY=$(curl -sfL "https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=${LAT}&longitude=${LON}&localityLanguage=it" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('city') or d.get('locality') or '')" 2>/dev/null)

RESPONSE=$(curl -sf "https://api.open-meteo.com/v1/forecast?latitude=${LAT}&longitude=${LON}&current=temperature_2m,weather_code,is_day&temperature_unit=celsius")

TEMP=$(echo "$RESPONSE"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['current']['temperature_2m'])" 2>/dev/null)
CODE=$(echo "$RESPONSE"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['current']['weather_code'])" 2>/dev/null)
IS_DAY=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['current']['is_day'])" 2>/dev/null)

if [ -z "$TEMP" ]; then
  sketchybar --set "$NAME" label="--"
  exit 0
fi

# Map WMO weather code → Material Symbols Rounded icon name
# is_day=1 → day icons, is_day=0 → night variants for clear/partly
case "$CODE" in
  0)           [ "$IS_DAY" = "1" ] && ICON="sunny"              || ICON="bedtime" ;;        # clear
  1)           [ "$IS_DAY" = "1" ] && ICON="partly_cloudy_day"  || ICON="partly_cloudy_night" ;;  # mainly clear
  2)           [ "$IS_DAY" = "1" ] && ICON="partly_cloudy_day"  || ICON="partly_cloudy_night" ;;  # partly cloudy
  3)           ICON="cloud" ;;                                                               # overcast
  45|48)       ICON="foggy" ;;                                                              # fog
  51|53|55)    ICON="rainy" ;;                                                              # drizzle
  61|63|65)    ICON="rainy" ;;                                                              # rain
  66|67)       ICON="weather_mix" ;;                                                        # freezing rain
  71|73|75|77) ICON="weather_snowy" ;;                                                      # snow
  80|81|82)    ICON="rainy" ;;                                                              # showers
  85|86)       ICON="cloudy_snowing" ;;                                                     # snow showers
  95|96|99)    ICON="thunderstorm" ;;                                                       # thunderstorm
  *)           ICON="cloud" ;;
esac

# Label: temperature · city (if resolved)
if [ -n "$CITY" ]; then
  LABEL="${TEMP}°C · ${CITY}"
else
  LABEL="${TEMP}°C"
fi

sketchybar --set "$NAME" icon="$ICON" label="$LABEL"

# Qualità dell'aria — indice europeo (EAQI): 0-40 buona, 40-80 moderata, >80 scarsa.
AQI=$(curl -sf "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=${LAT}&longitude=${LON}&current=european_aqi" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d['current']['european_aqi']))" 2>/dev/null)

if [ -n "$AQI" ]; then
  if [ "$AQI" -le 40 ]; then
    AQI_RGB=79d491
  elif [ "$AQI" -le 80 ]; then
    AQI_RGB=f2c14e
  else
    AQI_RGB=cf6679
  fi
  sketchybar --set air_quality label="AQI $AQI" label.color="0xff${AQI_RGB}" background.color="0x29${AQI_RGB}"
fi
