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
    minutes = d.get('remaining_minutes', 0)
    if minutes < 60:
        duration = f'{minutes}m'
    else:
        duration = f'{minutes // 60}h e {minutes % 60}m'
    print('1|' + d.get('title', 'Evento') + '|' + d.get('color', '0xff89b4fa') + '|' + duration + '|' + ('1' if d.get('in_progress') else '0'))
else:
    print('0||||')
" 2>/dev/null)

HAS_EVENT=$(echo "$STATE" | cut -d'|' -f1)
TITLE=$(echo "$STATE" | cut -d'|' -f2)
COLOR=$(echo "$STATE" | cut -d'|' -f3)
DURATION=$(echo "$STATE" | cut -d'|' -f4)
IN_PROGRESS=$(echo "$STATE" | cut -d'|' -f5)

if [ "$HAS_EVENT" = "1" ]; then
  if [ "$IN_PROGRESS" = "1" ]; then
    sketchybar --set "$NAME" icon.color="$COLOR" label="${TITLE} · ${DURATION}"
  else
    sketchybar --set "$NAME" icon.color="$COLOR" label="${TITLE} · tra ${DURATION}"
  fi
else
  sketchybar --set "$NAME" icon.color=0x44cdd6f4 label="Nessun evento"
fi
