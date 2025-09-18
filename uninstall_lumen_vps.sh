#!/usr/bin/env bash
# uninstall_lumen_vps.sh • Limpieza completa del VPS

set -euo pipefail

echo "[VPS] Deteniendo listeners (si los hubiera)…"

echo "[VPS] Eliminando inventario/estado…"
rm -rf /srv/lumen/heartbeats || true
rm -rf /srv/lumen/keys || true
rm -f  /srv/lumen/devices.tsv || true
rm -rf /srv/lumen

echo "[VPS] Eliminando utilidades instaladas…"
/bin/rm -f /usr/local/bin/lumen-assign.sh \
          /usr/local/bin/lumen-list.sh \
          /usr/local/bin/lumen-broadcast.sh || true

echo "[VPS] Eliminando configuración…"
/bin/rm -f /etc/lumen-vps.conf || true

echo "[VPS] (Opcional) revertir ajustes mínimos de sshd que agregamos"
SSHD="/etc/ssh/sshd_config"
if [ -f "$SSHD" ]; then
  sed -i '/^AllowTcpForwarding yes$/d' "$SSHD" || true
  sed -i '/^ClientAliveInterval 300$/d' "$SSHD" || true
  sed -i '/^ClientAliveCountMax 12$/d' "$SSHD" || true
  systemctl restart ssh || true
fi

echo "[VPS] Listo: VPS limpio."
