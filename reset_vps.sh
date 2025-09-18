#!/usr/bin/env bash
# reset_vps.sh — Limpia completamente el VPS para reinstalar Lumen
# Preserva /srv/lumen/onedrive_tokens (bundle de OneDrive)

set -euo pipefail

echo "[1/8] Detener autossh residuales (si hubiera)…"
systemctl stop autossh-lumen.service 2>/dev/null || true
pkill -f 'autossh.*-R' 2>/dev/null || true
pkill -f 'ssh .* -R'   2>/dev/null || true
sleep 1
pkill -9 -f 'autossh.*-R' 2>/dev/null || true
pkill -9 -f 'ssh .* -R'   2>/dev/null || true

echo "[2/8] Liberar puertos de túnel (2201–2399) en known_hosts…"
for port in $(seq 2201 2399); do
  ssh-keygen -R "[localhost]:$port" >/dev/null 2>&1 || true
done

echo "[3/8] Respaldar tokens de OneDrive y limpiar /srv/lumen…"
mkdir -p /srv/lumen/onedrive_tokens
TMP_TOK="/srv/onedrive_tokens_backup_$$"
mv /srv/lumen/onedrive_tokens "$TMP_TOK" 2>/dev/null || true
rm -rf /srv/lumen
mkdir -p /srv/lumen
mv "$TMP_TOK" /srv/lumen/onedrive_tokens 2>/dev/null || true
unset TMP_TOK

echo "[4/8] Eliminar inventario y heartbeats…"
rm -rf /srv/lumen/heartbeats 2>/dev/null || true
rm -f /srv/lumen/devices.tsv 2>/dev/null || true

echo "[5/8] Eliminar scripts/atajos globales del VPS…"
rm -f /usr/local/bin/lumen-assign.sh \
      /usr/local/bin/lumen-list.sh \
      /usr/local/bin/lumen-broadcast.sh \
      /usr/local/bin/lumen-push-token.sh 2>/dev/null || true
rm -rf /etc/lumen /etc/lumen-vps.conf 2>/dev/null || true

echo "[6/8] Restaurar cambios en sshd_config (si se aplicaron)…"
SSHD="/etc/ssh/sshd_config"
if [ -f "$SSHD" ]; then
  sed -i '/^AllowTcpForwarding yes$/d' "$SSHD" || true
  sed -i '/^ClientAliveInterval 300$/d' "$SSHD" || true
  sed -i '/^ClientAliveCountMax 12$/d' "$SSHD" || true
  systemctl restart ssh || true
fi

echo "[7/8] Limpiar known_hosts de la Pi (si enlista IP fija)…"
# Sustituye la IP si sueles conectarte a una IP distinta:
ssh-keygen -R 200.234.230.254 >/dev/null 2>&1 || true

echo "[8/8] Listo. Tokens preservados en /srv/lumen/onedrive_tokens"
echo "✅ VPS limpio (listo para reinstalar)"
