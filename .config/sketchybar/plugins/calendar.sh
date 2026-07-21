#!/bin/sh

# Aggiorna periodicamente label/colore del widget e la visibilità del
# bottone "Partecipa". Il popup con l'agenda si apre/chiude con un click
# sul widget (vedi calendar_toggle.sh), non più su hover.
STATE_FILE="/tmp/sketchybar_calendar_state.json"

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
    ends_in = d.get('ends_in_minutes')
    print('1|' + d.get('title', 'Evento') + '|' + d.get('color', '0xff89b4fa') + '|' + duration + '|' + ('1' if d.get('in_progress') else '0') + '|' + d.get('meeting_url', '') + '|' + d.get('meeting_color', '') + '|' + (str(ends_in) if ends_in is not None else ''))
else:
    print('0|||||||')
" 2>/dev/null)

HAS_EVENT=$(echo "$STATE" | cut -d'|' -f1)
TITLE=$(echo "$STATE" | cut -d'|' -f2)
COLOR=$(echo "$STATE" | cut -d'|' -f3)
DURATION=$(echo "$STATE" | cut -d'|' -f4)
IN_PROGRESS=$(echo "$STATE" | cut -d'|' -f5)
MEETING_URL=$(echo "$STATE" | cut -d'|' -f6)
MEETING_COLOR=$(echo "$STATE" | cut -d'|' -f7)
ENDS_IN=$(echo "$STATE" | cut -d'|' -f8)

if [ "$HAS_EVENT" = "1" ]; then
  if [ "$IN_PROGRESS" = "1" ]; then
    if [ -n "$MEETING_URL" ]; then
      # In corso con link alla videochiamata: il countdown si sposta nel
      # bottone ("Termina tra Xm"), qui resta solo il titolo.
      sketchybar --set "$NAME" icon.color="$COLOR" label="${TITLE}"
    else
      sketchybar --set "$NAME" icon.color="$COLOR" label="${TITLE} · ${DURATION}"
    fi
  else
    sketchybar --set "$NAME" icon.color="$COLOR" label="${TITLE} · tra ${DURATION}"
  fi
else
  sketchybar --set "$NAME" icon.color=0x44cdd6f4 label="Nessun evento"
fi

# Bottone "Partecipa"/"Termina tra Xm" — visibile solo quando l'evento in
# primo piano ha un link alla videochiamata (finestra: da 5 minuti prima a
# 15 minuti dopo l'inizio, gestita da calendar_notch tramite `spotlightEvent`).
# Colore = brand del provider (verde Meet, blu Zoom, viola Teams), stesso
# trattamento del bottone "Partecipa" nell'agenda espansa.
if [ -n "$MEETING_URL" ]; then
  BUTTON_COLOR="${MEETING_COLOR:-$COLOR}"
  if [ "$IN_PROGRESS" = "1" ]; then
    BUTTON_LABEL="Termina tra ${ENDS_IN}m"
  else
    BUTTON_LABEL="Partecipa"
  fi
  sketchybar --set calendar_join drawing=on label="$BUTTON_LABEL" \
    label.color="$BUTTON_COLOR" background.color="0x29${BUTTON_COLOR#0xff}"
else
  sketchybar --set calendar_join drawing=off
fi
