#!/bin/sh
# Aggiorna i dati WHOOP e ne archivia lo storico su GitHub.
#
# Ogni giro: lancia whoop.py, poi (se il repo di storico esiste) fa
#   git pull --rebase  ->  append deduplicato  ->  commit  ->  push
# nel repo di storico. Ogni errore di rete è non fatale: il push saltato viene
# ripreso al giro successivo.
#
# Uso:
#   whoop_archive.sh            esegue un giro di archiviazione
#   whoop_archive.sh install    installa/ricarica il LaunchAgent (ogni 30 min)
#   whoop_archive.sh uninstall  rimuove il LaunchAgent
#
# Il repo di storico va clonato in $WHOOP_HISTORY_DIR (default:
# ~/Library/Application Support/Sketchybar Health/history). Finché non c'è,
# lo script si limita ad aggiornare i dati e salta la parte git.

set -u

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SUPPORT_DIR="$HOME/Library/Application Support/Sketchybar Health"
HISTORY_DIR="${WHOOP_HISTORY_DIR:-$SUPPORT_DIR/history}"
STATE_FILE="/tmp/sketchybar_health_state.json"
LOG_FILE="/tmp/whoop_archive.log"
PLIST="$HOME/Library/LaunchAgents/com.luca.whoop-archive.plist"
LABEL="com.luca.whoop-archive"
INTERVAL=1800

# I LaunchAgent partono con un PATH minimo: fissiamo quello che serve a
# python3, git e gh (credential helper).
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_FILE"
}

install_agent() {
  mkdir -p "$(dirname "$PLIST")"
  cat >"$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>$PLUGIN_DIR/whoop_archive.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>$INTERVAL</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
</dict>
</plist>
PLISTEOF
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  echo "LaunchAgent installato: $PLIST (ogni $((INTERVAL / 60)) min)"
}

uninstall_agent() {
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "LaunchAgent rimosso."
}

archive_run() {
  # 1. aggiorna i dati (non fatale se fallisce: si usa l'ultimo stato buono)
  if ! python3 "$PLUGIN_DIR/whoop.py" >/dev/null 2>>"$LOG_FILE"; then
    log "whoop.py fallito, proseguo con lo stato esistente"
  fi
  [ -f "$STATE_FILE" ] || { log "nessuno state file, esco"; exit 0; }

  # 2. repo di storico presente?
  if [ ! -d "$HISTORY_DIR/.git" ]; then
    log "repo di storico assente in $HISTORY_DIR — salto l'archiviazione"
    exit 0
  fi
  cd "$HISTORY_DIR" || { log "cd $HISTORY_DIR fallito"; exit 0; }

  git pull --rebase --autostash --quiet 2>>"$LOG_FILE" || log "pull fallito (offline?), continuo"

  mkdir -p data
  MONTH_FILE="data/$(date -u +%Y-%m).ndjson"

  # merge=union: append concorrenti da più Mac si fondono senza conflitti
  if ! grep -qs 'data/\*.ndjson merge=union' .gitattributes; then
    printf 'data/*.ndjson merge=union\n' >>.gitattributes
    git add .gitattributes
  fi

  # 3. record deduplicato rispetto all'ultima riga del mese
  NEW_LINE=$(
    WHOOP_STATE_FILE="$STATE_FILE" WHOOP_MONTH_FILE="$MONTH_FILE" python3 - <<'PY'
import json, os, sys

state_path = os.environ["WHOOP_STATE_FILE"]
month_file = os.environ["WHOOP_MONTH_FILE"]

with open(state_path, encoding="utf-8") as handle:
    state = json.load(handle)

record = {
    "ts": state.get("updated_at"),
    "sleep": state.get("sleep"),
    "recovery": state.get("recovery"),
    "strain": state.get("strain"),
    "workouts": state.get("workouts"),
}

def core(payload):
    return {key: payload.get(key) for key in ("sleep", "recovery", "strain", "workouts")}

last = None
try:
    with open(month_file, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                last = line
except FileNotFoundError:
    pass

if last:
    try:
        if core(json.loads(last)) == core(record):
            sys.exit(9)  # nessun cambiamento: niente commit
    except json.JSONDecodeError:
        pass

sys.stdout.write(json.dumps(record, separators=(",", ":"), ensure_ascii=False))
PY
  )
  RC=$?

  if [ "$RC" -eq 9 ]; then
    log "nessun cambiamento, niente commit"
    exit 0
  fi
  if [ "$RC" -ne 0 ] || [ -z "$NEW_LINE" ]; then
    log "generazione record fallita (rc=$RC)"
    exit 0
  fi

  printf '%s\n' "$NEW_LINE" >>"$MONTH_FILE"
  git add "$MONTH_FILE"

  if git diff --cached --quiet; then
    log "diff vuoto, niente commit"
    exit 0
  fi

  STAMP=$(date -u +%Y-%m-%dT%H:%MZ)
  if ! git commit --quiet -m "health $STAMP"; then
    log "commit fallito"
    exit 0
  fi

  if git push --quiet 2>>"$LOG_FILE"; then
    log "push ok ($STAMP)"
  elif git pull --rebase --autostash --quiet 2>>"$LOG_FILE" && git push --quiet 2>>"$LOG_FILE"; then
    # Con più Mac attivi il primo push può essere rifiutato (non fast-forward):
    # un solo rebase+push lo recupera senza aspettare il giro dopo.
    log "push ok dopo rebase ($STAMP)"
  else
    log "push fallito (offline o conflitto?), verrà ripreso al prossimo giro"
  fi
}

case "${1:-run}" in
  install) install_agent ;;
  uninstall) uninstall_agent ;;
  run) archive_run ;;
  *) echo "uso: $0 [run|install|uninstall]" >&2; exit 2 ;;
esac
