#!/usr/bin/env bash
# lumen-assign.sh — Asigna DEVICE_ID y PORT autoincrementales en el VPS
# - Reusa la misma asignación si el HOSTNAME (argumento) ya existe en devices.tsv
# - Si no existe, asigna el siguiente índice disponible (escaneo + lock) y persiste en /etc/lumen-vps.conf
# - Salida: "DEVICE_ID=Box-00 PORT=2201"
#
# Uso:
#   lumen-assign.sh <hostname_unico>
#   (si se omite el argumento, intentará usar $SSH_CONNECTION o un UUID efímero)
set -euo pipefail

CONF="/etc/lumen-vps.conf"
source "$CONF" 2>/dev/null || { echo "No existe $CONF" >&2; exit 1; }

DEV_TSV="${DEVICES_TSV:-/srv/lumen/devices.tsv}"
LOCK_FILE="${DEV_TSV}.lock"

mkdir -p "$(dirname "$DEV_TSV")"
touch "$DEV_TSV"

HOST_IN="${1:-}"
if [[ -z "${HOST_IN}" ]]; then
  # Fallback poco ideal, pero evita duplicados triviales
  HOST_IN="$(hostname)-$(date +%s)"
fi

# Abrir lock para evitar condiciones de carrera
exec 9>"$LOCK_FILE"
flock 9

# ¿Ya existe este hostname? Reusar asignación
if grep -q -E "^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+${HOST_IN}$" "$DEV_TSV"; then
  row="$(grep -E "^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+${HOST_IN}$" "$DEV_TSV" | head -n1)"
  DID="$(awk '{print $1}' <<<"$row")"
  PORT="$(awk '{print $2}' <<<"$row")"
  echo "DEVICE_ID=${DID} PORT=${PORT}"
  exit 0
fi

# Calcular siguiente índice disponible escaneando el archivo (resistente a manual edits)
# Extrae índices como números (Box-00 -> 0) y toma max+1; si no hay, arranca en 0
next_idx=0
if awk '{print $1}' "$DEV_TSV" | grep -Eo '[0-9]+$' >/dev/null 2>&1; then
  max_idx="$(awk '{print $1}' "$DEV_TSV" | grep -Eo '[0-9]+$' | sort -n | tail -n1)"
  next_idx="$((max_idx + 1))"
fi

# Formatear DEVICE_ID y PORT
printf -v DID "%s-%02d" "${DEVICE_PREFIX:-Box}" "${next_idx}"
PORT=$(( (PORT_START:-2201) + next_idx ))

# Añadir fila (DEVICE_ID  PORT  HOSTNAME)
printf "%s\t%s\t%s\n" "$DID" "$PORT" "$HOST_IN" >> "$DEV_TSV"

# Intentar mantener NEXT_INDEX coherente (best-effort)
if grep -q '^NEXT_INDEX=' "$CONF" 2>/dev/null; then
  sed -i "s/^NEXT_INDEX=.*/NEXT_INDEX=${next_idx}/" "$CONF" || true
fi

echo "DEVICE_ID=${DID} PORT=${PORT}"
