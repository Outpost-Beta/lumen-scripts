#!/usr/bin/env bash
set -euo pipefail

# === Parámetros base ===
PI_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$PI_USER" | cut -d: -f6)"
CONF_ENV="/etc/default/onedrive-sync"
RCLONE_CONF_DIR="$HOME_DIR/.config/rclone"
RCLONE_CONF="$RCLONE_CONF_DIR/rclone.conf"

REMOTE_NAME="onedrive"
REMOTE_PATH="Lumen"                  # Carpeta raíz en OneDrive
LOCAL_DIR="$HOME_DIR/Lumen"          # Carpeta local ya usada por tu proyecto
LOG_FILE="$HOME_DIR/rclone-sync.log"

echo "[1/6] Paquetes y estructura…"
sudo apt-get update -y
sudo apt-get install -y rclone ca-certificates
mkdir -p "$RCLONE_CONF_DIR"
mkdir -p "$LOCAL_DIR"
sudo chown -R "$PI_USER:$PI_USER" "$HOME_DIR/.config" "$LOCAL_DIR"

echo "[2/6] Variables del sync (/etc/default/onedrive-sync)…"
sudo tee "$CONF_ENV" >/dev/null <<EOF
RCLONE_REMOTE="${REMOTE_NAME}:/${REMOTE_PATH}"
LOCAL_DIR="${LOCAL_DIR}"
LOG_FILE="${LOG_FILE}"
# Opcionales:
# BWLIMIT="--bwlimit 8M"
# EXTRA_FLAGS="--tpslimit 10"
EOF

echo "[3/6] Servicio systemd (onedrive-sync.service)…"
sudo tee /etc/systemd/system/onedrive-sync.service >/dev/null <<'UNIT'
[Unit]
Description=OneDrive -> Local sync (rclone)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=admin
EnvironmentFile=/etc/default/onedrive-sync
# Asegura lock para evitar solapes
ExecStart=/usr/bin/flock -n /run/onedrive-sync.lock \
  /usr/bin/rclone sync "${RCLONE_REMOTE}" "${LOCAL_DIR}" \
    --create-empty-src-dirs --delete-during --fast-list --skip-links \
    --log-file "${LOG_FILE}" --log-level INFO ${BWLIMIT} ${EXTRA_FLAGS}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=6
UNIT

echo "[4/6] Timer systemd (cada 5 min)…"
sudo tee /etc/systemd/system/onedrive-sync.timer >/dev/null <<'UNIT'
[Unit]
Description=Run OneDrive sync periodically

[Timer]
OnBootSec=2m
OnUnitActiveSec=5m
AccuracySec=30s
Unit=onedrive-sync.service
Persistent=true

[Install]
WantedBy=timers.target
UNIT

echo "[5/6] Helper para token headless (/usr/local/bin/rclone_set_token.sh)…"
sudo tee /usr/local/bin/rclone_set_token.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Uso:
#   rclone_set_token.sh <TOKEN_JSON_BASE64>
# Autoriza/crea remoto "onedrive" usando un token JSON ya autorizado
PI_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$PI_USER" | cut -d: -f6)"
RCLONE_CONF_DIR="$HOME_DIR/.config/rclone"
mkdir -p "$RCLONE_CONF_DIR"
TOKEN_B64="${1:-}"
[[ -n "$TOKEN_B64" ]] || { echo "Falta TOKEN_JSON_BASE64"; exit 2; }
TOKEN_JSON="$(printf '%s' "$TOKEN_B64" | base64 -d)"

# Escribimos en el rclone.conf del usuario admin
export RCLONE_CONFIG="$RCLONE_CONF_DIR/rclone.conf"

# Crea o actualiza el remoto "onedrive"
if rclone config create onedrive onedrive token "$TOKEN_JSON" --non-interactive >/dev/null 2>&1; then
  echo "[OK] Remoto 'onedrive' creado/actualizado."
else
  # Si ya existía, intentamos reconectar con el token
  rclone config reconnect onedrive: --non-interactive <<EOF >/dev/null 2>&1 || true
y
EOF
  echo "[OK] Remoto 'onedrive' actualizado (reconnect)."
fi

chown -R "$PI_USER:$PI_USER" "$RCLONE_CONF_DIR"
echo "[Listando raíz remota para validar…]"
rclone lsd onedrive:/ || true
SH
sudo chmod +x /usr/local/bin/rclone_set_token.sh

echo "[6/6] Habilitar y lanzar timer…"
sudo systemctl daemon-reload
sudo systemctl enable --now onedrive-sync.timer
# Intento de sync inicial (no falla si aún no hay token)
sudo systemctl start onedrive-sync.service || true

echo "✅ OneDrive integrado.
- Remoto:     ${REMOTE_NAME}:/$(printf '%s' "$REMOTE_PATH")
- Local:      ${LOCAL_DIR}
- Logs:       ${LOG_FILE}
- Timer:      onedrive-sync.timer (cada 5 min)

Siguiente paso: autoriza el remoto con tu token (ver instrucciones del VPS/broadcast)."
