#!/bin/bash
set -euo pipefail

DEVICE_ID="$1"
PORT="$2"
TOKEN_DIR="/srv/lumen/onedrive-tokens"

TOKEN_FILE="${TOKEN_DIR}/${DEVICE_ID}.token.json"
if [ ! -f "$TOKEN_FILE" ]; then
  echo "❌ No existe token para $DEVICE_ID"
  exit 1
fi

scp -P "$PORT" "$TOKEN_FILE" admin@localhost:/home/admin/.config/onedrive/items.sqlite
