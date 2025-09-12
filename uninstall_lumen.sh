#!/usr/bin/env bash
set -euo pipefail

echo "[PI] Eliminando servicios y configuraciones de Lumen…"

# Detener y deshabilitar systemd units
sudo systemctl stop autossh-lumen.service lumen-agent.timer lumen-agent.service 2>/dev/null || true
sudo systemctl disable autossh-lumen.service lumen-agent.timer lumen-agent.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/autossh-lumen.service
sudo rm -f /etc/systemd/system/lumen-agent.service
sudo rm -f /etc/systemd/system/lumen-agent.timer
sudo systemctl daemon-reload

# Borrar scripts y configs
sudo rm -f /usr/local/bin/lumen-agent.sh
sudo rm -rf /etc/lumen

# Borrar datos de audio
rm -rf "$HOME/Lumen"

# Borrar claves ssh locales
rm -f "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/known_hosts"

echo "[PI] Limpieza completa."
