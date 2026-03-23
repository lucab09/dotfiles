#!/bin/sh

COUNT=$(osascript -e '
tell application "System Events"
  if exists process "Slack" then
    tell process "Slack"
      set badge to value of attribute "AXStatusLabel" of UI element 1 of dock item "Slack" of application "Finder"
    end tell
  end if
end tell
' 2>/dev/null)

# Fallback: leggi il badge dal Dock
if [ -z "$COUNT" ]; then
  COUNT=$(osascript -e '
    tell application "System Events"
      tell UI element "Slack" of list 1 of process "Dock"
        set badgeValue to value of attribute "AXStatusLabel"
      end tell
    end tell
  ' 2>/dev/null)
fi

if [ -z "$COUNT" ] || [ "$COUNT" = "null" ]; then
  sketchybar --set "$NAME" icon.color=0xffcdd6f4 label.drawing=off
else
  sketchybar --set "$NAME" icon.color=0xfffb938f label.drawing=on label="$COUNT"
fi
