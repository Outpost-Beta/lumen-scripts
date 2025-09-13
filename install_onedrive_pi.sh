#!/usr/bin/env bash
set -euo pipefail

# === Parámetros y rutas ===
PI_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$PI_USER" | cut -d: -f6)"
LOCAL_DIR="$HOME_DIR/Lumen"             # Carpeta que ya usa tu player
REMOTE_NAME="onedrive"
REMOTE_PATH="Lumen"                     # Carpeta en OneDrive
REMOTE_URI="${REMOTE_NAME}:/${REMOTE_PATH}"
LOG_FILE="$HOME_DIR/rclone-bisync.log"
STATE_FLAG="/var/lib/lumen/bisync_initialized"

# === 1) Paquetes base ===
sudo apt-get update -y
sudo apt-get install -y rclone util-linux ca-certificates
mkdir -p "$LOCAL_DIR"
sudo mkdir -p "$(dirname "$STATE_FLAG")" && sudo chown "$PI_USER:$PI_USER" "$(dirname "$STATE_FLAG")"

# === 2) Ignorados opcionales (.rcloneignore) ===
if [[ ! -f "$LOCAL_DIR/.rcloneignore" ]]; then
  cat > "$LOCAL_DIR/.rcloneignore" <<'EOF'
.DS_Store
Thumbs.db
~$*
*.tmp
*.part
*.swp
EOF
fi

# === 3) Helper: setear token headless (rclone_set_token.sh) ===
sudo tee /usr/local/bin/rclone_set_token.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail
PI_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$PI_USER" | cut -d: -f6)"
CONF_DIR="$HOME_DIR/.config/rclone"
mkdir -p "$CONF_DIR"
TOKEN_B64="${1:-}"
[[ -n "$TOKEN_B64" ]] || { echo "Falta TOKEN_JSON_BASE64"; exit 2; }
TOKEN_JSON="$(printf '%s' "$TOKEN_B64" | base64 -d)"
export RCLONE_CONFIG="$CONF_DIR/rclone.conf"

if rclone config create onedrive onedrive token "$TOKEN_JSON" --non-interactive >/dev/null 2>&1; then
  echo "[OK] Remoto 'onedrive' creado."
else
  rclone config reconnect onedrive: --non-interactive <<EOF >/dev/null 2>&1 || true
y
EOF
  echo "[OK] Remoto 'onedrive' actualizado (reconnect)."
fi

chown -R "$PI_USER:$PI_USER" "$CONF_DIR"
# Prueba ligera
rclone lsd onedrive:/ >/dev/null 2>&1 || true
SH
sudo chmod +x /usr/local/bin/rclone_set_token.sh

# === 4) Script de bisync con detección de 'primer run' (usa --resync) ===
sudo tee /usr/local/bin/onedrive-bisync.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail

PI_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$PI_USER" | cut -d: -f6)"
CONF_FILE="/etc/default/onedrive-sync"
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

: "${RCLONE_REMOTE:?RCLONE_REMOTE no definido}"
: "${LOCAL_DIR:?LOCAL_DIR no definido}"
: "${LOG_FILE:?LOG_FILE no definido}"
STATE_FLAG="/var/lib/lumen/bisync_initialized"

# Flags opcionales
BWLIMIT="${BWLIMIT:-}"
EXTRA_FLAGS="${EXTRA_FLAGS:-}"

# Lock para evitar solapamiento
LOCK="/run/onedrive-bisync.lock"

# Primera corrida con --resync si no existe el flag
if [[ ! -f "$STATE_FLAG" ]]; then
  /usr/bin/flock -n "$LOCK" /usr/bin/rclone bisync "${LOCAL_DIR}" "${RCLONE_REMOTE}" \
    --resync --check-access --fast-list --create-empty-src-dirs \
    --filter-from "${LOCAL_DIR}/.rcloneignore" \
    --log-file "${LOG_FILE}" --log-level=INFO ${BWLIMIT} ${EXTRA_FLAGS}
  mkdir -p "$(dirname "$STATE_FLAG")"
  touch "$STATE_FLAG"
else
  /usr/bin/flock -n "$LOCK" /usr/bin/rclone bisync "${LOCAL_DIR}" "${RCLONE_REMOTE}" \
    --check-access --fast-list \
    --filter-from "${LOCAL_DIR}/.rcloneignore" \
    --log-file "${LOG_FILE}" --log-level=NOTICE ${BWLIMIT} ${EXTRA_FLAGS}
fi
SH
sudo chmod +x /usr/local/bin/onedrive-bisync.sh

# === 5) Variables de entorno del sync ===
sudo tee /etc/default/onedrive-sync >/dev/null <<EOF
RCLONE_REMOTE="${REMOTE_URI}"
LOCAL_DIR="${LOCAL_DIR}"
LOG_FILE="${LOG_FILE}"
# Opcionales:
# BWLIMIT="--bwlimit 8M"
# EXTRA_FLAGS="--tpslimit 10"
EOF

# === 6) Unidades systemd (servicio + timer usuario=admin) ===
sudo tee /etc/systemd/system/onedrive-bisync.service >/dev/null <<'UNIT'
[Unit]
Description=Rclone bisync Lumen (local ↔ OneDrive)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=admin
EnvironmentFile=/etc/default/onedrive-sync
ExecStart=/usr/local/bin/onedrive-bisync.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=6
UNIT

sudo tee /etc/systemd/system/onedrive-bisync.timer >/dev/null <<'UNIT'
[Unit]
Description=Ejecuta rclone-bisync cada 5 minutos

[Timer]
OnBootSec=2m
OnUnitActiveSec=5m
AccuracySec=30s
Unit=onedrive-bisync.service
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# === 7) Habilitar timer y primera corrida "suave" (sin bloquear si no hay token aún) ===
sudo systemctl daemon-reload
sudo systemctl enable --now onedrive-bisync.timer
# Primer intento (si no hay token, no es fatal)
sudo systemctl start onedrive-bisync.service || true

echo "✅ OneDrive bisync instalado.
- Remoto:     ${REMOTE_URI}
- Local:      ${LOCAL_DIR}
- Log:        ${LOG_FILE}
- Timer:      onedrive-bisync.timer (cada 5 min)

Siguiente: cargar token con rclone_set_token.sh (broadcast)."
