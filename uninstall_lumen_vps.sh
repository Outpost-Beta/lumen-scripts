#!/usr/bin/env bash
set -euo pipefail

echo "[VPS] Eliminando estado y configuraciones de Lumen…"

# Borrar estado, dispositivos y heartbeats
rm -rf /srv/lumen

# Borrar scripts instalados
rm -f /usr/local/bin/lumen-assign.sh \
      /usr/local/bin/lumen-list.sh \
      /usr/local/bin/lumen-check.sh 2>/dev/null || true

# Borrar configuración
rm -f /etc/lumen-vps.conf

# Borrar claves locales (opcional, comentar si quieres conservarlas)
rm -f /root/.ssh/id_ed25519 /root/.ssh/id_ed25519.pub

# Limpiar ajustes que agregamos en sshd_config
SSHD="/etc/ssh/sshd_config"
if [ -f "$SSHD" ]; then
  sed -i '/^AllowTcpForwarding yes$/d' "$SSHD" || true
  sed -i '/^ClientAliveInterval 300$/d' "$SSHD" || true
  sed -i '/^ClientAliveCountMax 12$/d' "$SSHD" || true
  systemctl restart ssh || true
fi

echo "[VPS] Limpieza completa."
