#!/bin/sh
# Trigger della cattura vocale dalla barra (o da una shortcut).
#
# Primo click: alza il flag di "modalità task" e avvia la registrazione di Handy.
# Secondo click: chiude la registrazione, nemotron trascrive e Handy consegna il
# testo a handy_capture.sh, che crea il task.
set -u

HANDY="/Applications/Handy.app/Contents/MacOS/handy"
STATE_FILE="/tmp/handy_capture_state"
FLAG_FILE="/tmp/handy_task_capture.flag"
LOG_FILE="/tmp/handy_capture.log"
# Uno stato appeso (Handy chiuso a metà registrazione, crash, sleep del Mac) non
# deve bloccare l'icona per sempre.
STALE_SECONDS=300

log() {
  printf '%s handy_task: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" >>"$LOG_FILE"
}

state="idle"
if [ -f "$STATE_FILE" ]; then
  state=$(cat "$STATE_FILE" 2>/dev/null || echo idle)
  age=$(( $(date +%s) - $(stat -f %m "$STATE_FILE" 2>/dev/null || echo 0) ))
  if [ "$age" -gt "$STALE_SECONDS" ]; then
    log "stato '$state' scaduto dopo ${age}s, torno a idle"
    state="idle"
  fi
fi

case "$state" in
  recording)
    printf 'processing' >"$STATE_FILE"
    "$HANDY" --toggle-transcription
    log "registrazione chiusa, trascrizione in corso"
    ;;
  *)
    if ! pgrep -f 'Handy.app/Contents/MacOS/handy' >/dev/null 2>&1; then
      log "Handy non è in esecuzione: lo avvio, riclicca per registrare"
      open -gj -a Handy
      printf 'idle' >"$STATE_FILE"
      exit 0
    fi
    : >"$FLAG_FILE"
    printf 'recording' >"$STATE_FILE"
    "$HANDY" --toggle-transcription
    log "registrazione avviata in modalità task"
    ;;
esac
