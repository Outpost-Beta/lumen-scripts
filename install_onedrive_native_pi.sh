#!/usr/bin/env bash
# install_onedrive_native_pi.sh — Instala y configura OneDrive (abraunegg) en la Pi
# - Compila / actualiza binario en /usr/local/bin/onedrive
# - Garantiza config en ~/.config/onedrive (download_only, threads, HTTP/1.1)
# - Crea o actualiza onedrive-lumen.service
# - COPIA onedrive-lumen.timer DESDE EL REPO (20 min) y lo habilita
# - Idempotente

set -euo pipefail

PI_USER="${SUDO_USER:-$USER}"
HOME_DIR="/home/${PI_USER}"
CONF_DIR="${HOME_DIR}/.config/onedrive"
REPO_DIR="${HOME_DIR}/lumen-scripts"

echo "[1/6] Paquetes base…"
sudo apt-get update -y
sudo apt-get install -y build-essential git curl pkg-config \
  ldc libdbus-1-dev libcurl4-openssl-dev libsqlite3-dev

echo "[2/6] Descargar/compilar onedrive (abraunegg)…"
SRC_DIR="${HOME_DIR}/onedrive-src"
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

echo "[3/6] Configuración local…"
sudo -u "$PI_USER" mkdir -p "$CONF_DIR" "${HOME_DIR}/Lumen"

CFG_FILE="${CONF_DIR}/config"
if [[ ! -f "$CFG_FILE" ]]; then
  cat <<CFG | sudo -u "$PI_USER" tee "$CFG_FILE" >/dev/null
sync_dir = "${HOME_DIR}/Lumen"
skip_dir = "~*"
monitor_interval = "300"
min_notify_changes = "5"
dry_run = "false"
upload_only = "false"
download_only = "true"
log_dir = "${HOME_DIR}"
threads = "4"
force_http_11 = "true"
CFG
else
  # Asegurar claves requeridas (idempotente)
  grep -q '^\s*sync_dir\s*=' "$CFG_FILE" || echo "sync_dir = \"${HOME_DIR}/Lumen\"" | sudo -u "$PI_USER" tee -a "$CFG_FILE" >/dev/null
  sed -i "s|^\s*sync_dir\s*=.*|sync_dir = \"${HOME_DIR}/Lumen\"|" "$CFG_FILE"
  grep -q '^\s*download_only\s*=' "$CFG_FILE" || echo 'download_only = "true"' | sudo -u "$PI_USER" tee -a "$CFG_FILE" >/dev/null
  sed -i 's|^\s*download_only\s*=.*|download_only = "true"|' "$CFG_FILE"
  grep -q '^\s*threads\s*=' "$CFG_FILE" || echo 'threads = "4"' | sudo -u "$PI_USER" tee -a "$CFG_FILE" >/dev/null
  sed -i 's|^\s*threads\s*=.*|threads = "4"|' "$CFG_FILE"
  grep -q '^\s*force_http_11\s*=' "$CFG_FILE" || echo 'force_http_11 = "true"' | sudo -u "$PI_USER" tee -a "$CFG_FILE" >/dev/null
  sed -i 's|^\s*force_http_11\s*=.*|force_http_11 = "true"|' "$CFG_FILE"
fi

echo "[4/6] Servicio systemd (onedrive-lumen.service)…"
sudo tee /etc/systemd/system/onedrive-lumen.service >/dev/null <<UNIT
[Unit]
Description=OneDrive sync for Lumen (download-only)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${PI_USER}
Group=${PI_USER}
ExecStart=/usr/local/bin/onedrive --confdir ${CONF_DIR} --synchronize --download-only
Restart=on-failure
RestartSec=10s
Nice=10

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable onedrive-lumen.service

echo "[5/6] Timer DESDE EL REPO (20 min)…"
# Preferimos el archivo versionado en el repo. Fallback: crear uno de 20 min si no existe.
if [[ -f "${REPO_DIR}/onedrive-lumen.timer" ]]; then
  sudo cp "${REPO_DIR}/onedrive-lumen.timer" /etc/systemd/system/onedrive-lumen.timer
else
  echo "(!) onedrive-lumen.timer no encontrado en ${REPO_DIR}, creando uno de 20 min por fallback."
  sudo tee /etc/systemd/system/onedrive-lumen.timer >/dev/null <<TIMER
[Unit]
Description=Run OneDrive Lumen sync every 20 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=20min
AccuracySec=30s
Persistent=true
Unit=onedrive-lumen.service

[Install]
WantedBy=timers.target
TIMER
fi

sudo systemctl daemon-reload
sudo systemctl enable --now onedrive-lumen.timer

echo "[6/6] Verificación rápida…"
# Mostrar definición efectiva del timer y próxima ejecución (para confirmar 20 min)
systemctl cat onedrive-lumen.timer || true
systemctl list-timers onedrive-lumen.timer --all || true

# Primer sync best-effort (no fatal si aún no hay token)
if ! sudo -u "${PI_USER}" /usr/local/bin/onedrive --confdir "${CONF_DIR}" --synchronize --download-only >/dev/null 2>&1; then
  echo "Nota: si no hay token aún, la sync automática correrá cuando empujes el bundle."
fi

echo "✅ OneDrive listo: service activo + timer (20 min) desde repo"
