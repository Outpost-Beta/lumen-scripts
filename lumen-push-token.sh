#!/usr/bin/env bash
# lumen-push-token.sh
# Uso: lumen-push-token.sh DEVICE_ID PORT [BUNDLE_PATH]
# Copia un bundle de OneDrive (tokens + config) desde el VPS a la Pi via túnel
# y lo instala en ~/.config/onedrive del usuario 'admin'.

set -euo pipefail

DEVICE_ID="${1:-}"
PORT="${2:-}"
# Bundle por defecto (puedes pasar uno específico como 3er arg)
BUNDLE="${3:-/srv/lumen/onedrive_tokens/Lumen_bundle.tar.gz}"

if [[ -z "$DEVICE_ID" || -z "$PORT" ]]; then
  echo "Uso: $0 DEVICE_ID PORT [BUNDLE_PATH]" >&2
  exit 1
fi

if [[ ! -f "$BUNDLE" ]]; then
  echo "❌ No existe bundle: $BUNDLE" >&2
  exit 1
fi

echo "[${DEVICE_ID}] enviando bundle -> puerto ${PORT}"
scp -P "$PORT" -o StrictHostKeyChecking=accept-new -q \
  "$BUNDLE" admin@localhost:/home/admin/onedrive_bundle.tar.gz

echo "[${DEVICE_ID}] instalando bundle en ~/.config/onedrive"
ssh -p "$PORT" -o StrictHostKeyChecking=accept-new admin@localhost bash -lc '
  set -euo pipefail
  mkdir -p ~/.config/onedrive
  tar -xzf ~/onedrive_bundle.tar.gz -C ~/.config/onedrive
  rm -f ~/onedrive_bundle.tar.gz
  chmod 700 ~/.config ~/.config/onedrive
  find ~/.config/onedrive -type f -exec chmod 600 {} \;
  # si está instalado el cliente, hace 1ª sincronización de prueba (no fatal si falla)
  if command -v onedrive >/dev/null 2>&1; then
    onedrive --synchronize --download-only || true
  fi
'

echo "[${DEVICE_ID}] ✅ bundle instalado"
