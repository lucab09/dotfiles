#!/bin/sh
# Card meteo quadrata, allineata al widget meteo di produzione
# (.config/sketchybar/plugins/weather.sh): stessi dati, stesso refresh
# (state file condiviso, riusa quello script per il fetch), stessi glifi
# icona/colori, e sfondo della card = pill_color di produzione (gradiente
# per temperatura, non per condizione). Il rendering pixel-preciso è
# delegato a card_render.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
PROD_PLUGIN_DIR="$(cd "$DIR/../../plugins" && pwd)"
STATE_FILE="/tmp/sketchybar_weather_state.json"
OUT_PNG="/tmp/sketchybar_weather_card.png"

# Aggiorna lo state file riusando la weather.sh di produzione (stesso fetch,
# stesso update_freq=900 impostato sull'item nel dashboardrc): NAME fittizio,
# gli item "weather"/"weather_pill" potrebbero non esistere in questa bar di
# test, sketchybar --set su un item inesistente fallisce silenziosamente.
NAME=weather_card_probe "$PROD_PLUGIN_DIR/weather.sh" >/dev/null 2>&1 || true

CARD_SIDE="${1:-280}"

python3 - "$STATE_FILE" "$OUT_PNG" "$CARD_SIDE" "$DIR/card_render" <<'PY'
import json, subprocess, sys

state_file, out_png, side, renderer = sys.argv[1:5]

try:
    with open(state_file) as f:
        s = json.load(f)
except Exception:
    s = {}

icon = s.get('icon', 'cloud')

# Stessa mappatura glifo/font di weather.sh (widget_icon/widget_font), solo
# il nome famiglia (senza ":peso:size", lo gestisce l'auto-fit di card_render).
if icon == 'sunny':
    glyph, glyph_font = '☼', 'Apple Symbols'
elif icon in ('weather_snowy', 'cloudy_snowing'):
    glyph, glyph_font = '❄', 'Apple Symbols'
elif icon in ('rainy', 'weather_mix'):
    glyph, glyph_font = '☔︎', 'Apple Symbols'
elif icon == 'cloud':
    glyph, glyph_font = '☁︎', 'Apple Symbols'
elif icon in ('partly_cloudy_day', 'partly_cloudy_night'):
    glyph, glyph_font = '⛅︎', 'Apple Symbols'
elif icon == 'foggy':
    glyph, glyph_font = '≋', 'Apple Symbols'
elif icon == 'thunderstorm':
    glyph, glyph_font = '☇', 'Apple Symbols'
elif icon == 'bedtime':
    glyph, glyph_font = '☾', 'Apple Symbols'
else:
    glyph, glyph_font = icon, 'Material Symbols Rounded'

icon_color = s.get('icon_color') or '0xffcac4d0'
pill_color = s.get('pill_color') or '0xff49454f'

temp = s.get('temperature')
feels = s.get('apparent_temperature')
city = s.get('city') or '--'
humidity = s.get('humidity')
condition = s.get('condition') or 'Meteo'

def fmt(v):
    return f"{v:g}°" if isinstance(v, (int, float)) else "--°"

lines = [
    [{"t": fmt(temp), "b": True}, {"t": " ora", "b": False}],
    [{"t": "a ", "b": False}, {"t": city, "b": True}],
    [{"t": "percepiti ", "b": False}, {"t": fmt(feels), "b": True}],
    [{"t": f"{glyph} ", "font": glyph_font, "color": icon_color}, {"t": condition, "b": True}],
]
if isinstance(humidity, (int, float)):
    lines.append([{"t": "umidità ", "b": False}, {"t": f"{humidity}%", "b": True}])

card = {"background": pill_color, "lines": lines}

proc = subprocess.run([renderer, out_png, side, "3"], input=json.dumps(card).encode())
sys.exit(proc.returncode)
PY

sketchybar --set "$NAME" \
  background.drawing=on \
  background.color=0x00000000 \
  background.corner_radius=0 \
  background.image.string="$OUT_PNG" \
  background.image.drawing=on \
  background.image.scale=0.333333 \
  background.height="$CARD_SIDE"
