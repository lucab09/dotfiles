#!/bin/sh

# GPU usage (Apple Silicon / integrated Apple GPU)
GPU=$(ioreg -r -d 1 -w 0 -c IOAccelerator 2>/dev/null \
  | sed -n 's/.*"Device Utilization %"=\([0-9][0-9]*\).*/\1/p' \
  | head -1)
GPU=${GPU:-0}

# CPU usage: user + system from macOS process statistics
CPU_LINE=$(top -l 1 -n 0 -stats cpu | grep "CPU usage")
CPU_USER=$(echo "$CPU_LINE" | awk '{print $3}' | tr -d '%')
CPU_SYS=$(echo "$CPU_LINE" | awk '{print $5}' | tr -d '%')
CPU=$(awk -v user="${CPU_USER:-0}" -v sys="${CPU_SYS:-0}" \
  'BEGIN { printf "%.0f", user + sys }')

# Memory health: show the percentage macOS considers available and color its status
MEM_AVAILABLE=$(memory_pressure -Q 2>/dev/null \
  | awk -F': ' '/System-wide memory free percentage/ {gsub(/%/, "", $2); print $2}')
MEM_AVAILABLE=${MEM_AVAILABLE:-0}

if [ "$MEM_AVAILABLE" -lt 10 ]; then
  MEM_COLOR=0xfff38ba8 # Critical
elif [ "$MEM_AVAILABLE" -lt 20 ]; then
  MEM_COLOR=0xfff9e2af # Warning
else
  MEM_COLOR=0xffa6e3a1 # Healthy
fi

sketchybar --set gpu label="G ${GPU}%  /" \
           --set cpu label="C ${CPU}%  /" \
           --set mem label="M ${MEM_AVAILABLE}%" \
                     icon.color="$MEM_COLOR" \
                     label.color="$MEM_COLOR"
