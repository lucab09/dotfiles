#!/bin/sh

PERCENTAGE="$(pmset -g batt | grep -Eo "\d+%" | cut -d% -f1)"
CHARGING="$(pmset -g batt | grep 'AC Power')"

if [ "$PERCENTAGE" = "" ]; then
  exit 0
fi

case "${PERCENTAGE}" in
  9[0-9]|100) ICON="󰁹"
  ;;
  [6-8][0-9]) ICON="󰂀"
  ;;
  [3-5][0-9]) ICON="󰁾"
  ;;
  [1-2][0-9]) ICON="󰁼"
  ;;
  *) ICON="󰁺"
esac

if [[ "$CHARGING" != "" ]]; then
  ICON="󰂄"
fi

COLOR=0xffa6e3a1
if [[ "$PERCENTAGE" -lt 20 ]] && [[ "$CHARGING" == "" ]]; then
  COLOR=0xffff5555
fi

sketchybar --set "$NAME" icon="$ICON" icon.color="$COLOR" label="${PERCENTAGE}%"
