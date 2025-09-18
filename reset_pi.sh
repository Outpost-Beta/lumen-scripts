#!/usr/bin/env bash
# reset_pi.sh — Limpia completamente la Raspberry Pi para reinstalar Lumen
# Conserva ~/Lumen (tu música). Si vas a formatear, NO necesitas este script.

set -euo pipefail

echo "[1/7] Detener y deshabilitar servicios Lumen/OneDrive…"
sudo systemctl stop autossh-lumen.service lumen-agent.service lumen-agent.timer \
                    onedrive-lumen.service onedrive-lumen.timer \
                    lumen-play.service 2>/dev/null || true
sudo systemctl disable autossh-lumen.service lumen-agent.service lumen-agent.timer \
                       onedrive-lumen.service onedrive-lumen.timer \
                       lumen-play.service 2>/dev/null || true

echo "[2/7] Eliminar units systemd…"
sudo rm -f /etc/systemd/system/autossh-lumen.service
sudo rm -f /etc/systemd/system/lumen-agent.service
sudo rm -f /etc/systemd/system/lumen-agent.timer
sudo rm -f /etc/systemd/system/onedrive-lumen.service
sudo rm -f /etc/systemd/system/onedrive-lumen.timer
sudo rm -f /etc/systemd/system/lumen-play.service
sudo systemctl daemon-reload

echo "[3/7] Matar procesos autossh/ssh…"
pkill -f 'autossh.*@' 2>/dev/null || true
pkill -f 'ssh .*@'    2>/dev/null || true
sleep 1
pkill -9 -f 'autossh.*@' 2>/dev/null || true
pkill -9 -f 'ssh .*@'    2>/dev/null || true

echo "[4/7] Eliminar binarios y configuración…"
sudo rm -f /usr/local/bin/lumen-agent.sh /usr/local/bin/onedrive 2>/dev/null || true
sudo rm -rf /etc/lumen 2>/dev/null || true

sudo rm -f /usr/local/bin/lumen-play.py

echo "[5/7] Conservar ~/Lumen (tu música), limpiar claves SSH locales…"
echo "   (Si quisieras borrar música: rm -rf ~/Lumen)"
rm -f ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub 2>/dev/null || true

echo "[6/7] Limpiar huellas de VPS en known_hosts y mantener /etc/hosts sano…"
ssh-keygen -R 200.234.230.254 >/dev/null 2>&1 || true
for port in $(seq 2201 2399); do
  ssh-keygen -R "[localhost]:$port" >/dev/null 2>&1 || true
done

HOSTNAME_ACTUAL=$(hostnamectl --static 2>/dev/null || hostname -s)
if grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
  sudo sed -i -E "s/^127\.0\.1\.1\s+.*/127.0.1.1 ${HOSTNAME_ACTUAL}/" /etc/hosts
else
  echo "127.0.1.1 ${HOSTNAME_ACTUAL}" | sudo tee -a /etc/hosts >/dev/null
fi

echo "[7/7] Limpieza completada."
echo "✅ Raspberry Pi limpia (se conserva ~/Lumen)"
