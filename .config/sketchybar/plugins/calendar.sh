#!/bin/sh

# Aggiorna periodicamente label/colore del widget. Il popup con l'agenda si
# apre/chiude con un click sul widget (vedi calendar_toggle.sh), non piu' su
# hover. Il bottone "Partecipa" non vive piu' qui: lo disegna direttamente la
# barra Swift (CalendarJoinButton in swift_bar/SwiftBar.swift), che legge lo
# stesso stato JSON.
#
# Tutto l'aggiornamento è delegato a Python, che chiama `sketchybar`
# direttamente come subprocess: passare i valori (titolo dell'evento
# incluso) come argv evita di dover ricostruire/spezzare una stringa
# unita da un delimitatore in shell, che si rompe se il titolo contiene
# quel carattere (es. "Sync | 1:1").
NAME="$NAME" python3 - <<'PY'
import json
import os
import subprocess

STATE_FILE = "/tmp/sketchybar_calendar_state.json"
NAME = os.environ["NAME"]

try:
    with open(STATE_FILE) as f:
        d = json.load(f)
except Exception:
    d = {}


def sketchybar(*args):
    subprocess.run(["sketchybar", *args])


if not d.get("has_event"):
    sketchybar("--set", NAME, "icon.color=0x44cdd6f4", "label=Nessun evento")
    raise SystemExit

minutes = d.get("remaining_minutes", 0)
duration = f"{minutes}m" if minutes < 60 else f"{minutes // 60}h e {minutes % 60}m"
title = d.get("title", "Evento")
color = d.get("color", "0xff89b4fa")
in_progress = bool(d.get("in_progress"))
meeting_url = d.get("meeting_url", "")

if in_progress:
    # In corso con link alla videochiamata: il countdown si sposta nel
    # bottone ("Termina tra Xm"), qui resta solo il titolo.
    label = title if meeting_url else f"{title} · {duration}"
else:
    label = f"{title} · tra {duration}"

sketchybar("--set", NAME, f"icon.color={color}", f"label={label}")

PY
