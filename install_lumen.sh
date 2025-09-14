#!/usr/bin/env bash
# install_lumen.sh — Instalador de la caja Lumen (Raspberry Pi, Bookworm headless)
# - Crea/usa clave SSH local
# - Autoriza Pi -> VPS (ssh-copy-id)  [pedirá la contraseña del VPS solo 1 vez]
# - Pide/recicla DEVICE_ID y PORT en el VPS (lumen-assign.sh)
# - Instala servicios systemd: autossh (túnel reverso) + agent (heartbeat)
# - Autoriza VPS -> Pi agregando la clave pública del VPS al authorized_keys de admin
# - ARRANCA servicios inmediatamente (primer latido automático)

set -euo pipefail

# --- Parámetros por defecto (los puedes cambiar aquí si quieres) ---
VPS_HOST="${VPS_HOST:-200.234.230.254}"
VPS_USER="${VPS_USER:-root}"
DEVICE_PREFIX="${DEVICE_PREFIX:-Box}"

# --- Usuario local ---
ME_USER="$(id -un)"
HOME_DIR="$HOME"

if [[ "$ME_USER" != "admin" ]]; then
  echo "[WARN] Estás instalando como '$ME_USER'. Este script asume el usuario 'admin'."
  echo "       Continuará, pero verifica rutas si cambiaste el usuario por defecto."
fi

echo "[1/9] Paquetes base…"
sudo apt-get update -y
sudo apt-get install -y \
  autossh openssh-client openssh-server jq rsync curl \
  python3 python3-pip vlc python3-vlc alsa-utils

echo "[2/9] Clave SSH local…"
mkdir -p "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"
if [[ ! -f "$HOME_DIR/.ssh/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$HOME_DIR/.ssh/id_ed25519"
fi

PUBKEY="$(cat "$HOME_DIR/.ssh/id_ed25519.pub")"
echo "IP/host del VPS [$VPS_HOST]: $VPS_HOST"
echo "Usuario del VPS  [$VPS_USER]: $VPS_USER"

echo "[3/9] Autorizar Pi→VPS (una vez)…"
# Pide pass del VPS solo en la primera caja; luego ya queda por llave
ssh-copy-id -i "$HOME_DIR/.ssh/id_ed25519.pub" -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" || true

# --- Config local ---
CONF_DIR="/etc/lumen"
CONF_FILE="$CONF_DIR/lumen.conf"
sudo mkdir -p "$CONF_DIR"

# Si ya hay config, la reutilizamos (idempotente)
DEVICE_ID=""
PORT=""

if [[ -f "$CONF_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONF_FILE" || true
  DEVICE_ID="${DEVICE_ID:-}"
  PORT="${PORT:-}"
fi

echo "[4/9] Obtener/reciclar DEVICE_ID y PORT desde el VPS…"
if [[ -n "${DEVICE_ID}" && -n "${PORT}" ]]; then
  echo "Reutilizando: DEVICE_ID=${DEVICE_ID} PORT=${PORT}"
else
  # Pedimos asignación al VPS (usa lumen-assign.sh en el VPS)
  ASSIGN_RAW="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" "lumen-assign.sh ${DEVICE_PREFIX}")" || true
  # Soportar salida en formato clave=valor o JSON
  if echo "$ASSIGN_RAW" | grep -q 'DEVICE_ID='; then
    DEVICE_ID="$(echo "$ASSIGN_RAW" | awk -F= '/DEVICE_ID=/{print $2}')"
    PORT="$(echo "$ASSIGN_RAW" | awk -F= '/PORT=/{print $2}')"
  else
    # Intento JSON: {"device_id":"Box-00","port":2201}
    DEVICE_ID="$(echo "$ASSIGN_RAW" | jq -r '.device_id // empty')"
    PORT="$(echo "$ASSIGN_RAW" | jq -r '.port // empty')"
  fi
  if [[ -z "${DEVICE_ID}" || -z "${PORT}" ]]; then
    echo "[ERROR] No pude obtener asignación del VPS. Salida fue:"
    echo "$ASSIGN_RAW"
    exit 1
  fi
fi

echo "[5/9] Guardar configuración…"
TMP_CONF="$(mktemp)"
cat > "$TMP_CONF" <<EOF
# /etc/lumen/lumen.conf
DEVICE_ID="${DEVICE_ID}"
VPS_HOST="${VPS_HOST}"
VPS_USER="${VPS_USER}"
PORT="${PORT}"

# Parámetros de reproducción (puedes afinarlos luego)
VOLUME="90"
XMAS_START="12-01"
XMAS_END="01-07"
SEASON_START=""
SEASON_END=""
ADS_SOURCE="Anuncios"
EOF
sudo mv "$TMP_CONF" "$CONF_FILE"
sudo chmod 644 "$CONF_FILE"

echo "[6/9] Autorizar VPS→Pi por túnel (para NO pedir password)…"
# Traer la clave pública del VPS y agregarla a authorized_keys del usuario actual
if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" 'test -r /root/.ssh/id_ed25519.pub'; then
  mkdir -p "$HOME_DIR/.ssh"
  chmod 700 "$HOME_DIR/.ssh"
  ssh -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" 'cat /root/.ssh/id_ed25519.pub' >> "$HOME_DIR/.ssh/authorized_keys" || true
  chmod 600 "$HOME_DIR/.ssh/authorized_keys"
  echo "[SSH] Autorizada clave del VPS para acceso inverso sin contraseña."
else
  echo "[SSH] Aviso: no encontré /root/.ssh/id_ed25519.pub en el VPS. El acceso VPS->Pi podría pedir password."
fi

echo "[7/9] Carpetas audio…"
mkdir -p "$HOME_DIR/Lumen/Canciones" "$HOME_DIR/Lumen/Anuncios" "$HOME_DIR/Lumen/Navideña" "$HOME_DIR/Lumen/Temporada"

echo "[8/9] Servicios systemd…"

# --- Binario del agente (heartbeat) ---
sudo tee /usr/local/bin/lumen-agent.sh >/dev/null <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
source /etc/lumen/lumen.conf

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Asegura carpeta en VPS y escribe timestamp
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" \
  "mkdir -p /srv/lumen/heartbeats && echo ${STAMP} > /srv/lumen/heartbeats/${DEVICE_ID}.ts"
AGENT
sudo chmod +x /usr/local/bin/lumen-agent.sh

# --- Servicio y timer del agente ---
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

# --- Servicio de autossh (túnel reverso) ---
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

echo "[9/9] Sudoers (NOPASSWD) para broadcast seguro…"
# Permitir que 'admin' ejecute oneliners comunes sin pedir password (opcional y acotado)
SUDO_FILE="/etc/sudoers.d/lumen-admin-nopasswd"
echo 'admin ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/systemctl, /usr/bin/journalctl, /usr/bin/curl, /usr/bin/rsync' | sudo tee "$SUDO_FILE" >/dev/null
sudo chmod 440 "$SUDO_FILE"

echo "[Activando servicios…]"
sudo systemctl daemon-reload
# Habilita y ARRANCA ahora mismo (primer latido automático)
sudo systemctl enable --now autossh-lumen.service
sudo systemctl enable --now lumen-agent.timer
# Dispara un primer latido inmediato
sudo systemctl start lumen-agent.service || true

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[OK]${STAMP}"
echo "Listo: DEVICE_ID=${DEVICE_ID}  PORT=${PORT}"
echo "Conéctate desde el VPS con:"
echo "  ssh -p ${PORT} admin@localhost"
