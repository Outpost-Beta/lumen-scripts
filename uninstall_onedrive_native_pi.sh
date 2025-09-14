#!/usr/bin/env bash
# uninstall_onedrive_native_pi.sh
set -euo pipefail

USER_NAME="admin"
HOME_DIR="/home/${USER_NAME}"

[[ $EUID -eq 0 ]] || { echo "Ejecuta con: sudo $0"; exit 1; }

echo "[1/4] Servicio…"
systemctl stop onedrive-lumen.service 2>/dev/null || true
systemctl disable onedrive-lumen.service 2>/dev/null || true
rm -f /etc/systemd/system/onedrive-lumen.service
systemctl daemon-reload

echo "[2/4] Binario…"
if dpkg -l | grep -q '^ii  onedrive '; then apt-get remove -y onedrive; fi
rm -rf "${HOME_DIR}/onedrive-src" /usr/local/bin/onedrive

echo "[3/4] Config/cache…"
rm -rf "${HOME_DIR}/.config/onedrive" "${HOME_DIR}/.cache/onedrive"

echo "[4/4] Mantengo ~/Lumen (tus archivos). Si quieres borrarlo: sudo rm -rf ${HOME_DIR}/Lumen"
echo "✅ OneDrive eliminado."
