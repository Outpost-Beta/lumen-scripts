#!/usr/bin/env bash
# uninstall_onedrive_native_pi.sh
# Elimina cliente OneDrive (abraunegg) y servicio onedrive-lumen de la Pi.

set -euo pipefail

USER_NAME="admin"
HOME_DIR="/home/${USER_NAME}"
CONF_DIR="${HOME_DIR}/.config/onedrive"
SYNC_DIR="${HOME_DIR}/Lumen"

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "✋ Ejecuta como root: sudo $0"
    exit 1
  fi
}

remove_service() {
  echo "[1/4] Eliminando servicio systemd…"
  systemctl stop onedrive-lumen.service 2>/dev/null || true
  systemctl disable onedrive-lumen.service 2>/dev/null || true
  rm -f /etc/systemd/system/onedrive-lumen.service
  systemctl daemon-reload
}

remove_binary() {
  echo "[2/4] Eliminando cliente onedrive…"
  if dpkg -l | grep -q '^ii  onedrive '; then
    apt-get remove -y onedrive
  fi
  rm -rf "${HOME_DIR}/onedrive-src"
  rm -f /usr/local/bin/onedrive
}

remove_config() {
  echo "[3/4] Eliminando configuración y caché…"
  rm -rf "${CONF_DIR}"
  rm -rf "${HOME_DIR}/.cache/onedrive"
}

optional_cleanup() {
  echo "[4/4] Limpieza opcional de carpeta sincronizada…"
  echo "⚠️ OJO: se mantendrá ${SYNC_DIR} con tus archivos de música."
  echo "Si quieres borrarla manualmente: sudo rm -rf ${SYNC_DIR}"
}

need_root
remove_service
remove_binary
remove_config
optional_cleanup

echo "✅ OneDrive eliminado de esta Pi."
