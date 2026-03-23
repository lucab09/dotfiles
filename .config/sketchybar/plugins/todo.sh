#!/bin/sh
DB="$HOME/.local/share/pmmgmt/tasks.db"

if [ ! -f "$DB" ]; then
  sketchybar --set "$NAME" label.drawing=off
  exit 0
fi

COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM tasks WHERE DATE(deadline) <= DATE('now', 'localtime') AND status != 'done';")

if [ -z "$COUNT" ] || [ "$COUNT" = "0" ]; then
  sketchybar --set "$NAME" icon.color=0xffcdd6f4 label.drawing=off
else
  sketchybar --set "$NAME" icon.color=0xfffb938f label.drawing=on label="$COUNT"
fi
