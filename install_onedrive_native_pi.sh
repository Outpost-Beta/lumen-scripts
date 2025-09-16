#!/usr/bin/env bash
# install_onedrive_native_pi.sh — Instala y activa OneDrive Client for Linux (abraunegg)
# - Compila desde fuente (ldc) y deja binario en /usr/local/bin/onedrive
# - Crea servicio y timer de systemd (nivel sistema) que ejecutan cada 5 minutos (download-only)
# - Usa configuración en /home/admin/.config/onedrive (tokens/bundle si fueron empujados)

set -euo pipefail

PI_USER="${SUDO_USER:-$USER}"
CONF_DIR="/home/${PI_USER}/.config/onedrive"

echo "[1/5] Paquetes base…"
sudo apt-get update -y
sudo apt-get install -y \
  build-essential git curl pkg-config \
  ldc libdbus-1-dev \
  libcurl4-openssl-dev libsqlite3-dev

echo "[2/5] Descargar/compilar onedrive (abraunegg)…"
SRC_DIR="/home/${PI_USER}/onedrive-src"
if [[ -d "$SRC_DIR/.git" ]]; then
  sudo chown -R "$PI_USER:$PI_USER" "$SRC_DIR"
  sudo -u "$PI_USER" git -C "$SRC_DIR" pull --ff-only
else
  sudo -u "$PI_USER" git clone https://github.com/abraunegg/onedrive.git "$SRC_DIR"
fi

pushd "$SRC_DIR" >/dev/null
sudo -u "$PI_USER" ./configure
sudo -u "$PI_USER" make clean || true
sudo -u "$PI_USER" make -j"$(nproc)"
sudo make install
popd >/dev/null

echo "[3/5] Configuración: sync en /home/${PI_USER}/Lumen (download-only)"
sudo -u "$PI_USER" mkdir -p "$CONF_DIR"
sudo -u "$PI_USER" mkdir -p "/home/${PI_USER}/Lumen"

# Si no hay config aún, crea una mínima (el binario la expande al primer run)
if [[ ! -f "${CONF_DIR}/config" ]]; then
  cat <<CFG | sudo -u "$PI_USER" tee "${CONF_DIR}/config" >/dev/null
sync_dir = "/home/${PI_USER}/Lumen"
skip_dir = "~*"
monitor_interval = "300"
min_notify_changes = "5"
dry_run = "false"
upload_only = "false"
download_only = "true"
log_dir = "/home/${PI_USER}"
CFG
fi

echo "[4/5] Crear servicio y timer (cada 5 min)…"
sudo tee /etc/systemd/system/onedrive-lumen.service >/dev/null <<UNIT
[Unit]
Description=OneDrive sync for Lumen (download-only)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${PI_USER}
Group=${PI_USER}
ExecStart=/usr/local/bin/onedrive --confdir /home/${PI_USER}/.config/onedrive --synchronize --download-only
Restart=on-failure
RestartSec=10s
Nice=10

[Install]
WantedBy=multi-user.target
UNIT

sudo tee /etc/systemd/system/onedrive-lumen.timer >/dev/null <<UNIT
[Unit]
Description=Run OneDrive Lumen sync every 5 minutes

[Timer]
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true
Unit=onedrive-lumen.service

[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now onedrive-lumen.timer

echo "[5/5] Primer intento (no fatal si aún no hay token)…"
if ! sudo -u "${PI_USER}" /usr/local/bin/onedrive --confdir "${CONF_DIR}" --synchronize --download-only >/dev/null 2>&1; then
  echo "Nota: si no hay token aún, la sincronización arrancará cuando se empuje el bundle o autorices manualmente."
fi

echo "✅ OneDrive instalado:"
echo "  - Servicio/Timer: onedrive-lumen.(service|timer) (cada 5 min)"
echo "  - Carpeta local:  /home/${PI_USER}/Lumen"
echo "  - Config:         ${CONF_DIR}"
