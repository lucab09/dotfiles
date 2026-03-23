#!/bin/sh

# Legge l'interfaccia di rete attiva
INTERFACE=$(route get default 2>/dev/null | grep interface | awk '{print $2}')

if [ -z "$INTERFACE" ]; then
  sketchybar --set "$NAME" label="no net"
  exit 0
fi

# Bytes attuali
read_bytes() {
  netstat -ib | awk -v iface="$INTERFACE" '$1 == iface {print $7, $10; exit}'
}

PREV_FILE="/tmp/sketchybar_net_$INTERFACE"
CURRENT=$(read_bytes)
BYTES_IN=$(echo "$CURRENT" | awk '{print $1}')
BYTES_OUT=$(echo "$CURRENT" | awk '{print $2}')

if [ -f "$PREV_FILE" ]; then
  PREV_IN=$(awk '{print $1}' "$PREV_FILE")
  PREV_OUT=$(awk '{print $2}' "$PREV_FILE")
  DELTA_IN=$(( (BYTES_IN - PREV_IN) / 1024 ))
  DELTA_OUT=$(( (BYTES_OUT - PREV_OUT) / 1024 ))
else
  DELTA_IN=0
  DELTA_OUT=0
fi

echo "$BYTES_IN $BYTES_OUT" > "$PREV_FILE"

# Formatta: usa M se > 1024K
fmt() {
  if [ "$1" -ge 1024 ] 2>/dev/null; then
    echo "$(( $1 / 1024 ))M"
  else
    echo "${1}K"
  fi
}

DOWN=$(fmt "$DELTA_IN")
UP=$(fmt "$DELTA_OUT")

sketchybar --set "$NAME" label="↓${DOWN} ↑${UP}"
