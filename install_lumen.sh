#!/usr/bin/env bash
set -euo pipefail

# === Config mínima ===
VPS_HOST="200.234.230.254"
VPS_USER="root"
BOOT_USER="${USER:-admin}"
HOME_DIR="${HOME:-/home/admin}"
CONF_DIR="/etc/lumen"
LUMEN_DIR="$HOME_DIR/Lumen"

echo "[1/9] Paquetes base…"
sudo apt update
sudo apt install -y autossh openssh-client openssh-server python3 python3-pip vlc python3-vlc alsa-utils jq rsync

echo "[2/9] Clave SSH local…"
mkdir -p "$HOME_DIR/.ssh" && chmod 700 "$HOME_DIR/.ssh"
if [[ ! -f "$HOME_DIR/.ssh/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -f "$HOME_DIR/.ssh/id_ed25519" -N "" -C "${BOOT_USER}@$(hostname -s)"
fi
chmod 600 "$HOME_DIR/.ssh/id_ed25519"
chmod 644 "$HOME_DIR/.ssh/id_ed25519.pub"

echo "[3/9] Autorizar Pi→VPS (te pedirá la contraseña de ${VPS_USER}@${VPS_HOST} una vez)…"
ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$HOME_DIR/.ssh/id_ed25519.pub" ${VPS_USER}@${VPS_HOST} || true

echo "[4/9] Obtener/reciclar DEVICE_ID y PORT desde el VPS…"
DEVICE_ID=""; PORT=""
if [[ -f "$CONF_DIR/lumen.conf" ]]; then
  DEVICE_ID=$(sed -n 's/^DEVICE_ID="\([^"]*\)"/\1/p' "$CONF_DIR/lumen.conf" || true)
  PORT=$(sed -n 's/^PORT="\([^"]*\)"/\1/p' "$CONF_DIR/lumen.conf" || true)
fi
if [[ -n "${DEVICE_ID:-}" && -n "${PORT:-}" ]]; then
  echo "Reutilizando config existente: DEVICE_ID=${DEVICE_ID} PORT=${PORT}"
else
  PUBKEY_B64=$(base64 -w0 < "$HOME_DIR/.ssh/id_ed25519.pub")
  ASSIGN=$(ssh -o StrictHostKeyChecking=accept-new ${VPS_USER}@${VPS_HOST} "/usr/local/bin/lumen-assign.sh --register --pubkey-b64 \"$PUBKEY_B64\"")
  eval "$ASSIGN"
  echo "Asignado: DEVICE_ID=$DEVICE_ID PORT=$PORT"
fi

echo "[5/9] Guardar config…"
sudo mkdir -p "$CONF_DIR"
sudo tee "$CONF_DIR/lumen.conf" >/dev/null <<CFG
DEVICE_ID="${DEVICE_ID}"
VPS_HOST="${VPS_HOST}"
VPS_USER="${VPS_USER}"
PORT="${PORT}"
VOLUME="90"
XMAS_START="12-01"
XMAS_END="01-07"
SEASON_START=""
SEASON_END=""
ADS_SOURCE="Anuncios"
CFG

echo "[6/9] Autorizar VPS→Pi por túnel (sin password)…"
mkdir -p "$HOME_DIR/.ssh" && chmod 700 "$HOME_DIR/.ssh"
touch "$HOME_DIR/.ssh/authorized_keys" && chmod 600 "$HOME_DIR/.ssh/authorized_keys"
# Traer la pub del VPS y agregarla
ssh -o StrictHostKeyChecking=accept-new ${VPS_USER}@${VPS_HOST} \
  "cat /srv/lumen/vps_root_id_ed25519.pub" >> "$HOME_DIR/.ssh/authorized_keys" || true
# Deduplicar
awk '!seen[$0]++' "$HOME_DIR/.ssh/authorized_keys" > "$HOME_DIR/.ssh/authorized_keys.tmp" && mv "$HOME_DIR/.ssh/authorized_keys.tmp" "$HOME_DIR/.ssh/authorized_keys"
chown -R ${BOOT_USER}:${BOOT_USER} "$HOME_DIR/.ssh"

echo "[7/9] Carpetas de audio…"
mkdir -p "$LUMEN_DIR"/{Canciones,Anuncios,Navideña,Temporada}

echo "[8/9] Servicios systemd…"
# --- autossh reverse tunnel ---
sudo tee /etc/systemd/system/autossh-lumen.service >/dev/null <<'UNIT'
[Unit]
Description=AutoSSH reverse tunnel to VPS
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/lumen/lumen.conf
User=admin
ExecStart=/usr/bin/autossh -M 0 -N \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new \
  -i /home/admin/.ssh/id_ed25519 \
  -R ${PORT}:127.0.0.1:22 ${VPS_USER}@${VPS_HOST}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# --- heartbeat robusto ---
sudo tee /usr/local/bin/lumen-agent.sh >/dev/null <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen/lumen.conf"; source "$CONF"

STAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
logger -t lumen-agent "Enviando heartbeat: DEVICE_ID=${DEVICE_ID} -> ${VPS_USER}@${VPS_HOST}"

set +e
printf "%s" "$STAMP" | ssh \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  -o ConnectTimeout=5 \
  -o ServerAliveInterval=10 \
  -o ServerAliveCountMax=1 \
  -i /home/admin/.ssh/id_ed25519 \
  "${VPS_USER}@${VPS_HOST}" "cat > /srv/lumen/heartbeats/${DEVICE_ID}.ts"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  logger -t lumen-agent "Heartbeat OK: ${STAMP}"
else
  logger -t lumen-agent "Heartbeat FAIL (rc=${rc})"
fi
AGENT
sudo chmod +x /usr/local/bin/lumen-agent.sh

sudo tee /etc/systemd/system/lumen-agent.service >/dev/null <<'UNIT'
[Unit]
Description=Lumen Agent (heartbeat)
After=network-online.target
Wants=network-online.target

[Service]
User=admin
Type=oneshot
ExecStart=/usr/local/bin/lumen-agent.sh
StandardOutput=journal
StandardError=journal
UNIT

sudo tee /etc/systemd/system/lumen-agent.timer >/dev/null <<'UNIT'
[Unit]
Description=Lumen Agent Timer

[Timer]
OnBootSec=30
OnUnitActiveSec=60
Unit=lumen-agent.service
Persistent=true

[Install]
WantedBy=timers.target
UNIT

echo "[9/9] Activar y probar…"
sudo systemctl daemon-reload
sudo systemctl enable autossh-lumen.service lumen-agent.timer
sudo systemctl restart autossh-lumen.service
sudo systemctl restart lumen-agent.timer

/usr/local/bin/lumen-agent.sh || true
ssh -o StrictHostKeyChecking=accept-new -i "$HOME_DIR/.ssh/id_ed25519" ${VPS_USER}@${VPS_HOST} \
  "test -s /srv/lumen/heartbeats/${DEVICE_ID}.ts && tail -n1 /srv/lumen/heartbeats/${DEVICE_ID}.ts || echo 'NO_HEARTBEAT'"

echo "✅ Listo: DEVICE_ID=${DEVICE_ID}  PORT=${PORT}
Conéctate desde el VPS con:
  ssh -p ${PORT} admin@localhost
"
