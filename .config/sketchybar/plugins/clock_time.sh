#!/bin/sh

SECOND=$(date '+%S')
if [ $((10#$SECOND % 2)) -eq 0 ]; then
  SEP=":"
else
  SEP=" "
fi

sketchybar --set "$NAME" label="$(date '+%H')${SEP}$(date '+%M')"
