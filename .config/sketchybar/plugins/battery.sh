#!/bin/sh

PERCENTAGE="$(pmset -g batt | grep -Eo "\d+%" | cut -d% -f1)"
CHARGING="$(pmset -g batt | grep 'AC Power')"

if [ "$PERCENTAGE" = "" ]; then
  exit 0
fi

# FG = colore acceso per icona/testo. BG = la stessa tinta miscelata al 16%
# sul grigio scuro degli altri widget (0xff49454f), come risulterebbe un
# tint traslucido — ma come unico strato pieno, senza doppio sfondo.
if [ "$PERCENTAGE" -ge 85 ]; then
  FG_RGB=79d491
  BG_RGB=515c5a
elif [ "$PERCENTAGE" -ge 25 ]; then
  FG_RGB=f2c14e
  BG_RGB=64594f
else
  FG_RGB=cf6679
  BG_RGB=5e4a56
fi

if [ "$PERCENTAGE" -ge 88 ]; then
  BATTERY_ICON="battery_full_alt"
elif [ "$PERCENTAGE" -ge 63 ]; then
  BATTERY_ICON="battery_horiz_075"
elif [ "$PERCENTAGE" -ge 25 ]; then
  BATTERY_ICON="battery_horiz_050"
else
  BATTERY_ICON="battery_horiz_000"
fi

# Material Symbols non ha una variante "in carica" della famiglia
# orizzontale: mostriamo solo il fulmine invece della sagoma verticale
# di default.
if [ -n "$CHARGING" ]; then
  ICON="bolt"
else
  ICON="$BATTERY_ICON"
fi

sketchybar --set "$NAME" icon="$ICON" label="${PERCENTAGE}%" \
  icon.color="0xff${FG_RGB}" label.color="0xff${FG_RGB}" background.color="0xff${BG_RGB}"
