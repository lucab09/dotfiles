#!/bin/sh

STATE_FILE="/tmp/sketchybar_calendar_state.json"
SOCK="/tmp/calendar_notch.sock"

case "$SENDER" in
  mouse.entered)
    echo "show" | nc -U "$SOCK" 2>/dev/null || true
    ;;
  mouse.exited)
    echo "hide" | nc -U "$SOCK" 2>/dev/null || true
    ;;
esac

STATE=$(python3 -c "
import json
try:
    d = json.load(open('$STATE_FILE'))
except Exception:
    d = {}
if d.get('has_event'):
    print('1|' + d.get('title', 'Evento') + '|' + d.get('color', '0xff89b4fa') + '|' + str(d.get('remaining_minutes', 0)))
else:
    print('0|||')
" 2>/dev/null)

HAS_EVENT=$(echo "$STATE" | cut -d'|' -f1)
TITLE=$(echo "$STATE" | cut -d'|' -f2)
COLOR=$(echo "$STATE" | cut -d'|' -f3)
REMAINING=$(echo "$STATE" | cut -d'|' -f4)

if [ "$HAS_EVENT" = "1" ]; then
  sketchybar --set "$NAME" icon.color="$COLOR" label="${TITLE} · ${REMAINING}m"
else
  sketchybar --set "$NAME" icon.color=0x44cdd6f4 label="Nessun evento"
fi
