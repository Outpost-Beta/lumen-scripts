#!/usr/bin/env bash
# install_lumen.sh  —  Bootstrap de una Pi "Lumen"
# - Crea clave SSH, autoriza Pi→VPS (ssh-copy-id)
# - Pide asignación (DEVICE_ID/PORT) al VPS (sin awk)
# - Escribe /etc/lumen/lumen.conf
# - Autoriza VPS→Pi (agrega la llave pública del root del VPS a authorized_keys de admin)
# - Crea carpetas de audio
# - Instala servicios systemd: autossh + heartbeat (timer)

set -euo pipefail

# --- Parámetros por defecto (tu VPS) ---
VPS_HOST_DEFAULT="200.234.230.254"
VPS_USER_DEFAULT="root"

# --- Usuario local (Pi) ---
PI_USER="${SUDO_USER:-$USER}"
PI_HOME="$(eval echo ~${PI_USER})"

if [[ "$EUID" -eq 0 ]]; then
  echo "⚠️  Ejecuta este script como usuario normal (p.ej. 'admin'), NO como root."
  echo "    Ejemplo:  ./install_lumen.sh"
  exit 1
fi

echo "[1/9] Paquetes base…"
sudo apt-get update -y
sudo apt-get install -y autossh openssh-client openssh-server \
  python3 python3-pip jq rsync alsa-utils vlc python3-vlc sshpass

echo "[2/9] Clave SSH local…"
mkdir -p "${PI_HOME}/.ssh"
chmod 700 "${PI_HOME}/.ssh"
if [[ ! -f "${PI_HOME}/.ssh/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -f "${PI_HOME}/.ssh/id_ed25519" -N "" -C "${PI_USER}@$(hostname -s)"
fi
eval "$(ssh-agent -s)" >/dev/null 2>&1 || true
ssh-add "${PI_HOME}/.ssh/id_ed25519" >/dev/null 2>&1 || true

read -r -p "IP/host del VPS [${VPS_HOST_DEFAULT}]: " VPS_HOST
VPS_HOST="${VPS_HOST:-$VPS_HOST_DEFAULT}"
read -r -p "Usuario del VPS [${VPS_USER_DEFAULT}]: " VPS_USER
VPS_USER="${VPS_USER:-$VPS_USER_DEFAULT}"

echo "[3/9] Autorizar Pi→VPS (una vez)…"
ssh -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" true || true
ssh-copy-id -i "${PI_HOME}/.ssh/id_ed25519.pub" "${VPS_USER}@${VPS_HOST}" || true

echo "[4/9] Obtener/reciclar DEVICE_ID y PORT desde el VPS…"
ASSIGN="$(ssh -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" '/usr/local/bin/lumen-assign.sh' 2>/dev/null || true)"

# Parseo SIN awk (robusto)
DEVICE_ID="$(printf '%s\n' "$ASSIGN" | tr ' ' '\n' | sed -n 's/^DEVICE_ID=\(.*\)$/\1/p')"
PORT="$(printf '%s\n' "$ASSIGN" | tr ' ' '\n' | sed -n 's/^PORT=\([0-9]\+\)$/\1/p')"

if [[ -z "${DEVICE_ID:-}" || -z "${PORT:-}" ]]; then
  echo "❌ No pude obtener asignación del VPS. Respuesta: '$ASSIGN'"
  echo "Verifica que el VPS tenga instalado lumen-assign.sh y /srv/lumen/devices.tsv."
  exit 1
fi
echo "Asignado: DEVICE_ID=${DEVICE_ID}  PORT=${PORT}"

echo "[5/9] Guardar configuración…"
sudo install -d -m 0755 /etc/lumen
sudo tee /etc/lumen/lumen.conf >/dev/null <<EOF
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
EOF

echo "[6/9] Autorizar VPS→Pi por túnel (para ssh -p \$PORT admin@localhost en el VPS)…"
# Tomamos la llave pública del root del VPS y la agregamos si no está
VPS_PUB="$(ssh -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" 'test -f ~/.ssh/id_ed25519.pub && cat ~/.ssh/id_ed25519.pub || true')"
if [[ -n "${VPS_PUB}" ]]; then
  AUTH_KEYS="${PI_HOME}/.ssh/authorized_keys"
  touch "${AUTH_KEYS}"; chmod 600 "${AUTH_KEYS}"
  if ! grep -qF "${VPS_PUB}" "${AUTH_KEYS}"; then
    echo "${VPS_PUB}" >> "${AUTH_KEYS}"
  fi
fi

echo "[7/9] Carpetas de audio…"
mkdir -p "${PI_HOME}/Lumen"/{Canciones,Anuncios,Navideña,Temporada}

echo "[8/9] Agente de heartbeat…"
/usr/bin/sudo tee /usr/local/bin/lumen-agent.sh >/dev/null <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
CFG="/etc/lumen/lumen.conf"
. "$CFG"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Escribimos el heartbeat en el VPS
ssh -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" \
  "mkdir -p /srv/lumen/heartbeats && echo ${STAMP} > /srv/lumen/heartbeats/${DEVICE_ID}.ts"
AGENT
sudo chmod +x /usr/local/bin/lumen-agent.sh

echo "[9/9] Servicios systemd…"
# autossh (túnel inverso)
sudo tee /etc/systemd/system/autossh-lumen.service >/dev/null <<'UNIT'
[Unit]
Description=Reverse SSH tunnel to VPS (Lumen)
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/lumen/lumen.conf
User=admin
ExecStart=/usr/bin/autossh -M 0 -N \
  -o "ServerAliveInterval=30" -o "ServerAliveCountMax=3" \
  -o "StrictHostKeyChecking=accept-new" \
  -R 127.0.0.1:${PORT}:127.0.0.1:22 ${VPS_USER}@${VPS_HOST}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# heartbeat (cada minuto)
sudo tee /etc/systemd/system/lumen-agent.service >/dev/null <<'UNIT'
[Unit]
Description=Lumen heartbeat agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/lumen/lumen.conf
User=admin
ExecStart=/usr/local/bin/lumen-agent.sh
UNIT

sudo tee /etc/systemd/system/lumen-agent.timer >/dev/null <<'UNIT'
[Unit]
Description=Run lumen-agent every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Unit=lumen-agent.service

[Install]
WantedBy=timers.target
UNIT

echo "[Activando servicios…]"
sudo systemctl daemon-reload
sudo systemctl enable --now autossh-lumen.service
sudo systemctl enable --now lumen-agent.timer

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "${STAMP}✅ Listo: DEVICE_ID=${DEVICE_ID}  PORT=${PORT}"
echo "Conéctate desde el VPS con:"
echo "  ssh -p ${PORT} ${PI_USER}@localhost"
