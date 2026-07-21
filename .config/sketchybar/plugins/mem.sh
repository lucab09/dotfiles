#!/bin/sh
TOTAL=$(sysctl -n hw.memsize)
PAGE_SIZE=$(pagesize)
STATS=$(vm_stat)
ACTIVE=$(echo "$STATS" | awk '/Pages active/ {gsub(/\./,"",$3); print $3}')
WIRED=$(echo "$STATS" | awk '/Pages wired down/ {gsub(/\./,"",$4); print $4}')
COMPRESSED=$(echo "$STATS" | awk '/occupied by compressor/ {gsub(/\./,"",$5); print $5}')
USED_BYTES=$(( (ACTIVE + WIRED + COMPRESSED) * PAGE_SIZE ))
MEM=$(awk -v u="$USED_BYTES" -v t="$TOTAL" 'BEGIN{printf "%.0f", u/t*100}')
FRAC=$(awk -v m="$MEM" 'BEGIN{printf "%.2f", m/100}')

sketchybar --set "$NAME" label="${MEM}%" \
           --push "${NAME}_graph" "$FRAC"
