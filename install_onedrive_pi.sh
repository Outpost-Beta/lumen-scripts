#!/usr/bin/env bash
set -euo pipefail

# === Parámetros ===
PI_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$PI_USER" | cut -d: -f6)"
LOCAL_DIR="$HOME_DIR/Lumen"                 # Mantener compatibilidad con el player
REMOTE_NAME="onedrive"
REMOTE_PATH="Lumen"
REMOTE_URI="${REMOTE_NAME}:/${REMOTE_PATH}"
LOG_FILE="$HOME_DIR/rclone-bisync.log"
STATE_FLAG="/var/lib/lumen/bisync_initialized"

echo "[1/6] Paquetes…"
sudo apt-get update -y
sudo apt-get install -y rclone util-linux ca-certificates
mkdir -p "$LOCAL_DIR"
sudo mkdir -p "$(dirname "$STATE_FLAG")" && sudo chown "$PI_USER:$PI_USER" "$(dirname "$STATE_FLAG")"

echo "[2/6] .rcloneignore (común)…"
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

echo "[3/6] Helper de token headless (opcional: broadcast de token)…"
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
rclone lsd onedrive:/ >/dev/null 2>&1 || true
SH
sudo chmod +x /usr/local/bin/rclone_set_token.sh

echo "[4/6] onedrive-bisync.sh (primer run con --resync)…"
sudo tee /usr/local/bin/onedrive-bisync.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail

PI_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$PI_USER" | cut -d: -f6)"
LOCAL_DIR="$HOME_DIR/Lumen"
REMOTE_URI="onedrive:/Lumen"
LOG_FILE="$HOME_DIR/rclone-bisync.log"
STATE_FLAG="/var/lib/lumen/bisync_initialized"
LOCK="/run/onedrive-bisync.lock"

# Flags opcionales por ambiente (si existen en /etc/default/onedrive-sync)
BWLIMIT="$(grep -E '^BWLIMIT=' /etc/default/onedrive-sync 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
EXTRA_FLAGS="$(grep -E '^EXTRA_FLAGS=' /etc/default/onedrive-sync 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"

if [[ ! -f "$STATE_FLAG" ]]; then
  /usr/bin/flock -n "$LOCK" /usr/bin/rclone bisync "${LOCAL_DIR}" "${REMOTE_URI}" \
    --resync --check-access --fast-list --create-empty-src-dirs \
    --filter-from "${LOCAL_DIR}/.rcloneignore" \
    --log-file "${LOG_FILE}" --log-level=INFO ${BWLIMIT} ${EXTRA_FLAGS}
  mkdir -p "$(dirname "$STATE_FLAG")"
  touch "$STATE_FLAG"
else
  /usr/bin/flock -n "$LOCK" /usr/bin/rclone bisync "${LOCAL_DIR}" "${REMOTE_URI}" \
    --check-access --fast-list \
    --filter-from "${LOCAL_DIR}/.rcloneignore" \
    --log-file "${LOG_FILE}" --log-level=NOTICE ${BWLIMIT} ${EXTRA_FLAGS}
fi
SH
sudo chmod +x /usr/local/bin/onedrive-bisync.sh

echo "[5/6] Cron cada 5 min con flock…"
sudo tee /etc/cron.d/onedrive-bisync >/dev/null <<'CRON'
*/5 * * * * admin /usr/bin/flock -n /run/onedrive-bisync.lock /usr/local/bin/onedrive-bisync.sh
CRON
sudo chmod 644 /etc/cron.d/onedrive-bisync
sudo systemctl restart cron || sudo service cron restart || true

echo "[6/6] Primer intento (no fatal si aún no hay token)…"
/usr/local/bin/onedrive-bisync.sh || true

cat <<MSG

✅ OneDrive (bisync+cron) instalado:
- Remoto:     onedrive:/Lumen
- Local:      ${LOCAL_DIR}
- Log:        ${LOG_FILE}
- Cron:       /etc/cron.d/onedrive-bisync  (cada 5 min con flock)

Autenticación:
  a) Token único + broadcast (recomendado):
       rclone_set_token.sh TOKEN_B64
  b) Device code por Pi (solo consola):
       rclone config  # onedrive / global / read-write / auto config = n
       # autoriza en navegador con el código mostrado
       rclone lsd onedrive:/Lumen

Revisa:
  tail -n 80 ${LOG_FILE}
MSG
