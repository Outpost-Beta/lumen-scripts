#!/usr/bin/env bash
# install_lumen.sh — Provisiona una Raspberry Pi (Bookworm, headless) como “Caja Lumen”
# - Túnel SSH inverso vía autossh (sin abrir puertos)
# - Asignación determinística (Box-00@2201, Box-01@2202, …) desde el VPS
# - Heartbeat cada 60s visible en el VPS
# - Carpetas de audio ~/Lumen/{Canciones,Anuncios,Navideña,Temporada}
# - Integra OneDrive (abraunegg) cada 5 min si existe bundle en el VPS

set -euo pipefail

# --- Parámetros por defecto (se pueden sobreescribir con /etc/lumen/lumen.conf) ---
VPS_HOST="${LUMEN_VPS_HOST:-200.234.230.254}"
VPS_USER="${LUMEN_VPS_USER:-root}"
DEVICE_ID=""
PORT=""
VOLUME="${LUMEN_VOLUME:-90}"
XMAS_START="${LUMEN_XMAS_START:-12-01}"
XMAS_END="${LUMEN_XMAS_END:-01-07}"
SEASON_START="${LUMEN_SEASON_START:-}"
SEASON_END="${LUMEN_SEASON_END:-}"
ADS_SOURCE="${LUMEN_ADS_SOURCE:-Anuncios}"

CONF_DIR="/etc/lumen"
CONF_FILE="${CONF_DIR}/lumen.conf"
AGENT_BIN="/usr/local/bin/lumen-agent.sh"

require_rootless() {
  if [[ "$(id -u)" -eq 0 ]]; then
    echo "Ejecuta este instalador como tu usuario normal (p.ej. 'admin'), NO como root."
    exit 1
  fi
}
require_sudo() {
  if ! sudo -n true 2>/dev/null; then
    echo "Se requiere 'sudo'. Te pediré contraseña cuando sea necesario."
  fi
}

apt_install() {
  echo "[1/9] Paquetes base…"
  sudo apt-get update -y
  sudo apt-get install -y \
    autossh openssh-client openssh-server \
    python3 python3-pip jq rsync alsa-utils vlc python3-vlc \
    curl git
}

ensure_ssh_key() {
  echo "[2/9] Clave SSH local…"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "$(whoami)@$(hostnamectl --static)"
  fi
}

load_or_init_conf() {
  echo "[3/9] Configuración local…"
  sudo mkdir -p "$CONF_DIR"
  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
  else
    cat <<CFG | sudo tee "$CONF_FILE" >/dev/null
DEVICE_ID="${DEVICE_ID}"
VPS_HOST="${VPS_HOST}"
VPS_USER="${VPS_USER}"
PORT="${PORT}"
VOLUME="${VOLUME}"
XMAS_START="${XMAS_START}"
XMAS_END="${XMAS_END}"
SEASON_START="${SEASON_START}"
SEASON_END="${SEASON_END}"
ADS_SOURCE="${ADS_SOURCE}"
CFG
    sudo chmod 644 "$CONF_FILE"
  fi
}

authorize_pi_to_vps() {
  echo "[4/9] Autorizar Pi→VPS (ssh-copy-id, una sola vez)…"
  # Intentará agregar clave si aún no existe en el VPS (puede pedir PWD del VPS)
  /usr/bin/ssh-copy-id -i "$HOME/.ssh/id_ed25519.pub" -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_HOST}" || true
}

assign_device_port() {
  echo "[5/9] Obtener/reciclar DEVICE_ID y PORT desde el VPS…"
  local host
  host="$(hostnamectl --static)"
  # Llama al asignador del VPS; debe devolver "DEVICE_ID=... PORT=..."
  # Nota: lumen-assign.sh vive en el VPS y usa /srv/lumen/devices.tsv
  local out
  if ! out="$(ssh -o StrictHostKeyChecking=accept-new -i "$HOME/.ssh/id_ed25519" "${VPS_USER}@${VPS_HOST}" "lumen-assign.sh '${host}'" 2>/dev/null)"; then
    echo "No pude contactar al asignador en el VPS. Revisa conectividad."
    exit 1
  fi
  # Parseo robusto
  DEVICE_ID="$(awk '{for(i=1;i<=NF;i++){ if($i ~ /^DEVICE_ID=/){split($i,a,"="); print a[2] }}}' <<<"$out")"
  PORT="$(awk '{for(i=1;i<=NF;i++){ if($i ~ /^PORT=/){split($i,a,"="); print a[2] }}}' <<<"$out")"

  if [[ -z "${DEVICE_ID}" || -z "${PORT}" ]]; then
    echo "Asignación inválida desde VPS: $out"
    exit 1
  fi
  echo "Reutilizando/Asignado: DEVICE_ID=${DEVICE_ID} PORT=${PORT}"

  # Persistir
  sudo tee "$CONF_FILE" >/dev/null <<CFG
DEVICE_ID="${DEVICE_ID}"
VPS_HOST="${VPS_HOST}"
VPS_USER="${VPS_USER}"
PORT="${PORT}"
VOLUME="${VOLUME}"
XMAS_START="${XMAS_START}"
XMAS_END="${XMAS_END}"
SEASON_START="${SEASON_START}"
SEASON_END="${SEASON_END}"
ADS_SOURCE="${ADS_SOURCE}"
CFG
}

setup_autossh_service() {
  echo "[6/9] Servicio autossh (túnel inverso)…"
  sudo tee /etc/systemd/system/autossh-lumen.service >/dev/null <<UNIT
[Unit]
Description=Lumen reverse SSH tunnel (Pi -> VPS)
After=network-online.target
Wants=network-online.target

[Service]
Environment=AUTOSSH_GATETIME=0
Environment=AUTOSSH_PORT=0
ExecStart=/usr/bin/autossh -N -M 0 \\
  -o "ServerAliveInterval=30" -o "ServerAliveCountMax=3" \\
  -o "StrictHostKeyChecking=accept-new" \\
  -i /home/$(whoami)/.ssh/id_ed25519 \\
  -R ${PORT}:localhost:22 ${VPS_USER}@${VPS_HOST}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now autossh-lumen.service
}

setup_agent() {
  echo "[7/9] Agente de heartbeat…"
  sudo tee "$AGENT_BIN" >/dev/null <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen/lumen.conf"
source "$CONF"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Crea carpeta y escribe timestamp de latido en el VPS
ssh -o StrictHostKeyChecking=accept-new -i "/home/${SUDO_USER:-$USER}/.ssh/id_ed25519" "${VPS_USER}@${VPS_HOST}" \
"mkdir -p /srv/lumen/heartbeats && printf '%s\n' '${STAMP}' > /srv/lumen/heartbeats/${DEVICE_ID}.ts" \
  && logger -t lumen-agent "Heartbeat OK: ${STAMP}" \
  || logger -t lumen-agent "Heartbeat FAIL"
AGENT
  sudo chmod +x "$AGENT_BIN"

  sudo tee /etc/systemd/system/lumen-agent.service >/dev/null <<UNIT
[Unit]
Description=Lumen heartbeat agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${AGENT_BIN}
User=$(whoami)
Group=$(whoami)

[Install]
WantedBy=multi-user.target
UNIT

  sudo tee /etc/systemd/system/lumen-agent.timer >/dev/null <<UNIT
[Unit]
Description=Run Lumen heartbeat every minute

[Timer]
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true
Unit=lumen-agent.service

[Install]
WantedBy=timers.target
UNIT

  sudo systemctl daemon-reload
  sudo systemctl enable --now lumen-agent.timer
}

make_audio_folders() {
  echo "[8/9] Carpetas de audio…"
  mkdir -p "$HOME/Lumen/Canciones" "$HOME/Lumen/Anuncios" "$HOME/Lumen/Navideña" "$HOME/Lumen/Temporada"
}

sudoers_broadcast() {
  echo "[9/9] Sudoers (NOPASSWD) para broadcast seguro…"
  # Permite que el VPS ejecute comandos comunes sin pedir password (ajusta a tus necesidades)
  local SNIP="/etc/sudoers.d/lumen"
  sudo bash -c "cat > '$SNIP' <<'SUDO'
# Permitir reinicios y onedrive sin password para el usuario actual
$(whoami) ALL=(ALL) NOPASSWD:/usr/sbin/reboot,/usr/bin/systemctl start onedrive-lumen.service,/usr/bin/systemctl restart onedrive-lumen.timer,/usr/bin/systemctl start onedrive-lumen.timer
SUDO"
  sudo chmod 440 "$SNIP"
}

maybe_onedrive() {
  echo "[+] Integración OneDrive (si hay bundle en VPS)…"
  # Instala/actualiza onedrive cliente + servicio/timer
  if [[ -x "./install_onedrive_native_pi.sh" ]]; then
    sudo ./install_onedrive_native_pi.sh
  fi

  # Si en el VPS existe un bundle global, empujar tokens y arrancar
  if ssh -o StrictHostKeyChecking=accept-new -i "$HOME/.ssh/id_ed25519" "${VPS_USER}@${VPS_HOST}" 'test -f /srv/lumen/onedrive_tokens/Lumen_bundle.tar.gz'; then
    echo "[OneDrive] Bundle encontrado en VPS. Empujando tokens…"
    ssh -o StrictHostKeyChecking=accept-new -i "$HOME/.ssh/id_ed25519" "${VPS_USER}@${VPS_HOST}" \
      "lumen-push-token.sh '${DEVICE_ID}' '${PORT}'" || true
    # Asegura timer arriba
    sudo systemctl enable --now onedrive-lumen.timer || true
  else
    echo "[OneDrive] No hay bundle en el VPS. Opciones:"
    echo "  - (Recomendado) Coloca /srv/lumen/onedrive_tokens/Lumen_bundle.tar.gz en el VPS y ejecuta:"
    echo "      lumen-push-token.sh '${DEVICE_ID}' '${PORT}'"
    echo "  - (Manual en esta Pi) Autoriza con:"
    echo "      onedrive   # seguirá prompts (crea ~/.config/onedrive)"
  fi
}

summary() {
  echo
  date -u +%Y-%m-%dT%H:%M:%SZ | sed "s/^/[OK]/"
  echo "Listo: DEVICE_ID=${DEVICE_ID}  PORT=${PORT}"
  echo "Conéctate desde el VPS con:"
  echo "  ssh -p ${PORT} $(whoami)@localhost"
}

# --- flujo principal ---
require_rootless
require_sudo
apt_install
ensure_ssh_key
load_or_init_conf
authorize_pi_to_vps
assign_device_port
setup_autossh_service
setup_agent
make_audio_folders
sudoers_broadcast
maybe_onedrive
summary
