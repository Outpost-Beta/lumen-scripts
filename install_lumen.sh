#!/usr/bin/env bash
set -euo pipefail

VPS_HOST="200.234.230.254"
VPS_USER="root"
BOOT_USER="${USER:-admin}"
BOOT_PASS="banana"
HOME_DIR="${HOME:-/home/admin}"
CONF_DIR="/etc/lumen"
BIN_DIR="/usr/local/bin"
LUMEN_DIR="$HOME_DIR/Lumen"

echo "[1/7] Paquetes base…"
sudo apt update
sudo apt install -y sshpass autossh openssh-client python3 python3-pip vlc python3-vlc alsa-utils jq rsync

echo "[2/7] Clave SSH…"
if [[ ! -f "$HOME_DIR/.ssh/id_ed25519" ]]; then
  mkdir -p "$HOME_DIR/.ssh"
  ssh-keygen -t ed25519 -f "$HOME_DIR/.ssh/id_ed25519" -N "" -C "${BOOT_USER}@$(hostname -s)"
fi

echo "[3/7] Autorizar en VPS…"
sshpass -p "$BOOT_PASS" ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$HOME_DIR/.ssh/id_ed25519.pub" ${VPS_USER}@${VPS_HOST}

echo "[4/7] Pedir asignación al VPS…"
ASSIGN=$(ssh -o StrictHostKeyChecking=accept-new ${VPS_USER}@${VPS_HOST} "/usr/local/bin/lumen-assign.sh --register --hostname $(hostname -s)")
eval "$ASSIGN"
echo "Asignado: DEVICE_ID=$DEVICE_ID PORT=$PORT"

echo "[5/7] Guardando config…"
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

echo "[6/7] Carpetas audio…"
mkdir -p "$LUMEN_DIR"/{Canciones,Anuncios,Navideña,Temporada}

echo "[7/7] Servicios systemd…"
sudo tee /etc/systemd/system/autossh-lumen.service >/dev/null <<UNIT
[Unit]
Description=AutoSSH reverse tunnel
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/lumen/lumen.conf
User=admin
ExecStart=/usr/bin/autossh -M 0 -N \\
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \\
  -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new \\
  -i %h/.ssh/id_ed25519 \\
  -R \${PORT}:localhost:22 \${VPS_USER}@\${VPS_HOST}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

sudo tee ${BIN_DIR}/lumen-agent.sh >/dev/null <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen/lumen.conf"; source "$CONF"
date -u +"%Y-%m-%dT%H:%M:%SZ" | ssh -o StrictHostKeyChecking=accept-new -i /home/admin/.ssh/id_ed25519 ${VPS_USER}@${VPS_HOST} "cat > /srv/lumen/heartbeats/${DEVICE_ID}.ts" || true
AGENT
sudo chmod +x ${BIN_DIR}/lumen-agent.sh

sudo tee /etc/systemd/system/lumen-agent.service >/dev/null <<UNIT
[Unit]
Description=Lumen Agent
After=network-online.target
Wants=network-online.target

[Service]
User=admin
Type=oneshot
ExecStart=/usr/local/bin/lumen-agent.sh
UNIT

sudo tee /etc/systemd/system/lumen-agent.timer >/dev/null <<UNIT
[Unit]
Description=Lumen Agent Timer
[Timer]
OnBootSec=30
OnUnitActiveSec=60
Unit=lumen-agent.service

[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now autossh-lumen.service lumen-agent.timer

echo "✅ Listo: DEVICE_ID=$DEVICE_ID PORT=$PORT
Conéctate desde el VPS con:
  ssh -p $PORT admin@localhost
"
