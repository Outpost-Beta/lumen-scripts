#!/usr/bin/env bash
# install_lumen_vps.sh  (Servidor VPS • SOLO Lumen • sin OneDrive)
# Prepara el VPS para manejar las cajas
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
tee "$CONF_FILE" >/dev/null <<'EOF'
DEVICE_PREFIX="Box"
NEXT_INDEX=0
PORT_START=2201
DEVICES_TSV="/srv/lumen/devices.tsv"
EOF

echo "[3/5] Script de asignación (lumen-assign.sh)…"
tee "$BIN_DIR/lumen-assign.sh" >/dev/null <<'ASSIGN'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen-vps.conf"
source "$CONF"

mkdir -p "$(dirname "$DEVICES_TSV")"
touch "$DEVICES_TSV"

# Si existe y tiene una entrada para este hostname, reutilízala
HOSTNAME_ARG="${1:-}"
if grep -q -E "^\S+\s+\S+\s+${HOSTNAME_ARG}$" "$DEVICES_TSV"; then
  row="$(grep -E "^\S+\s+\S+\s+${HOSTNAME_ARG}$" "$DEVICES_TSV" | head -n1)"
  DEVICE_ID="$(awk '{print $1}' <<<"$row")"
  PORT="$(awk '{print $2}' <<<"$row")"
else
  DEVICE_ID="${DEVICE_PREFIX}-$(printf "%02d" "$NEXT_INDEX")"
  PORT=$((PORT_START + NEXT_INDEX))
  echo -e "${DEVICE_ID}\t${PORT}\t${HOSTNAME_ARG}" >>"$DEVICES_TSV"
  NEXT_INDEX=$((NEXT_INDEX + 1))
  sed -i "s/^NEXT_INDEX=.*/NEXT_INDEX=${NEXT_INDEX}/" "$CONF"
fi

echo "DEVICE_ID=${DEVICE_ID} PORT=${PORT}"
ASSIGN
chmod +x "$BIN_DIR/lumen-assign.sh"

echo "[4/5] Script de listado (lumen-list.sh)…"
tee "$BIN_DIR/lumen-list.sh" >/dev/null <<'LIST'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen-vps.conf"
source "$CONF"

touch "$DEVICES_TSV"
printf "%-10s %-6s %-20s %-6s %s\n" "DEVICE_ID" "PORT" "Last Seen (UTC)" "Age(s)" "UP?"

now=$(date -u +%s)
while read -r DEVICE_ID PORT HOSTNAME; do
  hb="/srv/lumen/heartbeats/${DEVICE_ID}.ts"
  if [[ -f "$hb" ]]; then
    ts=$(cat "$hb")
    last=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
    age=$((now - last))
    up="NO"
    if [[ $age -lt 120 ]]; then
      up="YES"
    fi
    printf "%-10s %-6s %-20s %-6s %s\n" "$DEVICE_ID" "$PORT" "$ts" "$age" "$up"
  else
    printf "%-10s %-6s %-20s %-6s %s\n" "$DEVICE_ID" "$PORT" "-" "-" "NO"
  fi
done <"$DEVICES_TSV"
LIST
chmod +x "$BIN_DIR/lumen-list.sh"

echo "[5/5] Ajustes SSH y arranque…"
SSHD="/etc/ssh/sshd_config"
grep -q '^AllowTcpForwarding yes' "$SSHD" || echo "AllowTcpForwarding yes" >> "$SSHD"
grep -q '^ClientAliveInterval 300' "$SSHD" || echo "ClientAliveInterval 300" >> "$SSHD"
grep -q '^ClientAliveCountMax 12' "$SSHD" || echo "ClientAliveCountMax 12" >> "$SSHD"
systemctl restart ssh

echo "✅ VPS listo. Usa 'lumen-list.sh' para ver dispositivos."
