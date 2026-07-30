#!/bin/sh

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
POPUP="$PLUGIN_DIR/weather_popup"

case "$SENDER" in
  mouse.entered)
    if ! pgrep -f "^$POPUP$" >/dev/null 2>&1; then
      [ -x "$POPUP" ] && "$POPUP" >/dev/null 2>&1 &
    fi
    ;;
  mouse.exited)
    # The popup process owns hover dismissal: this avoids flicker while moving
    # from the bar chip into the popup container.
    ;;
esac
