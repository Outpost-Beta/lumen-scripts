#!/usr/bin/env bash
# lumen-list.sh (VPS) • Lista Pis y estado; hora en America/Mexico_City
set -euo pipefail

CONF="/etc/lumen-vps.conf"
source "$CONF" 2>/dev/null || { echo "No existe $CONF"; exit 1; }
[[ -f "$DEVICES_TSV" ]] || { echo "No hay dispositivos registrados."; exit 0; }

LOCAL_TZ="America/Mexico_City"
now_epoch=$(date -u +%s)

printf "%-10s %-6s %-22s %-6s %-3s\n" "DEVICE_ID" "PORT" "Last Seen (MX)" "Age(s)" "UP?"

while read -r DEVICE_ID PORT HOSTNAME; do
  [[ -z "${DEVICE_ID:-}" ]] && continue
  hb="/srv/lumen/heartbeats/${DEVICE_ID}.ts"
  if [[ -f "$hb" ]]; then
    ts="$(cat "$hb")"  # generado como 2025-09-16T22:28:43Z por el agente
    last_epoch="$(date -u -d "$ts" +%s 2>/dev/null || echo 0)"
    age=$((now_epoch - last_epoch))
    up="NO"; (( age < 120 )) && up="YES"
    if [[ "$last_epoch" -gt 0 ]]; then
      ts_mx="$(TZ="$LOCAL_TZ" date -d "@$last_epoch" '+%Y-%m-%d %H:%M:%S %Z')"
    else
      ts_mx="-"
    fi
    printf "%-10s %-6s %-22s %-6s %-3s\n" "$DEVICE_ID" "$PORT" "$ts_mx" "$age" "$up"
  else
    printf "%-10s %-6s %-22s %-6s %-3s\n" "$DEVICE_ID" "$PORT" "-" "-" "NO"
  fi
done < "$DEVICES_TSV"
