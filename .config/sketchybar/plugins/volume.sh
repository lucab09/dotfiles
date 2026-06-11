#!/bin/sh

if [ "$SENDER" = "volume_change" ]; then
  VOLUME="$INFO"

  case "$VOLUME" in
    [6-9][0-9]|100) ICON="volume_up" ;;
    [1-5][0-9])     ICON="volume_down" ;;
    [1-9])          ICON="volume_down" ;;
    *)              ICON="volume_off" ;;
  esac

  sketchybar --set "$NAME" icon="$ICON" label="$VOLUME%"
fi
