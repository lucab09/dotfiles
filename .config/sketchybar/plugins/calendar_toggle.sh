#!/bin/sh

# Click sul widget calendario (tranne il bottone "Partecipa", che ha il suo
# click_script separato): apre/chiude il popup con l'agenda. Sostituisce il
# vecchio show/hide su hover, che su questa macchina generava enter/exit
# spuri in rapida sequenza (probabilmente per via del re-layout del bracket
# calendar_pill ad ogni aggiornamento di calendar.sh) causando un loop di
# apri/chiudi continuo.
SOCK="/tmp/calendar_notch.sock"
echo "toggle" | nc -U "$SOCK" 2>/dev/null || true
