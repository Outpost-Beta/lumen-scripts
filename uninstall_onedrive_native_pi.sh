#!/usr/bin/env bash
# Desinstala el cliente abraunegg y borra la configuración del usuario 'admin'

set -euo pipefail

PI_USER="admin"
PI_HOME="/home/${PI_USER}"
CONF_DIR="${PI_HOME}/.config/onedrive"
SRC_DIR="${PI_HOME}/onedrive-src"
SERVICE="/etc/systemd/system/onedrive-lumen.service"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Ejecuta como root: sudo $0"
  exit 1
fi

echo "[1/3] Deteniendo y deshabilitando servicio…"
systemctl stop onedrive-lumen.service 2>/dev/null || true
systemctl disable onedrive-lumen.service 2>/dev/null || true
rm -f "${SERVICE}" || true
systemctl daemon-reload || true

echo "[2/3] Eliminando binario y fuentes…"
/bin/rm -f /usr/local/bin/onedrive || true
rm -rf "${SRC_DIR}" || true

echo "[3/3] Borrando configuración del usuario…"
rm -rf "${CONF_DIR}" || true

echo "✅ OneDrive nativo desinstalado."
