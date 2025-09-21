#!/usr/bin/env bash
# reset_vps.sh — Limpia completamente el VPS para reinstalar Lumen
# Versión actualizada para el sistema FTP/rclone.

set -euo pipefail

echo "[1/7] Detener autossh residuales (si hubiera)…"
systemctl stop autossh-lumen.service 2>/dev/null || true
pkill -f 'autossh.*-R' 2>/dev/null || true
pkill -f 'ssh .* -R'   2>/dev/null || true
sleep 1
pkill -9 -f 'autossh.*-R' 2>/dev/null || true
pkill -9 -f 'ssh .* -R'   2>/dev/null || true

echo "[2/7] Liberar puertos de túnel (2201–2399) en known_hosts…"
for port in $(seq 2201 2399); do
  ssh-keygen -R "[localhost]:$port" >/dev/null 2>&1 || true
done

echo "[3/7] Limpiar directorio de trabajo, inventario y heartbeats…"
rm -rf /srv/lumen

echo "[4/7] Eliminar scripts/atajos globales del VPS…"
rm -f /usr/local/bin/lumen-assign.sh \
      /usr/local/bin/lumen-list.sh \
      /usr/local/bin/lumen-broadcast.sh 2>/dev/null || true
rm -rf /etc/lumen /etc/lumen-vps.conf 2>/dev/null || true

echo "[5/7] Restaurar cambios en sshd_config (si se aplicaron)…"
SSHD="/etc/ssh/sshd_config"
if [ -f "$SSHD" ]; then
  sed -i '/^AllowTcpForwarding yes$/d' "$SSHD" || true
  sed -i '/^ClientAliveInterval 300$/d' "$SSHD" || true
  sed -i '/^ClientAliveCountMax 12$/d' "$SSHD" || true
  systemctl restart ssh || true
fi

echo "[6/7] Limpiar known_hosts de la Pi (si enlista IP fija)…"
# Sustituye la IP si sueles conectarte a una IP distinta:
ssh-keygen -R 200.234.230.254 >/dev/null 2>&1 || true

echo "[7/7] Listo. El VPS ha sido limpiado."
echo "✅ VPS limpio (listo para reinstalar)"
