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

# --- WiFi SSID (via scutil CachedScanRecord, nessun permesso richiesto, cached 60s) ---
SSID_CACHE_FILE="/tmp/sketchybar_ssid_cache"
if [ ! -f "$SSID_CACHE_FILE" ] || [ -n "$(find "$SSID_CACHE_FILE" -mmin +1 2>/dev/null)" ]; then
  SSID=$(python3 - << 'PYEOF'
import subprocess, plistlib, re
out = subprocess.run(['scutil'], input='open\nshow State:/Network/Interface/en0/AirPort\n', capture_output=True, text=True).stdout
m = re.search(r'CachedScanRecord : <data> 0x([0-9a-f]+)', out)
if not m:
    print(""); exit()
objects = plistlib.loads(bytes.fromhex(m.group(1)))['$objects']
is_key  = re.compile(r'^[A-Z0-9][A-Z0-9_]*$')
is_uuid = re.compile(r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$')
candidates = [o for o in objects if isinstance(o, str) and not is_key.match(o) and not is_uuid.match(o) and ':' not in o and 1 <= len(o) <= 32 and o not in ('$null','root')]
print(candidates[0] if candidates else "")
PYEOF
)
  if [ -z "$SSID" ]; then SSID="WiFi"; fi
  echo "$SSID" > "$SSID_CACHE_FILE"
else
  SSID=$(cat "$SSID_CACHE_FILE")
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
UPLOG="/Library/Application Support/AWSVPNClient/UpLog.txt"
DOWNLOG="/Library/Application Support/AWSVPNClient/DownLog.txt"
if [ -f "$UPLOG" ] && [ -f "$DOWNLOG" ] && [ "$UPLOG" -nt "$DOWNLOG" ]; then
  AWS_ACTIVE=1
elif [ -f "$UPLOG" ] && [ ! -f "$DOWNLOG" ]; then
  AWS_ACTIVE=1
fi

# --- Corporate WiFi ---
CORP_ACTIVE=0
[ "$SSID" = "qbc-ent" ] && CORP_ACTIVE=1

# Corp logo image: only for corp WiFi
if [ "$CORP_ACTIVE" = "1" ]; then
  sketchybar --set vpn_logo drawing=on
else
  sketchybar --set vpn_logo drawing=off
fi

# Push state to network popup app (fire-and-forget, silent if not running)
WIFI_ENABLED=1
networksetup -getairportpower en0 2>/dev/null | grep -q "Off" && WIFI_ENABLED=0
SSID_ENCODED=$(echo "$SSID" | sed 's/ /%20/g')
echo "state ssid=$SSID_ENCODED wifi=$WIFI_ENABLED tailscale=$TAILSCALE_ACTIVE nord=$NORD_ACTIVE aws=$AWS_ACTIVE corp=$CORP_ACTIVE" \
  | nc -U /tmp/network_popup.sock 2>/dev/null || true

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
