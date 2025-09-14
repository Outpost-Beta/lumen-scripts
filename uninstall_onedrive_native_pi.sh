#!/usr/bin/env bash
set -euo pipefail
PI_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$PI_USER" | cut -d: -f6)"

echo "[UNINST] Deteniendo servicio user…"
sudo -u "${PI_USER}" systemctl --user stop onedrive.service 2>/dev/null || true
sudo -u "${PI_USER}" systemctl --user disable onedrive.service 2>/dev/null || true
sudo -u "${PI_USER}" systemctl --user daemon-reload || true

echo "[UNINST] Quitando binario (de make install)…"
sudo rm -f /usr/local/bin/onedrive

echo "[UNINST] (Conservando datos locales en ~/Lumen y ~/.config/onedrive)"
echo "✅ Listo."
