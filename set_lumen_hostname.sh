#!/usr/bin/env bash
# set_lumen_hostname.sh — fija hostname y asegura /etc/hosts coherente
# Uso: ./set_lumen_hostname.sh caja-00   (o caja-01, caja-02, ...)
set -euo pipefail

NEW_HOST="${1:-}"
[[ -n "$NEW_HOST" ]] || { echo "Uso: $0 <nuevo_hostname>"; exit 1; }

# 1) Fijar hostname en el sistema
sudo hostnamectl set-hostname "$NEW_HOST"

# 2) Reflejar en /etc/hostname (por si hostnamectl no lo deja)
echo "$NEW_HOST" | sudo tee /etc/hostname >/dev/null

# 3) Asegurar mapping 127.0.1.1 -> <hostname> (evita: 'sudo: unable to resolve host')
if grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
  sudo sed -i -E "s/^127\.0\.1\.1\s+.*/127.0.1.1 ${NEW_HOST}/" /etc/hosts
else
  echo "127.0.1.1 ${NEW_HOST}" | sudo tee -a /etc/hosts >/dev/null
fi

# 4) (Opcional) reiniciar hostnamed para reflejar cambios inmediatos
sudo systemctl restart systemd-hostnamed 2>/dev/null || true

echo "✅ Hostname fijado: ${NEW_HOST} (y /etc/hosts actualizado)"
