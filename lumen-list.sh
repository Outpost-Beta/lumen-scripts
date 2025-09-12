#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen-vps.conf"; source "$CONF"
HEART="/srv/lumen/heartbeats"
TSV="$DEVICES_TSV"
now=$(date -u +%s)
printf "%-12s %-6s %-22s %-6s %-3s\n" "DEVICE_ID" "PORT" "Last Seen (UTC)" "Age(s)" "UP?"
while IFS=$'\t' read -r dev port; do
  [[ -z "${dev:-}" || "$dev" =~ ^# ]] && continue
  f="$HEART/$dev.ts"
  if [[ -f "$f" ]]; then
    ts=$(cat "$f")
    last=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
    age=$((now-last))
    up="NO"; [[ $age -le 120 ]] && up="YES"
    printf "%-12s %-6s %-22s %-6s %-3s\n" "$dev" "$port" "$ts" "$age" "$up"
  else
    printf "%-12s %-6s %-22s %-6s %-3s\n" "$dev" "$port" "—" "—" "NO"
  fi
done < "$TSV"
