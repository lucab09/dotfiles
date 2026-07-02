#!/bin/sh

if [ "$SENDER" = "front_app_switched" ]; then
  APP="$INFO"

  case "$APP" in
    "Safari")                ICON="󰀹" ;;
    "Firefox")               ICON="󰈹" ;;
    "Google Chrome")         ICON="󰊯" ;;
    "Arc")                   ICON="󰊯" ;;
    "Brave Browser")         ICON="󰊯" ;;
    "Terminal")              ICON="" ;;
    "WezTerm")               ICON="" ;;
    "iTerm2")                ICON="" ;;
    "Alacritty")             ICON="" ;;
    "Code"|"Visual Studio Code") ICON="󰨞" ;;
    "Xcode")                 ICON="" ;;
    "Cursor")                ICON="󰨞" ;;
    "Finder")                ICON="" ;;
    "Music")                 ICON="󰎇" ;;
    "Spotify")               ICON="" ;;
    "Mail")                  ICON="󰇮" ;;
    "Messages")              ICON="󰍦" ;;
    "Discord")               ICON="󰙯" ;;
    "Notion")                ICON="" ;;
    "Obsidian")              ICON="" ;;
    "Calendar")              ICON="󰃭" ;;
    "Notes")                 ICON="󰠮" ;;
    "Photos")                ICON="󰒍" ;;
    "Figma")                 ICON="" ;;
    "System Settings"|"System Preferences") ICON="󰒓" ;;
    "Activity Monitor")      ICON="󰄪" ;;
    "App Store")             ICON="" ;;
    "Preview")               ICON="" ;;
    *)                       ICON="󰣆" ;;
  esac

  sketchybar --set "$NAME" icon="$ICON" label="$APP"
fi
