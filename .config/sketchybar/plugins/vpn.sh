#!/bin/sh

GREEN=0xffa6e3a1
GREY=0xffcdd6f4
BLINK_STATE_FILE=/tmp/sketchybar_vpn_blink
FLAG_CACHE_FILE=/tmp/sketchybar_vpn_flag

# --- Tailscale ---
TAILSCALE_COLOR=$GREY
if scutil --nc list 2>/dev/null | grep -i "Tailscale" | grep -qi "(Connected)"; then
  TAILSCALE_COLOR=$GREEN
fi

# --- NordVPN ---
NORD_COLOR=$GREY
NORD_CONNECTED=$(defaults read com.nordvpn.macos isAppWasConnectedToVPN 2>/dev/null)
if [ "$NORD_CONNECTED" = "1" ]; then
  NORD_COLOR=$GREEN
fi

# --- AWS VPN Client ---
AWS_COLOR=$GREY
if scutil --nc list 2>/dev/null | grep -i "AWS\|Cisco\|anyconnect" | grep -qi "(Connected)"; then
  AWS_COLOR=$GREEN
elif pgrep -x "cvpnd" > /dev/null 2>&1; then
  AWS_COLOR=$GREEN
fi

# --- Corporate WiFi ---
# SSID non leggibile su macOS 14+ senza Location Services; usiamo il gateway
CORP_COLOR=$GREY
CORP_GATEWAY="10.102.1.1"
CURRENT_GATEWAY=$(netstat -rn 2>/dev/null | awk '/^default.*en0/{print $2; exit}')
if [ "$CURRENT_GATEWAY" = "$CORP_GATEWAY" ]; then
  CORP_COLOR=$GREEN
fi

# Aggiorna icone popup
sketchybar --set vpn_tailscale icon.color=$TAILSCALE_COLOR label.color=$TAILSCALE_COLOR
sketchybar --set vpn_nord      icon.color=$NORD_COLOR      label.color=$NORD_COLOR
sketchybar --set vpn_aws       icon.color=$AWS_COLOR       label.color=$AWS_COLOR
sketchybar --set vpn_corp      icon.color=$CORP_COLOR      label.color=$CORP_COLOR

# Logo aziendale: visibile quando AWS VPN o Corp WiFi sono attivi
if [ "$AWS_COLOR" = "$GREEN" ] || [ "$CORP_COLOR" = "$GREEN" ]; then
  sketchybar --set vpn_logo drawing=on
else
  sketchybar --set vpn_logo drawing=off
fi

# Blink + bandiera quando connesso
if [ "$TAILSCALE_COLOR" = "$GREEN" ] || [ "$NORD_COLOR" = "$GREEN" ] \
   || [ "$AWS_COLOR" = "$GREEN" ] || [ "$CORP_COLOR" = "$GREEN" ]; then

  # Bandiera solo se NordVPN è connessa
  FLAG=""
  if [ "$NORD_COLOR" = "$GREEN" ]; then
    # Aggiorna la cache ogni 60s (evita chiamate API ogni secondo)
    if [ ! -f "$FLAG_CACHE_FILE" ] || [ "$(find "$FLAG_CACHE_FILE" -mmin +1 2>/dev/null)" ]; then
      COUNTRY_CODE=$(curl -s --max-time 3 "http://ip-api.com/json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('countryCode', ''))
except:
    print('')
" 2>/dev/null)
      if [ -n "$COUNTRY_CODE" ] && [ ${#COUNTRY_CODE} -eq 2 ]; then
        FLAG=$(python3 -c "
cc = '${COUNTRY_CODE}'.upper()
print(chr(0x1F1E6 + ord(cc[0]) - ord('A')) + chr(0x1F1E6 + ord(cc[1]) - ord('A')))
")
        echo "$FLAG" > "$FLAG_CACHE_FILE"
      fi
    else
      FLAG=$(cat "$FLAG_CACHE_FILE")
    fi
  fi

  LABEL="VPN ${FLAG}"
  sketchybar --set "$NAME" label="$LABEL" label.color=$GREEN

  if [ -f "$BLINK_STATE_FILE" ]; then
    rm "$BLINK_STATE_FILE"
    sketchybar --set "$NAME" icon.color=$GREEN
  else
    touch "$BLINK_STATE_FILE"
    sketchybar --set "$NAME" icon.color=0x44a6e3a1
  fi
else
  rm -f "$BLINK_STATE_FILE" "$FLAG_CACHE_FILE"
  sketchybar --set "$NAME" label="VPN" label.color=$GREY icon.color=$GREY
fi
