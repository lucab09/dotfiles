#!/usr/bin/env bash
set -euo pipefail

for file in /tmp/sketchybar_swift_bar.pid /tmp/sketchybar_swift_battery_bar.pid; do
  if [ -f "$file" ]; then
    kill "$(cat "$file")" 2>/dev/null || true
    rm -f "$file"
  fi
done

pkill -f '/swift_bar$' 2>/dev/null || true
pkill -f '/tmp/sketchybar_swift_battery_bar$' 2>/dev/null || true
echo "Barra Swift arrestata."
