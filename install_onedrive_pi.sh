#!/usr/bin/env bash
set -euo pipefail

PI_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$PI_USER" | cut -d: -f6)"

# 1) paquetes mínimos
sudo apt-get update -y
sudo apt-get install -y rclone ca-certificates

# 2) carpetas
LOCAL_DIR="$HOME_DIR/Lumen"
mkdir -p "$LOCAL_DIR"

# 3) archivo de entorno sencillo
sudo tee /etc/default/onedrive-sync >/dev/null <<'EOF'
RCLONE_REMOTE="onedrive:/Lumen"
LOCAL_DIR="/home/admin/Lumen"
LOG_FILE="/home/admin/rclone-sync.log"

# Opcionales (descomenta si los necesitas):
# BWLIMIT="--bwlimit 8M"
# EXTRA_FLAGS="--include *.mp3"
EOF

# 4) script de sincronización (solo bajada OneDrive -> Pi)
sudo tee /usr/local/bin/onedrive-sync.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/onedrive-sync

: "${RCLONE_REMOTE:?no RCLONE_REMOTE}"
: "${LOCAL_DIR:?no LOCAL_DIR}"
: "${LOG_FILE:?no LOG_FILE}"

BWLIMIT="${BWLIMIT:-}"
EXTRA_FLAGS="${EXTRA_FLAGS:-}"

# Evitar ejecuciones solapadas
LOCK="/run/onedrive-sync.lock"
exec 9>"$LOCK" || exit 1
flock -n 9 || exit 0

# Sync simple: cloud -> local (espejo)
# Flags ultra-compatibles con rclone 1.60.x
/usr/bin/rclone sync "${RCLONE_REMOTE}" "${LOCAL_DIR}" \
  --fast-list --multi-thread-streams 4 \
  --log-file "${LOG_FILE}" --log-level NOTICE \
  ${BWLIMIT} ${EXTRA_FLAGS}
SH
sudo chmod +x /usr/local/bin/onedrive-sync.sh

# 5) helper para cargar token (método recomendado para muchas Pis)
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
  echo "[OK] Remoto 'onedrive' actualizado."
fi

chown -R "$PI_USER:$PI_USER" "$CONF_DIR"
# prueba suave
rclone lsd onedrive:/ >/dev/null 2>&1 || true
SH
sudo chmod +x /usr/local/bin/rclone_set_token.sh

# 6) unidades systemd (corre como el usuario admin)
sudo tee /etc/systemd/system/onedrive-sync.service >/dev/null <<'UNIT'
[Unit]
Description=Rclone sync OneDrive -> Lumen (solo bajada)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=admin
EnvironmentFile=/etc/default/onedrive-sync
ExecStart=/usr/local/bin/onedrive-sync.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=6
UNIT

sudo tee /etc/systemd/system/onedrive-sync.timer >/dev/null <<'UNIT'
[Unit]
Description=OneDrive sync cada 5 min

[Timer]
OnBootSec=2m
OnUnitActiveSec=5m
AccuracySec=30s
Unit=onedrive-sync.service
Persistent=true

[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now onedrive-sync.timer

# 7) primera corrida (no fatal si aún no hay token)
sudo systemctl start onedrive-sync.service || true

echo "✅ Instalado:
- Remoto: onedrive:/Lumen
- Local:  ${LOCAL_DIR}
- Log:    ${HOME_DIR}/rclone-sync.log
- Timer:  onedrive-sync.timer (cada 5 min)

Siguiente paso: cargar el token (o usar device code)."
