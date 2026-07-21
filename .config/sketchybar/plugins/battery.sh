#!/bin/sh

PERCENTAGE="$(pmset -g batt | grep -Eo "\d+%" | cut -d% -f1)"
CHARGING="$(pmset -g batt | grep 'AC Power')"

if [ "$PERCENTAGE" = "" ]; then
  exit 0
fi

GREEN=0xff79d491
YELLOW=0xfff2c94c
RED=0xffcf6679

if [ "$PERCENTAGE" -ge 85 ]; then
  COLOR=$GREEN
elif [ "$PERCENTAGE" -ge 25 ]; then
  COLOR=$YELLOW
else
  COLOR=$RED
fi

if [[ "$CHARGING" != "" ]]; then
  ICON="battery_charging_full"
elif [ "$PERCENTAGE" -ge 88 ]; then
  ICON="battery_full_alt"
elif [ "$PERCENTAGE" -ge 63 ]; then
  ICON="battery_horiz_075"
elif [ "$PERCENTAGE" -ge 25 ]; then
  ICON="battery_horiz_050"
else
  ICON="battery_horiz_000"
fi

sketchybar --set "$NAME" icon="$ICON" icon.color="$COLOR" label="${PERCENTAGE}%"
