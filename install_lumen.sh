#!/usr/bin/env bash
# install_lumen.sh  — Instalador de la Pi (sin OneDrive)
# - Fija VPS_HOST/VPS_USER (sin prompts)
# - Genera clave SSH, autoriza Pi→VPS (pedirá password del VPS sólo 1a vez)
# - Solicita/recicla DEVICE_ID y PORT al VPS
# - Crea servicios: autossh (túnel reverso) + heartbeat (timer)
# - Prepara carpetas de audio Lumen
# - Idempotente: se puede correr de nuevo sin romper nada

set -euo pipefail

# ---------- PARÁMETROS FIJOS DEL VPS (sin preguntas) ----------
VPS_HOST="${VPS_HOST:-200.234.230.254}"
VPS_USER="${VPS_USER:-root}"

# ---------- CHEQUEOS BÁSICOS ----------
if [[ "$EUID" -eq 0 ]]; then
  echo "Por seguridad, ejecuta este script como usuario normal (p.ej. 'admin'), no como root."
  exit 1
fi

echo "[1/9] Paquetes base…"
sudo apt-get update -y
sudo apt-get install -y autossh openssh-client openssh-server python3 python3-pip \
  vlc python3-vlc alsa-utils jq rsync

# ---------- USUARIO Y RUTAS ----------
ME="$(id -un)"
HOME_DIR="$HOME"

# ---------- SSH KEY LOCAL ----------
echo "[2/9] Clave SSH local…"
mkdir -p "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"
if [[ ! -f "$HOME_DIR/.ssh/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$HOME_DIR/.ssh/id_ed25519" -C "${ME}@$(hostname -s)" >/dev/null
fi
chmod 600 "$HOME_DIR/.ssh/id_ed25519"*
# Aceptar host key del VPS la primera vez
ssh -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" true || true

echo "[3/9] Autorizar Pi→VPS (una vez)…"
# Copia la clave pública (pedirá password del VPS sólo la primera vez)
ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$HOME_DIR/.ssh/id_ed25519.pub" "${VPS_USER}@${VPS_HOST}" || true

# ---------- ASIGNACIÓN DEVICE_ID / PORT DESDE VPS ----------
echo "[4/9] Obtener/reciclar DEVICE_ID y PORT desde el VPS…"
HOSTNAME_SHORT="$(hostname -s)"
ASSIGN_OUT="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  "${VPS_USER}@${VPS_HOST}" "/usr/local/bin/lumen-assign.sh '${HOSTNAME_SHORT}'" 2>/dev/null || true)"

# Formatos aceptados: "DEVICE_ID=Box-00 PORT=2201" o dos líneas con esas claves.
DEVICE_ID="$(echo "$ASSIGN_OUT" | awk -F= '/DEVICE_ID/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | head -n1)"
PORT="$(echo "$ASSIGN_OUT" | awk -F= '/PORT/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | head -n1)"

# Si no llegó nada, intenta reciclar config previa
if [[ -z "${DEVICE_ID:-}" || -z "${PORT:-}" ]]; then
  if [[ -f /etc/lumen/lumen.conf ]]; then
    # shellcheck disable=SC1091
    source /etc/lumen/lumen.conf || true
  fi
fi

if [[ -z "${DEVICE_ID:-}" || -z "${PORT:-}" ]]; then
  echo "No se pudieron obtener DEVICE_ID/PORT desde el VPS. Revisa que '/usr/local/bin/lumen-assign.sh' exista en el VPS."
  echo "Salida de asignación: $ASSIGN_OUT"
  exit 1
fi

echo "Reutilizando/asignado: DEVICE_ID=${DEVICE_ID} PORT=${PORT}"

# ---------- GUARDAR CONFIG DE LA PI ----------
echo "[5/9] Guardar configuración…"
sudo mkdir -p /etc/lumen
sudo tee /etc/lumen/lumen.conf >/dev/null <<EOF
DEVICE_ID="${DEVICE_ID}"
VPS_HOST="${VPS_HOST}"
VPS_USER="${VPS_USER}"
PORT="${PORT}"
VOLUME="${VOLUME:-90}"
XMAS_START="${XMAS_START:-12-01}"
XMAS_END="${XMAS_END:-01-07}"
SEASON_START="${SEASON_START:-}"
SEASON_END="${SEASON_END:-}"
ADS_SOURCE="${ADS_SOURCE:-Anuncios}"
EOF

# ---------- AUTORIZAR VPS → Pi POR EL TÚNEL (opcional pero útil para comandos desde el VPS) ----------
echo "[6/9] Autorizar VPS→Pi por túnel…"
# Trae la clave pública del VPS y agrégala al authorized_keys local si no está
VPS_PUB="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" "cat ~/.ssh/id_ed25519.pub" 2>/dev/null || true)"
if [[ -n "$VPS_PUB" ]]; then
  grep -qxF "$VPS_PUB" "$HOME_DIR/.ssh/authorized_keys" 2>/dev/null || {
    echo "$VPS_PUB" >> "$HOME_DIR/.ssh/authorized_keys"
    chmod 600 "$HOME_DIR/.ssh/authorized_keys"
  }
fi

# ---------- CARPETAS DE AUDIO ----------
echo "[7/9] Carpetas de audio…"
mkdir -p "$HOME_DIR/Lumen"/{Canciones,Anuncios,Navideña,Temporada}

# ---------- INSTALAR AGENTE DE HEARTBEAT ----------
echo "[8/9] Agente de heartbeat…"
sudo tee /usr/local/bin/lumen-agent.sh >/dev/null <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen/lumen.conf"
# shellcheck disable=SC1091
source "$CONF"
STAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
# crea carpeta en el VPS y escribe el timestamp
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" \
  "mkdir -p /srv/lumen/heartbeats && echo '${STAMP}' > /srv/lumen/heartbeats/${DEVICE_ID}.ts"
logger -t lumen-agent "Heartbeat ${STAMP}"
AGENT
sudo chmod +x /usr/local/bin/lumen-agent.sh

# Service (oneshot) + timer cada 60s
sudo tee /etc/systemd/system/lumen-agent.service >/dev/null <<'UNIT'
[Unit]
Description=Lumen Heartbeat Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lumen-agent.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
UNIT

sudo tee /etc/systemd/system/lumen-agent.timer >/dev/null <<'TIMER'
[Unit]
Description=Lumen Heartbeat Timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
TIMER

# ---------- SERVICIO AUTOSSH (TÚNEL REVERSO) ----------
echo "[9/9] Servicio de túnel reverso…"
sudo tee /etc/systemd/system/autossh-lumen.service >/dev/null <<'SVC'
[Unit]
Description=AutoSSH reverse tunnel to VPS
After=network-online.target
Wants=network-online.target

[Service]
User=__ADMIN__
EnvironmentFile=/etc/lumen/lumen.conf
WorkingDirectory=__HOME__
Environment="HOME=__HOME__"
# Mantener vivo el túnel y aceptar hostkey la primera vez
ExecStart=/usr/bin/autossh -M 0 -N \
  -o "ServerAliveInterval=30" -o "ServerAliveCountMax=3" \
  -o "ExitOnForwardFailure=yes" \
  -o "StrictHostKeyChecking=accept-new" \
  -R 127.0.0.1:${PORT}:127.0.0.1:22 ${VPS_USER}@${VPS_HOST}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC
# Rellenar placeholders de usuario/home en la unidad
sudo sed -i "s|__ADMIN__|${ME}|g; s|__HOME__|${HOME_DIR}|g" /etc/systemd/system/autossh-lumen.service

# ---------- SUDOERS (NOPASSWD) PARA OPERACIONES BÁSICAS ----------
# Permite que 'admin' controle estos servicios sin pedir password (útil para broadcast desde VPS)
if [[ -n "${ME}" ]]; then
  echo "${ME} ALL=(ALL) NOPASSWD:/bin/systemctl start autossh-lumen.service,/bin/systemctl restart autossh-lumen.service,/bin/systemctl start lumen-agent.timer,/bin/systemctl restart lumen-agent.timer" | sudo tee /etc/sudoers.d/99-lumen >/dev/null
  sudo chmod 440 /etc/sudoers.d/99-lumen
fi

# ---------- HABILITAR SERVICIOS ----------
echo "[Activando servicios…]"
sudo systemctl daemon-reload
sudo systemctl enable --now autossh-lumen.service
sudo systemctl enable --now lumen-agent.timer

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ")✅ Listo: DEVICE_ID=${DEVICE_ID}  PORT=${PORT}"
echo "Conéctate desde el VPS con:"
echo "  ssh -p ${PORT} ${ME}@localhost"
