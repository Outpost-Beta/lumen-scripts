#!/usr/bin/env bash
# install_onedrive_native_pi.sh
# Instala OneDrive (abraunegg) y crea servicio systemd para sincronizar ~/Lumen (download-only)

set -euo pipefail

USER_NAME="admin"
HOME_DIR="/home/${USER_NAME}"
CONF_DIR="${HOME_DIR}/.config/onedrive"
SYNC_DIR="${HOME_DIR}/Lumen"

need_root() { if [[ $EUID -ne 0 ]]; then echo "Ejecuta con: sudo $0"; exit 1; fi; }

pkg_install() {
  echo "[1/4] Paquetes…"
  apt-get update -y
  # intenta paquete precompilado
  if ! apt-get install -y onedrive; then
    echo "[INFO] Paquete 'onedrive' no está en repos; compilando desde fuente…"
    apt-get install -y curl git build-essential pkg-config ldc libcurl4-openssl-dev libsqlite3-dev libdbus-1-dev
    sudo -u "${USER_NAME}" bash -lc '
      set -euo pipefail
      rm -rf ~/onedrive-src
      git clone https://github.com/abraunegg/onedrive.git ~/onedrive-src
      cd ~/onedrive-src
      ./configure
      make -j2
    '
    make -C "${HOME_DIR}/onedrive-src" install
  fi
}

prepare_dirs() {
  echo "[2/4] Config y carpetas…"
  mkdir -p "${SYNC_DIR}" "${CONF_DIR}"
  chown -R "${USER_NAME}:${USER_NAME}" "${HOME_DIR}/.config" "${SYNC_DIR}"
  # si no llegó bundle aún, crea config básica
  if [[ ! -f "${CONF_DIR}/config" ]]; then
    sudo -u "${USER_NAME}" tee "${CONF_DIR}/config" >/dev/null <<'CFG'
sync_dir = "/home/admin/Lumen"
download_only = "true"
CFG
  fi
  if [[ ! -f "${CONF_DIR}/sync_list" ]]; then
    sudo -u "${USER_NAME}" tee "${CONF_DIR}/sync_list" >/dev/null <<'SL'
Lumen
SL
  fi
  chmod 700 "${HOME_DIR}/.config" "${CONF_DIR}"
  find "${CONF_DIR}" -type f -exec chmod 600 {} \;
  chown -R "${USER_NAME}:${USER_NAME}" "${CONF_DIR}"
}

install_service() {
  echo "[3/4] Servicio systemd…"
  cat >/etc/systemd/system/onedrive-lumen.service <<UNIT
[Unit]
Description=OneDrive client for Lumen (download-only)
After=network-online.target
Wants=network-online.target

[Service]
User=${USER_NAME}
ExecStart=/usr/bin/onedrive --monitor --synchronize --download-only
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now onedrive-lumen.service || true
}

smoke_test() {
  echo "[4/4] Prueba rápida… (no fatal si aún no hay bundle/tokens)"
  sudo -u "${USER_NAME}" bash -lc 'command -v onedrive >/dev/null && onedrive --synchronize --download-only || true'
  systemctl status onedrive-lumen.service --no-pager || true
  echo "✅ OneDrive listo: cuando empujes el bundle desde el VPS, sincroniza solo."
}

need_root
pkg_install
prepare_dirs
install_service
smoke_test
