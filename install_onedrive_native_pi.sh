#!/usr/bin/env bash
# Instala OneDrive Free Client (abraunegg) y deja un servicio systemd (de sistema) corriendo como 'admin'
# Modo: monitor + synchronize + download-only  (OneDrive:/Lumen -> /home/admin/Lumen)

set -euo pipefail

PI_USER="admin"
PI_HOME="/home/${PI_USER}"
CONF_DIR="${PI_HOME}/.config/onedrive"
SYNC_DIR="${PI_HOME}/Lumen"
SRC_DIR="${PI_HOME}/onedrive-src"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Ejecuta como root: sudo $0"
  exit 1
fi
id -u "${PI_USER}" >/dev/null 2>&1 || { echo "No existe el usuario ${PI_USER}"; exit 1; }

echo "[1/5] Paquetes base…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  curl git build-essential pkg-config \
  libcurl4-openssl-dev libsqlite3-dev libdbus-1-dev \
  ldc

echo "[2/5] Descargar/compilar onedrive (abraunegg)…"
# Limpia compilaciones previas del usuario para evitar conflictos
rm -rf "${SRC_DIR}"
sudo -u "${PI_USER}" git clone https://github.com/abraunegg/onedrive.git "${SRC_DIR}"
pushd "${SRC_DIR}" >/dev/null
sudo -u "${PI_USER}" ./configure
make clean
make
make install
popd >/dev/null

echo "[3/5] Configuración: sync en ${SYNC_DIR}"
# Estructura de config para el usuario admin
install -d -m 0755 -o "${PI_USER}" -g "${PI_USER}" "${CONF_DIR}"
install -d -m 0755 -o "${PI_USER}" -g "${PI_USER}" "${SYNC_DIR}"

# Archivos base (si luego “inyectas” un bundle, esto se sobrescribe)
CONFIG_FILE="${CONF_DIR}/config"
SYNC_LIST="${CONF_DIR}/sync_list"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  cat > "${CONFIG_FILE}" <<EOF
# Directorio local de sincronización
sync_dir = "${SYNC_DIR}"
# Sólo bajar del remoto (no sube nada desde la Pi)
sync_direction = "down"
# Evita borrar local ante cambios severos (seguro)
resync = false
EOF
  chown "${PI_USER}:${PI_USER}" "${CONFIG_FILE}"
  chmod 0644 "${CONFIG_FILE}"
fi

if [[ ! -f "${SYNC_LIST}" ]]; then
  echo "Lumen" > "${SYNC_LIST}"
  chown "${PI_USER}:${PI_USER}" "${SYNC_LIST}"
  chmod 0644 "${SYNC_LIST}"
fi

echo "[4/5] Servicio systemd (de sistema) como ${PI_USER}…"
SERVICE="/etc/systemd/system/onedrive-lumen.service"
cat > "${SERVICE}" <<'UNIT'
[Unit]
Description=OneDrive (abraunegg) Lumen monitor (download-only) as admin
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=admin
Group=admin
# Asegura variables HOME correctas
Environment=HOME=/home/admin
Environment=XDG_CONFIG_HOME=/home/admin/.config
ExecStart=/usr/local/bin/onedrive --monitor --synchronize --download-only
Restart=always
RestartSec=10
Nice=10

# Limita recursos un poco
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable onedrive-lumen.service

echo "[5/5] Arrancando servicio (si no hay token aún, quedará a la espera)…"
systemctl restart onedrive-lumen.service || true

echo
echo "✅ OneDrive instalado y servicio creado:"
echo "  - Binario:   /usr/local/bin/onedrive"
echo "  - Servicio:  onedrive-lumen.service (User=admin)"
echo "  - Config:    ${CONF_DIR}/ (config, sync_list)"
echo "  - Carpeta:   ${SYNC_DIR}"
echo
echo "Si vas a inyectar el token vía VPS, ya puedes hacerlo (bundle) y luego:"
echo "  sudo systemctl restart onedrive-lumen.service"
echo
echo "Para ver estado/logs:"
echo "  systemctl status --no-pager onedrive-lumen.service"
echo "  journalctl -u onedrive-lumen.service -n 50 --no-pager"
