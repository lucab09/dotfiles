#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$DIR/SwiftBar.swift"
CARD_COMPONENT="$DIR/../components/Card.swift"
BINARY="$DIR/swift_bar"
PID_FILE="/tmp/sketchybar_swift_bar.pid"
LEGACY_PID_FILE="/tmp/sketchybar_swift_battery_bar.pid"
LOG_FILE="/tmp/sketchybar_swift_bar.log"

for file in "$PID_FILE" "$LEGACY_PID_FILE"; do
  if [ -f "$file" ]; then
    kill "$(cat "$file")" 2>/dev/null || true
    rm -f "$file"
  fi
done
pkill -f '/tmp/sketchybar_swift_battery_bar$' 2>/dev/null || true

if [ ! -x "$BINARY" ] || [ "$SOURCE" -nt "$BINARY" ] || [ "$CARD_COMPONENT" -nt "$BINARY" ]; then
  "$DIR/build.sh" >>"$LOG_FILE" 2>&1
fi

nohup "$BINARY" >>"$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
sleep 0.4

if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "La barra Swift non è partita. Log: $LOG_FILE" >&2
  tail -100 "$LOG_FILE" >&2
  exit 1
fi

echo "Barra Swift avviata (PID $(cat "$PID_FILE"))."
