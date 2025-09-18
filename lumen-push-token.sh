#!/usr/bin/env bash
# lumen-push-token.sh — Empuja el bundle de OneDrive a una Pi y fuerza el primer resync (solo descarga)
# Uso:
#   lumen-push-token.sh <DEVICE_ID> <PORT>
# Ejemplo:
#   lumen-push-token.sh Box-00 2201
#
# Requisitos:
# - Bundle en el VPS: /srv/lumen/onedrive_tokens/Lumen_bundle.tar.gz
#   (DEBE contener SOLO: config, refresh_token, sync_list)
# - Acceso por túnel reverso: ssh/scp a admin@localhost -p <PORT>
# - En la Pi: onedrive (abraunegg) instalado, servicio/timer onedrive-lumen.*

set -euo pipefail

BUNDLE="/srv/lumen/onedrive_tokens/Lumen_bundle.tar.gz"
REMOTE_USER="admin"
REMOTE_HOST="localhost"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)
TIMEOUT=120

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  echo "Uso: $0 <DEVICE_ID> <PORT>"
  exit 1
}

[[ $# -eq 2 ]] || usage
DEVICE_ID="$1"
PORT="$2"

[[ -f "$BUNDLE" ]] || die "No existe bundle: $BUNDLE
Crea uno con: tar -C /root/OD_BUNDLE -czf $BUNDLE config refresh_token sync_list"

echo "[$DEVICE_ID] enviando bundle -> $PORT"

# Pasar el bundle
if ! timeout "$TIMEOUT" scp -P "$PORT" "${SSH_OPTS[@]}" "$BUNDLE" "${REMOTE_USER}@${REMOTE_HOST}:/home/${REMOTE_USER}/Lumen_bundle.tar.gz" 2>&1; then
  die "scp falló (puerto $PORT). ¿Está la Pi arriba y el túnel activo?"
fi

echo "[$DEVICE_ID] instalando bundle…"

# Preparar y aplicar en la Pi:
# - crear carpetas
# - extraer bundle en ~/.config/onedrive
# - eliminar DB y hashes heredados
# - detener timer/servicio
# - primer resync (solo descarga)
# - reactivar timer
REMOTE_CMD=$(cat <<'EOSH'
set -euo pipefail
CONF_DIR="$HOME/.config/onedrive"
mkdir -p "$CONF_DIR"
tar -xzf "$HOME/Lumen_bundle.tar.gz" -C "$CONF_DIR"

# Asegura permisos de usuario sobre los archivos del bundle
chown "$USER":"$USER" "$CONF_DIR"/config "$CONF_DIR"/refresh_token "$CONF_DIR"/sync_list 2>/dev/null || true
chmod 600 "$CONF_DIR"/config "$CONF_DIR"/refresh_token 2>/dev/null || true

# Limpia rastros de otra máquina para evitar reconciliaciones extrañas
rm -f "$CONF_DIR/items.sqlite3" "$CONF_DIR/.config.hash" "$CONF_DIR/.sync_list.hash" 2>/dev/null || true

# Asegura carpeta local de trabajo
mkdir -p "$HOME/Lumen"

# Detén servicio/timer antes del primer resync
sudo systemctl stop onedrive-lumen.timer onedrive-lumen.service 2>/dev/null || true

# Primer resync (solo descarga). Puede tardar si hay muchos archivos.
if ! /usr/local/bin/onedrive --resync --download-only --verbose; then
  echo "[WARN] onedrive --resync devolvió error. Revisa 'journalctl -u onedrive-lumen.service' luego." >&2
fi

# Reactiva el timer (cada 5 min)
sudo systemctl enable --now onedrive-lumen.timer >/dev/null 2>&1 || true

# Limpia bundle temporal
rm -f "$HOME/Lumen_bundle.tar.gz" 2>/dev/null || true

echo "[OK] Bundle aplicado y resync inicial ejecutado."
EOSH
)

# Ejecutar en remoto
if ! timeout "$TIMEOUT" ssh -p "$PORT" "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" -- bash -lc "$REMOTE_CMD"; then
  die "Aplicación remota del bundle falló."
fi

echo "[$DEVICE_ID] ✅ bundle instalado"
