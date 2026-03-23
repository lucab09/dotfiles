#!/bin/sh

ACTION=$1

SPOTIFY_RUNNING=$(osascript -e 'application "Spotify" is running' 2>/dev/null)
MUSIC_RUNNING=$(osascript -e 'application "Music" is running' 2>/dev/null)

case "$ACTION" in
  prev)
    if [ "$SPOTIFY_RUNNING" = "true" ]; then
      osascript -e 'tell application "Spotify" to previous track'
    elif [ "$MUSIC_RUNNING" = "true" ]; then
      osascript -e 'tell application "Music" to back track'
    fi
    ;;
  next)
    if [ "$SPOTIFY_RUNNING" = "true" ]; then
      osascript -e 'tell application "Spotify" to next track'
    elif [ "$MUSIC_RUNNING" = "true" ]; then
      osascript -e 'tell application "Music" to next track'
    fi
    ;;
  toggle)
    if [ "$SPOTIFY_RUNNING" = "true" ]; then
      osascript -e 'tell application "Spotify" to playpause'
    elif [ "$MUSIC_RUNNING" = "true" ]; then
      osascript -e 'tell application "Music" to playpause'
    fi
    ;;
esac

# Aggiorna subito l'icona play/pause e la canzone
sleep 0.3
sketchybar --trigger media_change
