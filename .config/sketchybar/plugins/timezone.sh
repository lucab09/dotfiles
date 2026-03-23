#!/bin/sh

WIDGET="$HOME/.config/sketchybar/plugins/timezone_widget"
PID_FILE="/tmp/sketchybar_tz_widget.pid"

# Toggle: se il widget è aperto, chiudilo; altrimenti aprilo
if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE")
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID"
    rm "$PID_FILE"
    exit 0
  fi
  rm "$PID_FILE"
fi

"$WIDGET" &
echo $! > "$PID_FILE"
