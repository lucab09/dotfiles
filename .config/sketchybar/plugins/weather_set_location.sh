#!/bin/sh

# Ask for city name
CITY=$(osascript -e 'text returned of (display dialog "Inserisci la città:" default answer "" with title "Meteo" buttons {"Annulla", "Cerca"} default button "Cerca" cancel button "Annulla")' 2>/dev/null)
[ -z "$CITY" ] && exit 0

# URL-encode city name
ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$CITY")

# Geocode via Open-Meteo (free, no API key)
RESULTS=$(curl -sf "https://geocoding-api.open-meteo.com/v1/search?name=${ENCODED}&count=5&language=it&format=json")

COUNT=$(echo "$RESULTS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('results', [])))" 2>/dev/null)

if [ -z "$COUNT" ] || [ "$COUNT" -eq 0 ]; then
  osascript -e 'display alert "Città non trovata" message "Prova con un nome diverso."'
  exit 0
fi

# Build list of candidates
CHOICES=$(echo "$RESULTS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('results', []):
    parts = [r['name'], r.get('admin1', ''), r.get('country', '')]
    print(', '.join(p for p in parts if p))
")

if [ "$COUNT" -eq 1 ]; then
  CHOICE=$(echo "$CHOICES" | head -1)
else
  # Let user pick from list
  CHOICE=$(osascript 2>/dev/null <<APPLESCRIPT
set choiceList to paragraphs of "$CHOICES"
set chosen to choose from list choiceList with prompt "Seleziona la città:" default items {item 1 of choiceList} with title "Meteo"
if chosen is false then return ""
return item 1 of chosen
APPLESCRIPT
)
fi

[ -z "$CHOICE" ] && exit 0

# Extract coordinates for chosen city
LAT=$(echo "$RESULTS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
target = '$CHOICE'
for r in d.get('results', []):
    parts = [r['name'], r.get('admin1', ''), r.get('country', '')]
    name = ', '.join(p for p in parts if p)
    if name == target:
        print(r['latitude'])
        break
")

LON=$(echo "$RESULTS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
target = '$CHOICE'
for r in d.get('results', []):
    parts = [r['name'], r.get('admin1', ''), r.get('country', '')]
    name = ', '.join(p for p in parts if p)
    if name == target:
        print(r['longitude'])
        break
")

# Save location to file
echo "{\"lat\":$LAT,\"lon\":$LON,\"name\":\"$CHOICE\"}" > "$HOME/.config/sketchybar/weather_location.json"

# Reload bar to reflect new city
sketchybar --reload
