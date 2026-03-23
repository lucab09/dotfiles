#!/bin/sh

TEMP=$(curl -sf "wttr.in/Milan?format=%t" | tr -d '+')
COND=$(curl -sf "wttr.in/Milan?format=%C")

if [ -n "$TEMP" ] && [ -n "$COND" ]; then
  sketchybar --set "$NAME" label="${TEMP} • ${COND}"
else
  sketchybar --set "$NAME" label="--"
fi
