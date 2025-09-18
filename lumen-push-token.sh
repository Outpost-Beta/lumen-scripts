#!/usr/bin/env bash
# lumen-push-token.sh — Empuja el bundle de OneDrive a UNA caja y forza resync.
# Uso: lumen-push-token.sh <DEVICE_ID> <PORT>
# Ejemplo: lumen-push-token.sh Box-00 2201
set -euo pipefail

DEVICE_ID="${1:-}"
PORT="${2:-}"

if [[ -z "$DEVICE_ID" || -z "$PORT" ]]; then
  echo "Uso: $0 <DEVICE_ID> <PORT>    (ej. $0 Box-00 2201)" >&2
  exit 1
fi

# Ruta del bundle en el VPS (usa tu bundle “limpio” central)
TOKENS_DIR="/srv/lumen/onedrive_tokens"
BUNDLE="${TOKENS_DIR}/Lumen_bundle.tar.gz"

[[ -f "$BUNDLE" ]] || { echo "[ERROR] No existe bundle: $BUNDLE"; exit 1; }

echo "[1/4] Copiando bundle a ${DEVICE_ID} (puerto ${PORT})…"
scp -P "$PORT" -o 'StrictHostKeyChecking=accept-new' "$BUNDLE" admin@localhost:/home/admin/Lumen_bundle.tar.gz

echo "[2/4] Instalando bundle y normalizando configuración en la caja…"
ssh -p "$PORT" -o 'StrictHostKeyChecking=accept-new' admin@localhost 'bash -lc "
  set -euo pipefail
  CONF=\$HOME/.config/onedrive
  mkdir -p \"\$CONF\"

  # Desempacar bundle en la conf del cliente
  tar -xzf \"\$HOME/Lumen_bundle.tar.gz\" -C \"\$CONF\"

  # Normalización antianidación (raíz: /home/admin ; sync_list: Lumen)
  if grep -q \"^sync_dir\" \"\$CONF/config\"; then
    sed -i '\''s|^sync_dir *=.*|sync_dir = \"/home/admin\"|'\'' \"\$CONF/config\"
  else
    echo '\''sync_dir = "/home/admin"'\'' >> \"\$CONF/config\"
  fi
  printf \"Lumen\n\" > \"\$CONF/sync_list\"

  # Resetear índice local para que vea deletes y estructura actual
  rm -f \"\$CONF/items.sqlite3\" 2>/dev/null || true

  # Binario real (evita path hardcodeado)
  BIN=\$(command -v onedrive || true)
  if [[ -z \"\$BIN\" ]]; then
    echo \"[ERROR] onedrive no está instalado en la caja\" >&2
    exit 1
  fi

  echo \"[3/4] Forzando resincronización de OneDrive (download-only)…\"
  \"\$BIN\" --confdir \"\$CONF\" --resync --sync --download-only --verbose

  # (Opcional) Borramos el tar en HOME para no dejar basura
  rm -f \"\$HOME/Lumen_bundle.tar.gz\" 2>/dev/null || true
"'

echo "[4/4] Listo. Token instalado y resincronización ejecutada en ${DEVICE_ID}:${PORT}."
