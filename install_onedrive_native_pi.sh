#!/usr/bin/env bash
set -euo pipefail

PI_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$PI_USER" | cut -d: -f6)"
SYNC_DIR="${HOME_DIR}/Lumen"     # Tu carpeta ya usada por el player
CFG_DIR="${HOME_DIR}/.config/onedrive"
LOG_DIR="${HOME_DIR}/.cache/onedrive"
REPO_DIR="${HOME_DIR}/onedrive-src"

echo "[1/5] Paquetes base…"
sudo apt-get update -y
sudo apt-get install -y build-essential libcurl4-openssl-dev libsqlite3-dev pkg-config git curl

echo "[2/5] Descargar/compilar onedrive (abraunegg)…"
rm -rf "${REPO_DIR}"
git clone https://github.com/abraunegg/onedrive.git "${REPO_DIR}"
cd "${REPO_DIR}"
./configure
make
sudo make install

echo "[3/5] Configuración: sync en ${SYNC_DIR}"
mkdir -p "${SYNC_DIR}" "${CFG_DIR}" "${LOG_DIR}"
# Config simple; puedes ajustar include/exclude luego en este archivo
cat > "${CFG_DIR}/config" <<EOF
sync_dir = "${SYNC_DIR}"
monitor_interval = "300"
skip_dotfiles = "true"
skip_symlinks = "true"
EOF
chown -R "${PI_USER}:${PI_USER}" "${CFG_DIR}" "${SYNC_DIR}" "${LOG_DIR}"

echo "[4/5] Habilitar servicio de usuario y linger…"
# Permite servicios user sin sesión interactiva
sudo loginctl enable-linger "${PI_USER}" >/dev/null 2>&1 || true
# Asegura el directorio de systemd user
mkdir -p "${HOME_DIR}/.config/systemd/user"
# Habilita servicio onedrive del usuario
sudo -u "${PI_USER}" systemctl --user daemon-reload
sudo -u "${PI_USER}" systemctl --user enable onedrive.service

echo "[5/5] Primera ejecución (pedirá URL + código la primera vez)…"
echo ">>> Cuando se muestre una URL y un CÓDIGO, ábrela en un navegador y autoriza tu cuenta."
sudo -u "${PI_USER}" onedrive || true

echo
echo "✅ Instalado."
echo "- Carpeta local: ${SYNC_DIR}"
echo "- Config: ${CFG_DIR}/config"
echo "- Servicio: systemd --user onedrive.service (con linger)"
echo
echo "Para iniciar en background ahora y que sincronice automáticamente:"
echo "  sudo -u ${PI_USER} systemctl --user start onedrive.service"
echo "Ver logs:"
echo "  sudo -u ${PI_USER} journalctl --user-unit=onedrive -f"
