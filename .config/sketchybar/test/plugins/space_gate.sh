#!/bin/sh
# La finestra della bar esiste comunque su ogni scrivania (non confinabile),
# e anche invisibile intercetta i click nella sua area. Prima tentavamo di
# restringere l'altezza (--bar height=1) fuori dalla scrivania target, ma
# ridimensionare da 1px a piena altezza causava un frame "a bande" (il
# sistema stira il vecchio backing store durante il resize). Qui invece
# l'altezza resta SEMPRE fissa e spostiamo l'intera finestra sopra lo
# schermo con y_offset: è una traslazione rigida, non un resize, quindi
# nessuno stretch del contenuto — e comunque non intercetta più click
# perché il suo frame non interseca più lo schermo visibile.
# Chiamato dal segnale yabai space_changed (passa YABAI_SPACE_INDEX) e
# manualmente all'avvio per sincronizzare lo stato iniziale.
TARGET_SPACE="${TARGET_SPACE:-1}"
HEIGHT_FILE="/tmp/sketchybar_test_bar_height"
FULL_HEIGHT=$(cat "$HEIGHT_FILE" 2>/dev/null || echo 466)
OFFSCREEN_OFFSET=$((FULL_HEIGHT + 100))

if [ "$YABAI_SPACE_INDEX" = "$TARGET_SPACE" ]; then
  sketchybar --bar y_offset=0
else
  sketchybar --bar y_offset=-"$OFFSCREEN_OFFSET"
fi
