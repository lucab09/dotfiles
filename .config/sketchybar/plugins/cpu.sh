#!/bin/sh
LINE=$(top -l 1 -n 0 -stats cpu | grep "CPU usage")
USER=$(echo "$LINE" | awk '{print $3}' | tr -d '%')
SYS=$(echo "$LINE" | awk '{print $5}' | tr -d '%')
CPU=$(awk -v u="${USER:-0}" -v s="${SYS:-0}" 'BEGIN{printf "%.0f", u+s}')
FRAC=$(awk -v c="$CPU" 'BEGIN{printf "%.2f", c/100}')

sketchybar --set "$NAME" label="${CPU}%" \
           --push "${NAME}_graph" "$FRAC"
