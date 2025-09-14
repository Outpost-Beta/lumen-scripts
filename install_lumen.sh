#!/usr/bin/env bash
# install_lumen.sh  (Raspberry Pi • SOLO Lumen • sin OneDrive)
# Raspberry Pi OS Bookworm Lite
set -euo pipefail

# --- Parámetros por defecto (puedes cambiarlos aquí si quieres) ---
VPS_HOST_DEFAULT="200.234.230.254"
VPS_USER_DEFAULT="root"
AUDIO_ROOT="$HOME/Lumen"
CONF_DIR="/etc/lumen"
CONF_FILE="$CONF_DIR/lumen.conf"

echo "[1/9] Paquetes base…"
sudo apt-get update -y
sudo apt-get install -y autossh openssh-client openssh-server python3 python3-pip vlc python3-vlc alsa-utils jq rsync sshpass

# Asegura sshd local (por si viene deshabilitado)
sudo systemctl enable --now ssh

echo "[2/9] Clave SSH local…"
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "admin@$(hostname -s)"
fi

# --- Pregunta o toma variables para el VPS ---
read -rp "IP/host del VPS [${VPS_HOST_DEFAULT}]: " VPS_HOST_IN || true
VPS_HOST="${VPS_HOST_IN:-$VPS_HOST_DEFAULT}"

read -rp "Usuario del VPS [${VPS_USER_DEFAULT}]: " VPS_USER_IN || true
VPS_USER="${VPS_USER_IN:-$VPS_USER_DEFAULT}"

echo "[3/9] Autorizar Pi→VPS (una vez)…"
/usr/bin/ssh-copy-id -i "$HOME/.ssh/id_ed25519.pub" -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" || true

echo "[4/9] Obtener/reciclar DEVICE_ID y PORT desde el VPS…"
ASSIGN_OUT="$(ssh -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" "/usr/local/bin/lumen-assign.sh $(hostname -s)")"
# Espera algo como:  DEVICE_ID=Box-00 PORT=2201
DEVICE_ID="$(awk '{for(i=1;i<=NF;i++){if($i~^"DEVICE_ID="){split($i,a,"=");print a[2]}}}' <<<"$ASSIGN_OUT")"
PORT="$(awk '{for(i=1;i<=NF;i++){if($i~^"PORT="){split($i,a,"=");print a[2]}}}' <<<"$ASSIGN_OUT")"

if [[ -z "${DEVICE_ID:-}" || -z "${PORT:-}" ]]; then
  echo "ERROR: no pude obtener asignación del VPS. Salida: $ASSIGN_OUT" >&2
  exit 1
fi
echo "Reutilizando: DEVICE_ID=${DEVICE_ID} PORT=${PORT}"

echo "[5/9] Guardar configuración…"
sudo mkdir -p "$CONF_DIR"
sudo tee "$CONF_FILE" >/dev/null <<EOF
# /etc/lumen/lumen.conf
DEVICE_ID="${DEVICE_ID}"
VPS_HOST="${VPS_HOST}"
VPS_USER="${VPS_USER}"
PORT="${PORT}"
# Volumen por defecto (0-100) para el reproductor (si lo usas después)
VOLUME="90"
# Programación estacional (placeholders; no usados en este instalador)
XMAS_START="12-01"
XMAS_END="01-07"
SEASON_START=""
SEASON_END=""
ADS_SOURCE="Anuncios"
EOF

echo "[6/9] Autorizar VPS→Pi por túnel…"
# Permitimos que el VPS entre como root al puerto reverso sin preguntar hostkey
# (El VPS agregará esta llave a su known_hosts cuando se conecte la primera vez.)
cat "$HOME/.ssh/id_ed25519.pub" | ssh "${VPS_USER}@${VPS_HOST}" "mkdir -p /srv/lumen/keys && cat > /srv/lumen/keys/${DEVICE_ID}.pub"

echo "[7/9] Carpetas de audio…"
mkdir -p "${AUDIO_ROOT}/"{Canciones,Anuncios,Navideña,Temporada}

echo "[8/9] Servicios systemd…"
# --- servicio autossh (túnel reverso) ---
sudo tee /etc/systemd/system/autossh-lumen.service >/dev/null <<UNIT
[Unit]
Description=Lumen reverse SSH tunnel to VPS
After=network-online.target
Wants=network-online.target

[Service]
Environment=AUTOSSH_GATETIME=0
Environment=AUTOSSH_POLL=30
Environment=AUTOSSH_FIRST_POLL=30
Type=simple
User=${USER}
ExecStart=/usr/bin/autossh -M 0 -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -R 127.0.0.1:${PORT}:127.0.0.1:22 ${VPS_USER}@${VPS_HOST}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# --- agente de heartbeat (script + service + timer) ---
sudo tee /usr/local/bin/lumen-agent.sh >/dev/null <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen/lumen.conf"
source "$CONF"

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Crea carpeta y escribe timestamp en el VPS
ssh -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" \
  "mkdir -p /srv/lumen/heartbeats && printf '%s\n' '${STAMP}' > /srv/lumen/heartbeats/${DEVICE_ID}.ts" \
  && logger -t lumen-agent "Heartbeat OK: ${STAMP}" \
  || logger -t lumen-agent "Heartbeat FAIL"
AGENT
sudo chmod +x /usr/local/bin/lumen-agent.sh

sudo tee /etc/systemd/system/lumen-agent.service >/dev/null <<'UNIT'
[Unit]
Description=Lumen heartbeat agent
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lumen-agent.sh
UNIT

sudo tee /etc/systemd/system/lumen-agent.timer >/dev/null <<'UNIT'
[Unit]
Description=Run Lumen heartbeat every minute

[Timer]
OnBootSec=60
OnUnitActiveSec=60
Unit=lumen-agent.service

[Install]
WantedBy=timers.target
UNIT

echo "[9/9] Sudoers (NOPASSWD) para broadcast seguro…"
# Permite a root del VPS ejecutar comandos sin password a través del túnel (solo necesarios para lumen-broadcast)
echo "${USER} ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/010_${USER}_nopasswd >/dev/null
sudo chmod 440 /etc/sudoers.d/010_${USER}_nopasswd

echo "[Activando servicios…]"
sudo systemctl daemon-reload
sudo systemctl enable --now autossh-lumen.service
sudo systemctl enable --now lumen-agent.timer

# Primer heartbeat inmediato (no bloqueante si falla)
if /usr/local/bin/lumen-agent.sh 2>/dev/null; then
  :
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)✅ Listo: DEVICE_ID=${DEVICE_ID}  PORT=${PORT}"
echo "Conéctate desde el VPS con:"
echo "  ssh -p ${PORT} ${USER}@localhost"
