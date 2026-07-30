#!/bin/sh

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
GEOLOCATE_APP="$PLUGIN_DIR/Geolocate.app"
GEO_CACHE="$HOME/Library/Caches/sketchybar-geolocation.json"
STATE_FILE="/tmp/sketchybar_weather_state.json"

case "$SENDER" in
  mouse.entered|mouse.exited)
    "$PLUGIN_DIR/weather_popup_hover.sh"
    exit 0
    ;;
esac

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

FORECAST_URL="https://api.open-meteo.com/v1/forecast?latitude=${LAT}&longitude=${LON}&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m,wind_gusts_10m,wind_direction_10m,surface_pressure,cloud_cover,precipitation&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,uv_index_max,sunrise,sunset&forecast_days=1&timezone=auto&temperature_unit=celsius&wind_speed_unit=kmh"
AIR_URL="https://air-quality-api.open-meteo.com/v1/air-quality?latitude=${LAT}&longitude=${LON}&current=european_aqi,pm10,pm2_5,nitrogen_dioxide,ozone,grass_pollen,birch_pollen,olive_pollen"

RESPONSE=$(curl -sf "$FORECAST_URL" 2>/dev/null)
AIR_RESPONSE=$(curl -sf "$AIR_URL" 2>/dev/null)

export WEATHER_RESPONSE="$RESPONSE"
export WEATHER_AIR_RESPONSE="$AIR_RESPONSE"
export WEATHER_CITY="$CITY"
export WEATHER_LAT="$LAT"
export WEATHER_LON="$LON"
export WEATHER_STATE_FILE="$STATE_FILE"

python3 <<'PY'
import json, os, subprocess, tempfile

response = os.environ.get('WEATHER_RESPONSE') or '{}'
air_response = os.environ.get('WEATHER_AIR_RESPONSE') or '{}'
city = os.environ.get('WEATHER_CITY') or ''
state_file = os.environ.get('WEATHER_STATE_FILE') or '/tmp/sketchybar_weather_state.json'
name = os.environ.get('NAME') or 'weather'

def load(raw):
    try:
        return json.loads(raw)
    except Exception:
        return {}

def value(d, *path):
    cur = d
    for key in path:
        if isinstance(cur, dict):
            cur = cur.get(key)
        elif isinstance(cur, list) and isinstance(key, int) and len(cur) > key:
            cur = cur[key]
        else:
            return None
    return cur

def rounded(v):
    try:
        return int(round(float(v)))
    except Exception:
        return None

def one_decimal(v):
    try:
        return round(float(v), 1)
    except Exception:
        return None

def weather_icon(code, is_day):
    code = str(code)
    day = str(is_day) == '1'
    if code == '0': return 'sunny' if day else 'bedtime'
    if code in ('1','2'): return 'partly_cloudy_day' if day else 'partly_cloudy_night'
    if code == '3': return 'cloud'
    if code in ('45','48'): return 'foggy'
    if code in ('51','53','55','61','63','65','80','81','82'): return 'rainy'
    if code in ('66','67'): return 'weather_mix'
    if code in ('71','73','75','77'): return 'weather_snowy'
    if code in ('85','86'): return 'cloudy_snowing'
    if code in ('95','96','99'): return 'thunderstorm'
    return 'cloud'

def weather_description(code):
    mapping = {
        0: 'Sereno', 1: 'Prevalentemente sereno', 2: 'Parzialmente nuvoloso', 3: 'Coperto',
        45: 'Nebbia', 48: 'Nebbia con brina', 51: 'Pioviggine leggera', 53: 'Pioviggine',
        55: 'Pioviggine intensa', 61: 'Pioggia leggera', 63: 'Pioggia', 65: 'Pioggia intensa',
        66: 'Pioggia gelata leggera', 67: 'Pioggia gelata', 71: 'Neve leggera', 73: 'Neve',
        75: 'Neve intensa', 77: 'Nevischio', 80: 'Rovesci leggeri', 81: 'Rovesci',
        82: 'Rovesci intensi', 85: 'Rovesci di neve', 86: 'Rovesci di neve intensi',
        95: 'Temporale', 96: 'Temporale con grandine', 99: 'Temporale con grandine intensa'
    }
    try:
        return mapping.get(int(code), 'Meteo')
    except Exception:
        return 'Meteo'

def wind_direction_label(deg):
    try:
        deg = float(deg) % 360
    except Exception:
        return ''
    labels = ['N','NE','E','SE','S','SO','O','NO']
    return labels[int((deg + 22.5) // 45) % 8]

def aqi_color(aqi):
    if aqi is None: return '79d491'
    if aqi <= 40: return '79d491'
    if aqi <= 80: return 'f2c14e'
    return 'cf6679'

def weather_icon_color(icon):
    return {
        'sunny': 'ffcc4d',
        'partly_cloudy_day': 'ffd166',
        'partly_cloudy_night': 'b7c2ff',
        'bedtime': 'b7c2ff',
        'rainy': '80deff',
        'weather_mix': '80deff',
        'weather_snowy': 'b9ebff',
        'cloudy_snowing': 'b9ebff',
        'foggy': 'cac4d0',
        'thunderstorm': 'be91ff',
        'cloud': 'cac4d0',
    }.get(icon, 'cac4d0')

def lerp(a, b, t):
    return round(a + (b - a) * t)

def temperature_pill_color(temp):
    stops = [
        (-5,  (47, 111, 218)),   # freddo
        (8,   (38, 166, 184)),   # fresco
        (18,  (67, 160, 111)),   # mite
        (27,  (196, 144, 59)),   # caldo
        (34,  (212, 96, 61)),    # molto caldo
        (42,  (178, 64, 92)),    # estremo
    ]
    if temp is None:
        r, g, b = (73, 69, 79)
    else:
        temp = float(temp)
        if temp <= stops[0][0]:
            r, g, b = stops[0][1]
        elif temp >= stops[-1][0]:
            r, g, b = stops[-1][1]
        else:
            for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
                if t0 <= temp <= t1:
                    f = (temp - t0) / (t1 - t0)
                    r, g, b = (lerp(c0[0], c1[0], f), lerp(c0[1], c1[1], f), lerp(c0[2], c1[2], f))
                    break
    return f'{r:02x}{g:02x}{b:02x}'

w = load(response)
a = load(air_response)
cur = w.get('current') or {}
daily = w.get('daily') or {}
air = a.get('current') or {}

temp = one_decimal(cur.get('temperature_2m'))
code = cur.get('weather_code')
is_day = cur.get('is_day')
icon = weather_icon(code, is_day)

if temp is None:
    subprocess.run(['sketchybar', '--set', name, 'label=--'])
    raise SystemExit(0)

aqi = rounded(air.get('european_aqi'))
aqi_rgb = aqi_color(aqi)

payload = {
    'city': city,
    'latitude': os.environ.get('WEATHER_LAT'),
    'longitude': os.environ.get('WEATHER_LON'),
    'temperature': temp,
    'apparent_temperature': one_decimal(cur.get('apparent_temperature')),
    'condition': weather_description(code),
    'weather_code': code,
    'is_day': is_day,
    'icon': icon,
    'icon_color': f"0xff{weather_icon_color(icon)}",
    'pill_color': f"0xff{temperature_pill_color(temp)}",
    'humidity': rounded(cur.get('relative_humidity_2m')),
    'wind_speed': one_decimal(cur.get('wind_speed_10m')),
    'wind_gusts': one_decimal(cur.get('wind_gusts_10m')),
    'wind_direction': wind_direction_label(cur.get('wind_direction_10m')),
    'pressure': rounded(cur.get('surface_pressure')),
    'cloud_cover': rounded(cur.get('cloud_cover')),
    'precipitation': one_decimal(cur.get('precipitation')),
    'temp_max': one_decimal(value(daily, 'temperature_2m_max', 0)),
    'temp_min': one_decimal(value(daily, 'temperature_2m_min', 0)),
    'precipitation_probability': rounded(value(daily, 'precipitation_probability_max', 0)),
    'uv_index': one_decimal(value(daily, 'uv_index_max', 0)),
    'sunrise': value(daily, 'sunrise', 0),
    'sunset': value(daily, 'sunset', 0),
    'aqi': aqi,
    'aqi_color': f'0xff{aqi_rgb}',
    'pm10': one_decimal(air.get('pm10')),
    'pm2_5': one_decimal(air.get('pm2_5')),
    'nitrogen_dioxide': one_decimal(air.get('nitrogen_dioxide')),
    'ozone': one_decimal(air.get('ozone')),
    'grass_pollen': one_decimal(air.get('grass_pollen')),
    'birch_pollen': one_decimal(air.get('birch_pollen')),
    'olive_pollen': one_decimal(air.get('olive_pollen')),
}

fd, tmp = tempfile.mkstemp(prefix='sketchybar_weather_state_', suffix='.json')
with os.fdopen(fd, 'w') as f:
    json.dump(payload, f)
os.replace(tmp, state_file)

label = f'{temp:g}°C · {city}' if city else f'{temp:g}°C'
if icon == 'sunny':
    widget_icon = '☼'
    widget_font = 'Apple Symbols:Regular:18.0'
elif icon in ('weather_snowy', 'cloudy_snowing'):
    widget_icon = '❄'
    widget_font = 'Apple Symbols:Regular:18.0'
elif icon in ('rainy', 'weather_mix'):
    widget_icon = '☔︎'
    widget_font = 'Apple Symbols:Regular:17.0'
elif icon == 'cloud':
    widget_icon = '☁︎'
    widget_font = 'Apple Symbols:Regular:18.0'
elif icon in ('partly_cloudy_day', 'partly_cloudy_night'):
    widget_icon = '⛅︎'
    widget_font = 'Apple Symbols:Regular:17.0'
elif icon == 'foggy':
    widget_icon = '≋'
    widget_font = 'Apple Symbols:Regular:18.0'
elif icon == 'thunderstorm':
    widget_icon = '☇'
    widget_font = 'Apple Symbols:Regular:18.0'
elif icon == 'bedtime':
    widget_icon = '☾'
    widget_font = 'Apple Symbols:Regular:18.0'
else:
    widget_icon = icon
    widget_font = 'Material Symbols Rounded:Regular:18.0'
pill_rgb = temperature_pill_color(temp)
subprocess.run([
    'sketchybar', '--set', name,
    'icon.drawing=off', f'icon={widget_icon}', f'icon.font={widget_font}',
    f'icon.color=0xff{weather_icon_color(icon)}', f'label={label}'
])
subprocess.run(['sketchybar', '--set', 'weather_pill', f'background.color=0xff{pill_rgb}'])
PY
