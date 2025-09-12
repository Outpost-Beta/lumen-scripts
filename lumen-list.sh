#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/lumen-vps.conf"; source "$CONF"
HEART="/srv/lumen/heartbeats"
TSV="$DEVICES_TSV"

now_utc_s=$(date -u +%s)

# Encabezado: quitamos Age(s) y agregamos Last Seen (Local)
printf "%-12s %-6s %-22s %-25s %-3s\n" "DEVICE_ID" "PORT" "Last Seen (UTC)" "Last Seen (Local)" "UP?"

while IFS=$'\t' read -r dev port; do
  [[ -z "${dev:-}" || "$dev" =~ ^# ]] && continue
  f="$HEART/$dev.ts"

  if [[ -f "$f" ]]; then
    ts=$(cat "$f")                                   # ISO en UTC, ej: 2025-09-12T02:58:56Z
    # A UTC epoch (para calcular si está UP)
    last_utc_s=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
    # Formatos legibles
    ts_utc="$ts"
    ts_local=$(date -d "$ts" +"%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || echo "—")

    age=$(( now_utc_s - last_utc_s ))
    up="NO"; [[ $age -le 120 ]] && up="YES"

    printf "%-12s %-6s %-22s %-25s %-3s\n" "$dev" "$port" "$ts_utc" "$ts_local" "$up"
  else
    printf "%-12s %-6s %-22s %-25s %-3s\n" "$dev" "$port" "—" "—" "NO"
  fi
done < "$TSV"
