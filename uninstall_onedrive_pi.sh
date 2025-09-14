#!/usr/bin/env bash
set -euo pipefail
echo "[UNINST] Eliminando cron…"
/bin/rm -f /etc/cron.d/onedrive-bisync || true
sudo systemctl restart cron || sudo service cron restart || true
echo "[UNINST] Eliminando helpers…"
/bin/rm -f /usr/local/bin/onedrive-bisync.sh /usr/local/bin/rclone_set_token.sh || true
echo "[UNINST] Conservados: ~/Lumen y ~/.config/rclone/rclone.conf"
echo "✅ Listo."
