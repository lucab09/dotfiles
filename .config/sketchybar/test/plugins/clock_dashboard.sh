#!/bin/sh
# Card orologio: ora grande in bold, mese/giorno sotto, anno/settimana in
# light in fondo. Renderizzata come immagine (come weather_card.sh) per
# poter mescolare pesi/font e allineamento sx/dx sulla stessa riga.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_PNG="/tmp/sketchybar_clock_card.png"
CARD_SIDE="${1:-280}"
BACKGROUND="0xff252422"

python3 - "$OUT_PNG" "$CARD_SIDE" "$DIR/clock_card_render" "$BACKGROUND" <<'PY'
import json, subprocess, sys, locale
from datetime import datetime

out_png, side, renderer, background = sys.argv[1:5]

try:
    locale.setlocale(locale.LC_TIME, "it_IT.UTF-8")
except locale.Error:
    pass

now = datetime.now()
card = {
    "background": background,
    "time": now.strftime("%H:%M"),
    "month": now.strftime("%B").capitalize(),
    "day": now.strftime("%-d"),
    "year": now.strftime("%Y"),
    "week": now.strftime("%V"),
}

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
