#!/bin/sh

SPOTIFY_RUNNING=$(osascript -e 'application "Spotify" is running' 2>/dev/null)
MUSIC_RUNNING=$(osascript -e 'application "Music" is running' 2>/dev/null)

STATE="stopped"

if [ "$SPOTIFY_RUNNING" = "true" ]; then
  STATE=$(osascript -e 'tell application "Spotify" to get player state as string' 2>/dev/null)
elif [ "$MUSIC_RUNNING" = "true" ]; then
  STATE=$(osascript -e 'tell application "Music" to get player state as string' 2>/dev/null)
fi

if [ "$STATE" = "playing" ]; then
  sketchybar --set "$NAME" icon=󰏤   # pause
else
  sketchybar --set "$NAME" icon=󰐊   # play
fi
