#!/bin/sh

PERCENTAGE="$(pmset -g batt | grep -Eo "\d+%" | cut -d% -f1)"
CHARGING="$(pmset -g batt | grep 'AC Power')"

if [ "$PERCENTAGE" = "" ]; then
  exit 0
fi

if [[ "$CHARGING" != "" ]]; then
  ICON="battery_charging_full"
  COLOR=0xff79d491
elif [ "$PERCENTAGE" -ge 90 ]; then
  ICON="battery_full"
  COLOR=0xffcac4d0
elif [ "$PERCENTAGE" -ge 70 ]; then
  ICON="battery_6_bar"
  COLOR=0xffcac4d0
elif [ "$PERCENTAGE" -ge 50 ]; then
  ICON="battery_4_bar"
  COLOR=0xffcac4d0
elif [ "$PERCENTAGE" -ge 30 ]; then
  ICON="battery_3_bar"
  COLOR=0xffcac4d0
elif [ "$PERCENTAGE" -ge 20 ]; then
  ICON="battery_2_bar"
  COLOR=0xffcac4d0
elif [ "$PERCENTAGE" -ge 10 ]; then
  ICON="battery_1_bar"
  COLOR=0xffcf6679
else
  ICON="battery_alert"
  COLOR=0xffcf6679
fi

sketchybar --set "$NAME" icon="$ICON" icon.color="$COLOR" label="${PERCENTAGE}%"
