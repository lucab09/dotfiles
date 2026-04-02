#!/bin/sh

GREEN=0xffa6e3a1
GREY=0xffcdd6f4
COLOR1=0xff219ebc
BLINK_STATE_FILE=/tmp/sketchybar_vpn_blink
FLAG_CACHE_FILE=/tmp/sketchybar_vpn_flag

# --- LAN detection (first active non-WiFi/Bluetooth interface) ---
LAN_ACTIVE=0
while IFS= read -r line; do
  if echo "$line" | grep -q "Hardware Port:"; then
    HW_SERVICE=$(echo "$line" | sed 's/.*Hardware Port: //')
  elif echo "$line" | grep -q "Device:"; then
    HW_IFACE=$(echo "$line" | awk '{print $2}')
    if ! echo "$HW_SERVICE" | grep -qi "wi-fi\|airport\|bluetooth\|thunderbolt bridge"; then
      if ifconfig "$HW_IFACE" 2>/dev/null | grep -q "status: active"; then
        LAN_ACTIVE=1
        break
      fi
    fi
  fi
done <<EOF
$(networksetup -listallhardwareports 2>/dev/null)
EOF

# --- WiFi SSID ---
SSID=$(networksetup -getairportnetwork en0 2>/dev/null | sed 's/Current Wi-Fi Network: //')
if echo "$SSID" | grep -qi "not associated\|You are not"; then
  SSID=$(networksetup -getairportnetwork en1 2>/dev/null | sed 's/Current Wi-Fi Network: //')
fi
if echo "$SSID" | grep -qi "not associated\|You are not\|Error"; then
  SSID=""
fi

# --- Tailscale ---
TAILSCALE_ACTIVE=0
if scutil --nc list 2>/dev/null | grep -i "Tailscale" | grep -qi "(Connected)"; then
  TAILSCALE_ACTIVE=1
fi

# --- NordVPN ---
NORD_ACTIVE=0
NORD_CONNECTED=$(defaults read com.nordvpn.macos isAppWasConnectedToVPN 2>/dev/null)
[ "$NORD_CONNECTED" = "1" ] && NORD_ACTIVE=1

# --- AWS VPN Client ---
AWS_ACTIVE=0
if scutil --nc list 2>/dev/null | grep -i "AWS\|Cisco\|anyconnect" | grep -qi "(Connected)"; then
  AWS_ACTIVE=1
elif pgrep -x "cvpnd" > /dev/null 2>&1; then
  AWS_ACTIVE=1
fi

# --- Corporate WiFi ---
CORP_ACTIVE=0
CORP_GATEWAY="10.102.1.1"
CURRENT_GATEWAY=$(netstat -rn 2>/dev/null | awk '/^default.*en0/{print $2; exit}')
[ "$CURRENT_GATEWAY" = "$CORP_GATEWAY" ] && CORP_ACTIVE=1

# Update popup item colors
TAILSCALE_COLOR=$GREY; [ "$TAILSCALE_ACTIVE" = "1" ] && TAILSCALE_COLOR=$GREEN
NORD_COLOR=$GREY;      [ "$NORD_ACTIVE"      = "1" ] && NORD_COLOR=$GREEN
AWS_COLOR=$GREY;       [ "$AWS_ACTIVE"        = "1" ] && AWS_COLOR=$GREEN
CORP_COLOR=$GREY;      [ "$CORP_ACTIVE"       = "1" ] && CORP_COLOR=$GREEN

sketchybar --set vpn_tailscale icon.color=$TAILSCALE_COLOR label.color=$TAILSCALE_COLOR
sketchybar --set vpn_nord      icon.color=$NORD_COLOR      label.color=$NORD_COLOR
sketchybar --set vpn_aws       icon.color=$AWS_COLOR       label.color=$AWS_COLOR
sketchybar --set vpn_corp      icon.color=$CORP_COLOR      label.color=$CORP_COLOR

# Corp logo image: only for corp WiFi
if [ "$CORP_ACTIVE" = "1" ]; then
  sketchybar --set vpn_logo drawing=on
else
  sketchybar --set vpn_logo drawing=off
fi

ANY_VPN=$(( TAILSCALE_ACTIVE + NORD_ACTIVE + AWS_ACTIVE + CORP_ACTIVE ))

# --- Icon: LAN takes priority over WiFi ---
if [ "$LAN_ACTIVE" = "1" ]; then
  ICON="󰈀"   # ethernet cable
  BASE_LABEL="LAN"
elif [ -n "$SSID" ]; then
  ICON="󰖩"   # wifi
  BASE_LABEL="$SSID"
else
  ICON="󰖪"   # wifi off
  BASE_LABEL="No network"
fi

# --- VPN badge suffix ---
BADGE=""
if [ "$TAILSCALE_ACTIVE" = "1" ]; then
  BADGE="  󰒄"
elif [ "$AWS_ACTIVE" = "1" ]; then
  BADGE="  󰸏"
elif [ "$NORD_ACTIVE" = "1" ]; then
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
  BADGE="  $FLAG"
fi

LABEL="${BASE_LABEL}${BADGE}"

if [ "$ANY_VPN" -gt 0 ]; then
  sketchybar --set "$NAME" icon="$ICON" label="$LABEL" label.color=$GREEN

  if [ -f "$BLINK_STATE_FILE" ]; then
    rm "$BLINK_STATE_FILE"
    sketchybar --set "$NAME" icon.color=$GREEN
  else
    touch "$BLINK_STATE_FILE"
    sketchybar --set "$NAME" icon.color=0x44a6e3a1
  fi
else
  rm -f "$BLINK_STATE_FILE" "$FLAG_CACHE_FILE"
  sketchybar --set "$NAME" icon="$ICON" label="$LABEL" label.color=$COLOR1 icon.color=$COLOR1
fi
