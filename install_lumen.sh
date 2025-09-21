#!/usr/bin/env bash
# install_lumen.sh — Instalador de la caja Lumen (Raspberry Pi)
# Versión final corregida para usar FTP/rclone y sintaxis tee correcta.

set -euo pipefail

# --- Parámetros ---
VPS_HOST="${VPS_HOST:-200.234.230.254}"
VPS_USER="${VPS_USER:-root}"
ME_USER="$(id -un)"
HOME_DIR="$HOME"

if [[ "$ME_USER" != "admin" ]]; then
  echo "[WARN] Estás instalando como '$ME_USER'. Se asume el usuario 'admin'."
fi

echo "[1/10] Paquetes base…"
sudo apt-get update -y
sudo apt-get install -y \
  autossh openssh-client openssh-server jq rsync curl \
  python3 python3-pip vlc python3-vlc alsa-utils

echo "[2/10] Clave SSH local…"
mkdir -p "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"
if [[ ! -f "$HOME_DIR/.ssh/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$HOME_DIR/.ssh/id_ed25519"
fi

echo "[3/10] Autorizando claves SSH en ambas direcciones…"
# Autorizar Pi→VPS (para establecer el túnel)
ssh-copy-id -i "$HOME_DIR/.ssh/id_ed25519.pub" -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" || true

# Autorizar VPS→Pi (para usar el túnel con lumen-broadcast.sh)
touch "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
if ssh -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" "test -r ~/.ssh/id_ed25519.pub"; then
  ssh "${VPS_USER}@${VPS_HOST}" "cat ~/.ssh/id_ed25519.pub" >> "$HOME_DIR/.ssh/authorized_keys"
  echo "[INFO] Llave del VPS agregada a authorized_keys de la Pi."
else
  echo "[WARN] El VPS no tiene ~/.ssh/id_ed25519.pub. 'lumen-broadcast' podría fallar."
fi

# --- Config local ---
CONF_DIR="/etc/lumen"
CONF_FILE="$CONF_DIR/lumen.conf"
sudo mkdir -p "$CONF_DIR"
DEVICE_ID=""
PORT=""
if [[ -f "$CONF_FILE" ]]; then
  source "$CONF_FILE" || true
fi

echo "[4/10] Verificando /etc/hosts…"
HOST_UNICO="$(hostnamectl --static 2>/dev/null || hostname -s)"
if ! grep -qE "^127\.0\.1\.1[[:space:]]+${HOST_UNICO}(\s|$)" /etc/hosts; then
  echo "127.0.1.1 ${HOST_UNICO}" | sudo tee -a /etc/hosts >/dev/null
fi

echo "[5/10] Obtener/reciclar DEVICE_ID y PORT desde el VPS…"
if [[ -n "${DEVICE_ID:-}" && -n "${PORT:-}" ]]; then
  echo "Reutilizando: DEVICE_ID=${DEVICE_ID} PORT=${PORT}"
else
  ASSIGN_RAW="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" "lumen-assign.sh ${HOST_UNICO}")" || true
  DEVICE_ID="$(sed -n 's/.*DEVICE_ID=\([^[:space:]]*\).*/\1/p' <<<"$ASSIGN_RAW")"
  PORT="$(sed -n 's/.*PORT=\([0-9]\+\).*/\1/p' <<<"$ASSIGN_RAW")"
  if [[ -z "${DEVICE_ID}" || -z "${PORT}" ]]; then
    DEVICE_ID="$(jq -r '.device_id // empty' <<<"$ASSIGN_RAW" 2>/dev/null || true)"
    PORT="$(jq -r '.port // empty' <<<"$ASSIGN_RAW" 2>/dev/null || true)"
  fi
  if [[ -z "${DEVICE_ID}" || -z "${PORT}" ]]; then
    echo "[ERROR] No pude obtener asignación del VPS. Salida fue:"
    echo "$ASSIGN_RAW"
    exit 1
  fi
fi

echo "[6/10] Guardar configuración…"
TMP_CONF="$(mktemp)"
cat > "$TMP_CONF" <<EOF
# /etc/lumen/lumen.conf
DEVICE_ID="${DEVICE_ID}"
VPS_HOST="${VPS_HOST}"
VPS_USER="${VPS_USER}"
PORT="${PORT}"
EOF
sudo mv "$TMP_CONF" "$CONF_FILE"
sudo chmod 644 "$CONF_FILE"

echo "[7/10] Instalando y configurando cliente de sincronización FTP…"
bash ./install_ftp_client.sh

echo "[8/10] Instalando servicios de gestión y reproductor…"

# --- Agente de heartbeat ---
sudo tee /usr/local/bin/lumen-agent.sh >/dev/null <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
source /etc/lumen/lumen.conf
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" \
  "mkdir -p /srv/lumen/heartbeats && echo ${STAMP} > /srv/lumen/heartbeats/${DEVICE_ID}.ts"
AGENT
sudo chmod +x /usr/local/bin/lumen-agent.sh

sudo tee /etc/systemd/system/lumen-agent.service >/dev/null <<'UNIT'
[Unit]
Description=Lumen Heartbeat Agent
[Service]
Type=oneshot
ExecStart=/usr/local/bin/lumen-agent.sh
User=admin
Group=admin
UNIT

sudo tee /etc/systemd/system/lumen-agent.timer >/dev/null <<'UNIT'
[Unit]
Description=Run Lumen Heartbeat Agent every minute
[Timer]
OnBootSec=15s
OnUnitActiveSec=60s
AccuracySec=10s
Unit=lumen-agent.service
[Install]
WantedBy=timers.target
UNIT

# --- Servicio de autossh (túnel inverso) ---
sudo tee /etc/systemd/system/autossh-lumen.service >/dev/null <<'UNIT'
[Unit]
Description=autossh reverse tunnel to VPS
After=network-online.target ssh.service
Wants=network-online.target
[Service]
EnvironmentFile=/etc/lumen/lumen.conf
User=admin
Group=admin
ExecStart=/usr/bin/autossh -M 0 -N \
  -o "ServerAliveInterval=30" -o "ServerAliveCountMax=3" \
  -o "ExitOnForwardFailure=yes" -o "StrictHostKeyChecking=accept-new" \
  -R 127.0.0.1:${PORT}:127.0.0.1:22 ${VPS_USER}@${VPS_HOST}
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT

# --- Servicio del reproductor de música ---
sudo cp lumen-play.py /usr/local/bin/lumen-play.py
sudo chmod +x /usr/local/bin/lumen-play.py

sudo tee /etc/systemd/system/lumen-play.service >/dev/null <<'UNIT'
[Unit]
Description=Lumen Music Player
After=network-online.target ftp-sync-Lumen.service
Wants=network-online.target
[Service]
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 /usr/local/bin/lumen-play.py
WorkingDirectory=/home/admin/Lumen
User=admin
Group=admin
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT

echo "[9/10] Sudoers (NOPASSWD) para broadcast…"
SUDO_FILE="/etc/sudoers.d/lumen-admin-nopasswd"
echo 'admin ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/systemctl, /usr/bin/journalctl, /usr/bin/curl, /usr/bin/rsync' | sudo tee "$SUDO_FILE" >/dev/null
sudo chmod 440 "$SUDO_FILE"

echo "[10/10] Activando servicios…"
sudo systemctl daemon-reload
sudo systemctl enable --now autossh-lumen.service
sudo systemctl enable --now lumen-agent.timer
sudo systemctl enable --now lumen-play.service
sudo systemctl start lumen-agent.service || true

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Listo:"
echo "  - DEVICE_ID=${DEVICE_ID}"
echo "  - PORT=${PORT}"
echo "  - Sincronización FTP y reproductor activados."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
