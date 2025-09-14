#!/usr/bin/env bash
# lumen-push-token.sh  (VPS) • Envía el bundle de OneDrive a una Pi y fuerza una sync inicial
# Uso: lumen-push-token.sh <DEVICE_ID> <PORT>

set -euo pipefail
CONF="/etc/lumen-vps.conf"
source "$CONF" 2>/dev/null || { echo "No existe $CONF"; exit 1; }

DEVICE_ID="${1:-}"; PORT="${2:-}"
[[ -n "$DEVICE_ID" && -n "$PORT" ]] || { echo "Uso: $0 <DEVICE_ID> <PORT>"; exit 1; }

BUNDLE="/srv/lumen/onedrive_tokens/Lumen_bundle.tar.gz"
[[ -f "$BUNDLE" ]] || { echo "No existe $BUNDLE"; exit 1; }

echo "[${DEVICE_ID}] enviando bundle -> ${PORT}"
scp -P "${PORT}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$BUNDLE" admin@localhost:/home/admin/Lumen_bundle.tar.gz

echo "[${DEVICE_ID}] instalando bundle…"
ssh -p "${PORT}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new admin@localhost -- bash -lc '
  set -euo pipefail
  cd "$HOME"
  mkdir -p "$HOME/.config/onedrive"
  tar -xzf "$HOME/Lumen_bundle.tar.gz" -C "$HOME/.config/onedrive"
  rm -f "$HOME/Lumen_bundle.tar.gz"
  # primer sync (download-only). Cambiamos --synchronize -> --sync
  if command -v onedrive >/dev/null 2>&1; then
    onedrive --sync --download-only --verbose || true
    sudo systemctl restart onedrive-lumen.timer || true
    sudo systemctl start onedrive-lumen.service || true
  fi
'

echo "[${DEVICE_ID}] ✅ bundle instalado"
