#!/usr/bin/env bash
# lumen-list.sh (VPS) • Muestra las Pis registradas y estado de heartbeat

set -euo pipefail

CONF="/etc/lumen-vps.conf"
source "$CONF" 2>/dev/null || { echo "No existe $CONF"; exit 1; }

[[ -f "$DEVICES_TSV" ]] || { echo "No hay dispositivos registrados."; exit 0; }

now=$(date -u +%s)

printf "%-10s %-6s %-20s %-6s %-3s\n" "DEVICE_ID" "PORT" "Last Seen (UTC)" "Age(s)" "UP?"

while read -r DEVICE_ID PORT HOSTNAME; do
  [[ -z "${DEVICE_ID:-}" ]] && continue
  hb="/srv/lumen/heartbeats/${DEVICE_ID}.ts"
  if [[ -f "$hb" ]]; then
    ts=$(cat "$hb")
    last=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
    age=$((now - last))
    up="NO"
    (( age < 120 )) && up="YES"
    printf "%-10s %-6s %-20s %-6s %-3s\n" "$DEVICE_ID" "$PORT" "$ts" "$age" "$up"
  else
    printf "%-10s %-6s %-20s %-6s %-3s\n" "$DEVICE_ID" "$PORT" "-" "-" "NO"
  fi
done < "$DEVICES_TSV"
