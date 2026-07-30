#!/bin/sh

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
POPUP="$PLUGIN_DIR/weather_popup"

if pgrep -f "^$POPUP$" >/dev/null 2>&1; then
  pkill -f "^$POPUP$"
  exit 0
fi

[ -x "$POPUP" ] && "$POPUP" >/dev/null 2>&1 &
