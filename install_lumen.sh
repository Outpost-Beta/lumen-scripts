#!/usr/bin/env bash
# install_lumen.sh — Instalador de la caja Lumen (Raspberry Pi, Bookworm headless)
# Corrección incluida:
#  - Parseo robusto de la salida "DEVICE_ID=... PORT=..." de lumen-assign.sh
#  - Uso de hostname único para asignación
#  - Asegura /etc/hosts (127.0.1.1 <hostname>) para evitar "sudo: unable to resolve host"
#  - Servicios: autossh (túnel reverso) + lumen-agent (heartbeat)

set -euo pipefail

# --- Parámetros por defecto (puedes exportarlos antes de ejecutar) ---
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

echo "[3/10] Autorizar Pi→VPS (una vez)…"
ssh-copy-id -i "$HOME_DIR/.ssh/id_ed25519.pub" -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" || true

# --- Config local ---
CONF_DIR="/etc/lumen"
CONF_FILE="$CONF_DIR/lumen.conf"
sudo mkdir -p "$CONF_DIR"

# Reutiliza si ya existe
DEVICE_ID=""
PORT=""
if [[ -f "$CONF_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONF_FILE" || true
  DEVICE_ID="${DEVICE_ID:-}"
  PORT="${PORT:-}"
fi

# --- Asegurar /etc/hosts para el hostname actual (evita 'sudo: unable to resolve host') ---
echo "[4/10] Verificando /etc/hosts…"
HOST_UNICO="$(hostnamectl --static 2>/dev/null || hostname -s)"
if ! grep -qE "^127\.0\.1\.1[[:space:]]+${HOST_UNICO}(\s|$)" /etc/hosts; then
  echo "127.0.1.1 ${HOST_UNICO}" | sudo tee -a /etc/hosts >/dev/null
fi

echo "[5/10] Obtener/reciclar DEVICE_ID y PORT desde el VPS…"
if [[ -n "${DEVICE_ID}" && -n "${PORT}" ]]; then
  echo "Reutilizando: DEVICE_ID=${DEVICE_ID} PORT=${PORT}"
else
  # Pide asignación usando el hostname ÚNICO
  ASSIGN_RAW="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" "lumen-assign.sh ${HOST_UNICO}")" || true

  # Formatos soportados:
  #  a) "DEVICE_ID=Box-00 PORT=2201"
  #  b) JSON: {"device_id":"Box-00","port":2201}
  # Extrae de forma robusta SIN capturar el ' PORT=' en DEVICE_ID
  DEVICE_ID="$(sed -n 's/.*DEVICE_ID=\([^[:space:]]*\).*/\1/p' <<<"$ASSIGN_RAW")"
  PORT="$(sed -n 's/.*PORT=\([0-9]\+\).*/\1/p' <<<"$ASSIGN_RAW")"

  # Si no funcionó, intenta JSON
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

echo "[7/10] Carpetas de audio…"
mkdir -p "$HOME_DIR/Lumen/Canciones" "$HOME_DIR/Lumen/Anuncios" "$HOME_DIR/Lumen/Navideña" "$HOME_DIR/Lumen/Temporada"

echo "[8/10] Instalar scripts/servicios…"

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

echo "[9/10] Sudoers (NOPASSWD) para broadcast…"
SUDO_FILE="/etc/sudoers.d/lumen-admin-nopasswd"
echo 'admin ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/systemctl, /usr/bin/journalctl, /usr/bin/curl, /usr/bin/rsync' | sudo tee "$SUDO_FILE" >/dev/null
sudo chmod 440 "$SUDO_FILE"

echo "[10/10] Activando servicios…"
sudo systemctl daemon-reload
sudo systemctl enable --now autossh-lumen.service
sudo systemctl enable --now lumen-agent.timer
sudo systemctl start lumen-agent.service || true

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[OK]${STAMP}"
echo "Listo: DEVICE_ID=${DEVICE_ID}  PORT=${PORT}"
echo "Conéctate desde el VPS con:"
echo "  ssh -p ${PORT} admin@localhost"
