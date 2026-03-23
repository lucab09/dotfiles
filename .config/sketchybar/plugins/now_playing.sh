#!/bin/sh

# Controlla Spotify
SPOTIFY_RUNNING=$(osascript -e 'application "Spotify" is running' 2>/dev/null)
if [ "$SPOTIFY_RUNNING" = "true" ]; then
  STATE=$(osascript -e 'tell application "Spotify" to get player state as string' 2>/dev/null)
  if [ "$STATE" = "playing" ]; then
    TRACK=$(osascript -e 'tell application "Spotify" to get name of current track' 2>/dev/null)
    ARTIST=$(osascript -e 'tell application "Spotify" to get artist of current track' 2>/dev/null)
    sketchybar --set "$NAME" label="${ARTIST} - ${TRACK}" drawing=on
    exit 0
  fi
fi

# Controlla Music
MUSIC_RUNNING=$(osascript -e 'application "Music" is running' 2>/dev/null)
if [ "$MUSIC_RUNNING" = "true" ]; then
  STATE=$(osascript -e 'tell application "Music" to get player state as string' 2>/dev/null)
  if [ "$STATE" = "playing" ]; then
    TRACK=$(osascript -e 'tell application "Music" to get name of current track' 2>/dev/null)
    ARTIST=$(osascript -e 'tell application "Music" to get artist of current track' 2>/dev/null)
    sketchybar --set "$NAME" label="${ARTIST} - ${TRACK}" drawing=on
    exit 0
  fi
fi

sketchybar --set "$NAME" drawing=off
