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

# Leer flags opcionales si existen
BWLIMIT="$(grep -E '^BWLIMIT=' /etc/default/onedrive-sync 2>/dev/null | cut -d= -f2- | tr -d '\"' || true)"
EXTRA_FLAGS="$(grep -E '^EXTRA_FLAGS=' /etc/default/onedrive-sync 2>/dev/null | cut -d= -f2- | tr -d '\"' || true)"

# Usar --filters-file en rclone 1.60.x (no --filter-from) y sin --create-empty-src-dirs
if [[ ! -f "$STATE_FLAG" ]]; then
  /usr/bin/flock -n "$LOCK" /usr/bin/rclone bisync "${LOCAL_DIR}" "${REMOTE_URI}" \
    --resync --check-access --fast-list \
    --filters-file "${LOCAL_DIR}/.rcloneignore" \
    --log-file "${LOG_FILE}" --log-level=INFO ${BWLIMIT} ${EXTRA_FLAGS}
  mkdir -p "$(dirname "$STATE_FLAG")"
  touch "$STATE_FLAG"
else
  /usr/bin/flock -n "$LOCK" /usr/bin/rclone bisync "${LOCAL_DIR}" "${REMOTE_URI}" \
    --check-access --fast-list \
    --filters-file "${LOCAL_DIR}/.rcloneignore" \
    --log-file "${LOG_FILE}" --log-level=NOTICE ${BWLIMIT} ${EXTRA_FLAGS}
fi
SH
sudo chmod +x /usr/local/bin/onedrive-bisync.sh
