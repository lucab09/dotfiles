#!/bin/sh
# Widget orologio per il test dashboard.
sketchybar --set "$NAME" label="$(date '+%a %-d %b  ·  %H:%M')"
