#!/usr/bin/env bash
set -euo pipefail
echo "[UNINST] Deteniendo…"
sudo systemctl stop onedrive-sync.timer onedrive-sync.service 2>/dev/null || true
echo "[UNINST] Deshabilitando…"
sudo systemctl disable onedrive-sync.timer 2>/dev/null || true
echo "[UNINST] Borrando unidades…"
sudo rm -f /etc/systemd/system/onedrive-sync.timer
sudo rm -f /etc/systemd/system/onedrive-sync.service
sudo systemctl daemon-reload
echo "[UNINST] Quitando env…"
/bin/rm -f /etc/default/onedrive-sync
echo "[UNINST] (Opcional) conserva rclone.conf y la carpeta Lumen si no quieres perder auth/datos"
echo "✅ Listo."
