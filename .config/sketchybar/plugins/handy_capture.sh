#!/bin/sh
# Hook esterno di Handy (paste_method = external_script): Handy esegue questo
# script con il transcript come $1, con stdio su /dev/null, e attende l'exit
# status — quindi qui dentro si fa solo lavoro veloce.
#
# Due modalità, distinte dal flag alzato da handy_task.sh:
#   - flag presente  -> la registrazione arriva dalla barra: creo un task
#   - flag assente   -> dettatura normale: incollo nell'app in focus come farebbe Handy
set -u

TRANSCRIPT=${1:-}
FLAG_FILE="/tmp/handy_task_capture.flag"
STATE_FILE="/tmp/handy_capture_state"
LOG_FILE="/tmp/handy_capture.log"
DB="$HOME/.local/share/pmmgmt/tasks.db"
ORPHAN_DIR="$HOME/.local/share/pmmgmt/voice_orphans"

log() {
  printf '%s handy_capture: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" >>"$LOG_FILE"
}

# --- Dettatura normale ------------------------------------------------------
if [ ! -f "$FLAG_FILE" ]; then
  previous=$(pbpaste 2>/dev/null || printf '')
  printf '%s' "$TRANSCRIPT" | pbcopy

  # L'invio di ⌘V richiede il permesso Accessibilità: se manca, non si perde il
  # testo — resta in clipboard e la notifica dice cosa fare.
  if paste_error=$(osascript -e 'tell application "System Events" to keystroke "v" using command down' 2>&1); then
    # La clipboard torna al contenuto precedente (come clipboard_handling
    # "dont_modify" di Handy) senza far attendere Handy: il ripristino avviene
    # in background, dopo che l'incollaggio è andato a segno.
    if [ -n "$previous" ]; then
      ( sleep 0.6; printf '%s' "$previous" | pbcopy ) >/dev/null 2>&1 &
    fi
  else
    log "incollaggio non riuscito ($paste_error): testo lasciato in clipboard"
    osascript -e 'display notification "Trascrizione in clipboard: premi ⌘V" with title "Handy"' >/dev/null 2>&1
  fi
  exit 0
fi

# --- Modalità task ----------------------------------------------------------
rm -f "$FLAG_FILE"

summary=$(printf '%s' "$TRANSCRIPT" | tr '\n\t' '  ' | sed 's/   */ /g; s/^ *//; s/ *$//')
if [ -z "$summary" ]; then
  log "transcript vuoto, nessun task creato"
  printf 'idle' >"$STATE_FILE"
  exit 0
fi

# Il titolo è un troncamento del transcript a 60 caratteri su confine di parola:
# è un segnaposto, il passo di processing con Claude lo riscriverà.
if [ ${#summary} -gt 60 ]; then
  name="$(printf '%s' "$summary" | cut -c1-60 | sed 's/ [^ ]*$//')…"
else
  name="$summary"
fi

now="$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/\(..\)$/:\1/')"

esc() { printf '%s' "$1" | sed "s/'/''/g"; }

task_id=$(sqlite3 "$DB" "INSERT INTO tasks (name, description, deadline, tags, status, created_at, updated_at) VALUES ('$(esc "$name")', '$(esc "$TRANSCRIPT")', NULL, '[\"voice\",\"raw\"]', 'todo', '$now', '$now'); SELECT last_insert_rowid();" 2>>"$LOG_FILE")

if [ -z "$task_id" ]; then
  # Un transcript non deve mai andare perso perché il DB non era scrivibile.
  mkdir -p "$ORPHAN_DIR"
  printf '%s\n' "$TRANSCRIPT" >"$ORPHAN_DIR/$(date '+%Y%m%dT%H%M%S').txt"
  log "INSERT fallito, transcript salvato in $ORPHAN_DIR"
  printf 'idle' >"$STATE_FILE"
  exit 1
fi

log "task #$task_id creato ($(printf '%s' "$summary" | wc -c | tr -d ' ') byte)"
printf 'saved' >"$STATE_FILE"
( sleep 2.5; [ "$(cat "$STATE_FILE" 2>/dev/null)" = "saved" ] && printf 'idle' >"$STATE_FILE" ) >/dev/null 2>&1 &
exit 0
