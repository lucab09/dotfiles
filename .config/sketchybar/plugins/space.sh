#!/bin/sh

if [ "$SELECTED" = "true" ]; then
  sketchybar --set "$NAME" \
    background.drawing=on \
    background.color=0xff89b4fa \
    icon.color=0xff1a1b26
else
  sketchybar --set "$NAME" \
    background.drawing=on \
    background.color=0xff313244 \
    icon.color=0xffcdd6f4
fi
