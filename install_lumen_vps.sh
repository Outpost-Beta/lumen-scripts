#!/usr/bin/env bash
set -euo pipefail

BASE="/srv/lumen"

echo "[1/6] Creando estructura de directorios…"
sudo mkdir -p $BASE/{config/devices,cmd/devices,heartbeats}
sudo chown -R root:root $BASE

echo "[2/6] Config SSHD para túneles inversos…"
SSHD="/etc/ssh/sshd_config"
sudo cp $SSHD ${SSHD}.bak.$(date +%F-%H%M)
sudo sed -i 's/^#\?AllowTcpForwarding.*/AllowTcpForwarding yes/' $SSHD
if ! grep -q "^GatewayPorts" $SSHD; then
  echo "GatewayPorts no" | sudo tee -a $SSHD >/dev/null
fi
sudo systemctl restart ssh

echo "[3/6] Config común inicial…"
sudo tee $BASE/config/common.conf >/dev/null <<CFG
VOLUME="90"
XMAS_START="12-01"
XMAS_END="01-07"
SEASON_START=""
SEASON_END=""
ADS_SOURCE="Anuncios"
CFG

echo "[4/6] Script para listar Pis…"
sudo tee /usr/local/bin/lumen-list.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail
HEART="/srv/lumen/heartbeats"
now=$(date -u +%s)
printf "%-24s %-24s %-8s %-8s\n" "DEVICE_ID" "Last Seen (UTC)" "Age(s)" "UP?"
for f in "$HEART"/*.ts; do
  [[ -e "$f" ]] || { echo "No heartbeats yet."; exit 0; }
  dev=$(basename "$f" .ts)
  ts=$(cat "$f")
  last=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
  age=$(( now - last ))
  up="DOWN"; [[ $age -le 120 ]] && up="UP"
  printf "%-24s %-24s %-8s %-8s\n" "$dev" "$ts" "$age" "$up"
done
SH
sudo chmod +x /usr/local/bin/lumen-list.sh

echo "[5/6] Broadcast opcional…"
sudo tee /usr/local/bin/lumen-broadcast.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CMD="${*:-}"
if [[ -z "$CMD" ]]; then
  echo "Uso: lumen-broadcast.sh <comando>"
  exit 1
fi
FILE="/srv/lumen/devices.tsv"
while IFS=$'\t' read -r dev port; do
  [[ -z "$dev" || "$dev" =~ ^# ]] && continue
  echo "== $dev (port $port) =="
  ssh -o ConnectTimeout=5 -p "$port" "pi@localhost" "$CMD" || echo "  (no conectado)"
done < "$FILE"
SH
sudo chmod +x /usr/local/bin/lumen-broadcast.sh

echo "[6/6] Archivo de dispositivos (plantilla)…"
sudo tee $BASE/devices.tsv >/dev/null <<'TSV'
# DEVICE_ID<TAB>PORT
raspberrypi	2201
TSV

echo "✅ VPS listo.
- Config común: $BASE/config/common.conf
- Config individuales: $BASE/config/devices/<DEVICE_ID>.conf
- Heartbeats: $BASE/heartbeats
- Listar: lumen-list.sh
- Broadcast: lumen-broadcast.sh 'comando'"
