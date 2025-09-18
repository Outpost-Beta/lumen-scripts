#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/lumen-vps.conf"
source "$CONF" 2>/dev/null || { echo "No existe $CONF" >&2; exit 1; }

DEV_TSV="${DEVICES_TSV:-/srv/lumen/devices.tsv}"
LOCK_FILE="${DEV_TSV}.lock"

mkdir -p "$(dirname "$DEV_TSV")"
touch "$DEV_TSV"

HOST_IN="${1:-}"
if [[ -z "${HOST_IN}" ]]; then
  HOST_IN="$(hostname)-$(date +%s)"
fi

exec 9>"$LOCK_FILE"
flock 9

if grep -q -E "^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+${HOST_IN}$" "$DEV_TSV"; then
  row="$(grep -E "^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+${HOST_IN}$" "$DEV_TSV" | head -n1)"
  DID="$(awk '{print $1}' <<<"$row")"
  PORT="$(awk '{print $2}' <<<"$row")"
  echo "DEVICE_ID=${DID} PORT=${PORT}"
  exit 0
fi

next_idx=0
if awk '{print $1}' "$DEV_TSV" | grep -Eo '[0-9]+$' >/dev/null 2>&1; then
  max_idx="$(awk '{print $1}' "$DEV_TSV" | grep -Eo '[0-9]+$' | sort -n | tail -n1)"
  next_idx="$((max_idx + 1))"
fi

printf -v DID "%s-%02d" "${DEVICE_PREFIX:-Box}" "${next_idx}"

PORT_START_VAL="${PORT_START:-2201}"
PORT=$(( PORT_START_VAL + next_idx ))

printf "%s\t%s\t%s\n" "$DID" "$PORT" "$HOST_IN" >> "$DEV_TSV"

if grep -q '^NEXT_INDEX=' "$CONF" 2>/dev/null; then
  sed -i "s/^NEXT_INDEX=.*/NEXT_INDEX=${next_idx}/" "$CONF" || true
fi

echo "DEVICE_ID=${DID} PORT=${PORT}"
lol
