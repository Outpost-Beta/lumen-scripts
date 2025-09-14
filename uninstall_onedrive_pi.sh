#!/usr/bin/env bash
set -euo pipefail
echo "[UNINST] Deteniendo y deshabilitando…"
sudo systemctl stop onedrive-sync.timer onedrive-sync.service 2>/dev/null || true
sudo systemctl disable onedrive-sync.timer 2>/dev/null || true

echo "[UNINST] Borrando unidades/env/scripts…"
/bin/rm -f /etc/systemd/system/onedrive-sync.timer
/bin/rm -f /etc/systemd/system/onedrive-sync.service
/bin/rm -f /etc/default/onedrive-sync
/bin/rm -f /usr/local/bin/onedrive-sync.sh
/bin/rm -f /usr/local/bin/rclone_set_token.sh

sudo systemctl daemon-reload
echo "✅ Listo. (Se conserva ~/Lumen y ~/.config/rclone)"
