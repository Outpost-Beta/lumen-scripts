#!/usr/bin/env bash
# install_lumen_vps.sh  (Servidor VPS • SOLO Lumen • sin OneDrive)
# Prepara el VPS para manejar las cajas, con asignación robusta (lock + max+1)
set -euo pipefail

CONF_FILE="/etc/lumen-vps.conf"
BIN_DIR="/usr/local/bin"
STATE_DIR="/srv/lumen"

echo "[1/5] Paquetes base…"
apt-get update -y
apt-get install -y autossh openssh-server jq

echo "[2/5] Configuración global…"
mkdir -p "$STATE_DIR"
mkdir -p /etc/lumen
mkdir -p /srv/lumen/heartbeats

tee "$CONF_FILE" >/dev/null <<'EOF'
DEVICE_PREFIX="Box"
NEXT_INDEX=0
PORT_START=2201
DEVICES_TSV="/srv/lumen/devices.tsv"
EOF

echo "[3/5] Script de asignación (lumen-assign.sh) — versión robusta…"
tee "$BIN_DIR/lumen-assign.sh" >/dev/null <<'ASSIGN'
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
ASSIGN
chmod +x "$BIN_DIR/lumen-assign.sh"

echo "[4/5] Script de listado (lumen-list.sh)…"
tee "$BIN_DIR/lumen-list.sh" >/dev/null <<'LIST'
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
LIST
chmod +x "$BIN_DIR/lumen-list.sh"

echo "[5/5] Ajustes SSH y arranque…"
SSHD="/etc/ssh/sshd_config"
grep -q '^AllowTcpForwarding yes' "$SSHD" || echo "AllowTcpForwarding yes" >> "$SSHD"
grep -q '^ClientAliveInterval 300' "$SSHD" || echo "ClientAliveInterval 300" >> "$SSHD"
grep -q '^ClientAliveCountMax 12' "$SSHD" || echo "ClientAliveCountMax 12" >> "$SSHD"
systemctl restart ssh

echo "✅ VPS listo. Usa 'lumen-list.sh' para ver dispositivos."
