#!/bin/sh
# Card meteo quadrata, allineata al widget meteo di produzione
# (.config/sketchybar/plugins/weather.sh): stessi dati, stesso refresh
# (state file condiviso, riusa quello script per il fetch). Icona: stesso
# set "ben definito" usato ovunque nella bar (cpu.sh/mem.sh/vpn.sh) — font
# Material Symbols Rounded con il nome icona direttamente dallo state
# (weather.sh calcola già la categoria come nome icona valido, es.
# "partly_cloudy_night"), non più i glifi Unicode custom usati prima.
# Sfondo statico #252422, stesso colore della card orologio (design system
# condiviso, non più il gradiente per temperatura). Il rendering
# pixel-preciso è delegato a card_render.
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

glyph = s.get('icon', 'cloud')
glyph_font = 'Material Symbols Rounded'
icon_color = s.get('icon_color') or '0xffcac4d0'
background = '0xff252422'

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
    [{"t": "percepiti ", "b": False}, {"t": fmt(feels), "b": True, "color": icon_color}],
    [{"t": glyph, "font": glyph_font, "color": icon_color}, {"t": " " + condition, "b": True}],
]
if isinstance(humidity, (int, float)):
    lines.append([{"t": "umidità ", "b": False}, {"t": f"{humidity}%", "b": True}])

card = {"background": background, "lines": lines}

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
