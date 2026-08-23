#!/usr/bin/env sh
# Avvia la dashboard di test al posto della bar live. SketchyBar usa un unico
# mach port per utente quindi le due bar non possono girare insieme: questo
# script ferma quella gestita da brew services, lancia la config di test in
# foreground, e alla chiusura (Ctrl-C) puoi ripristinare con stop.sh.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
RC="$DIR/dashboardrc"

echo "Fermo la sketchybar live (brew services)..."
brew services stop sketchybar >/dev/null

# Aspetta che il mach port si liberi.
for _ in $(seq 1 20); do
  pgrep -x sketchybar >/dev/null || break
  sleep 0.2
done

echo "Avvio la dashboard di test: $RC"
echo "Premi Ctrl-C per fermarla, poi lancia ./stop.sh per ripristinare la bar live."
exec sketchybar -c "$RC"
