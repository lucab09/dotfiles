#!/usr/bin/env sh
# Ferma un'eventuale dashboard di test rimasta appesa e ripristina la bar
# live gestita da brew services (sketchybarrc "vero").
pkill -x sketchybar 2>/dev/null
sleep 0.3
echo "Ripristino la sketchybar live (brew services)..."
brew services start sketchybar >/dev/null
echo "Fatto."
