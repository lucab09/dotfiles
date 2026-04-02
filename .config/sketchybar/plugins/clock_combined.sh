#!/bin/sh
sketchybar --set "$NAME" \
  icon="$(date '+%I:%M:%S %p')" \
  label="$(date '+%A, %B %-d')"
