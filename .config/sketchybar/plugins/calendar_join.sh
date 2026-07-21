#!/bin/sh

STATE_FILE="/tmp/sketchybar_calendar_state.json"

URL=$(python3 -c "
import json
try:
    d = json.load(open('$STATE_FILE'))
except Exception:
    d = {}
print(d.get('meeting_url', ''))
" 2>/dev/null)

[ -n "$URL" ] && open "$URL"
