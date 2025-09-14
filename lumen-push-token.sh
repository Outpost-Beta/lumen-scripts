#!/usr/bin/env bash
# lumen-push-token.sh
# Uso: lumen-push-token.sh DEVICE_ID PORT [BUNDLE_PATH]
# Copia bundle de OneDrive a la Pi y lo instala en ~/.config/onedrive
set -euo pipefail

DEVICE_ID="${1:-}"; PORT="${2:-}"
BUNDLE="${3:-/srv/lumen/onedrive_tokens/Lumen_bundle.tar.gz}"

[[ -n "$DEVICE_ID" && -n "$PORT" ]] || { echo "Uso: $0 DEVICE_ID PORT [BUNDLE]"; exit 1; }
[[ -f "$BUNDLE" ]] || { echo "❌ No existe bundle: $BUNDLE"; exit 1; }

echo "[${DEVICE_ID}] enviando bundle -> ${PORT}"
scp -P "$PORT" -o StrictHostKeyChecking=accept-new -q \
  "$BUNDLE" admin@localhost:/home/admin/onedrive_bundle.tar.gz

echo "[${DEVICE_ID}] instalando bundle…"
ssh -p "$PORT" -o StrictHostKeyChecking=accept-new admin@localhost bash -lc '
  set -euo pipefail
  mkdir -p ~/.config/onedrive
  tar -xzf ~/onedrive_bundle.tar.gz -C ~/.config/onedrive
  rm -f ~/onedrive_bundle.tar.gz
  chmod 700 ~/.config ~/.config/onedrive
  find ~/.config/onedrive -type f -exec chmod 600 {} \;
  if command -v onedrive >/dev/null 2>&1; then
    onedrive --synchronize --download-only || true
    sudo systemctl restart onedrive-lumen.service || true
  fi
'
echo "[${DEVICE_ID}] ✅ bundle instalado"
