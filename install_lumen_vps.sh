#!/usr/bin/env bash
set -euo pipefail

BASE="/srv/lumen"
CONF="/etc/lumen-vps.conf"

echo "[1/5] Estructura…"
mkdir -p "$BASE"/{config/devices,cmd/devices,heartbeats}
chown -R root:root "$BASE"

echo "[2/5] Config VPS (prefijo y puertos)…"
tee "$CONF" >/dev/null <<'CFG'
DEVICE_PREFIX="Box"
NEXT_INDEX=0
PORT_START=2201
DEVICES_TSV="/srv/lumen/devices.tsv"
CFG

# Inicia devices.tsv si no existe
[[ -f "$BASE/devices.tsv" ]] || echo -e "# DEVICE_ID\tPORT" > "$BASE/devices.tsv"

echo "[3/5] Asignador de IDs/puertos…"
cat > /usr/local/bin/lumen-assign.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen-vps.conf"
source "$CONF"
LOCK="/srv/lumen/.assign.lock"

# Uso:
#   lumen-assign.sh --register
# Salida (eval-friendly):
#   DEVICE_ID="Box-00"
#   PORT="2201"

[[ "${1:-}" == "--register" ]] || { echo "Uso: lumen-assign.sh --register"; exit 1; }

exec 9>"$LOCK"
flock -x 9

PREFIX=$(sed -n 's/^DEVICE_PREFIX="\([^"]*\)"/\1/p' "$CONF")
NEXT=$(sed -n 's/^NEXT_INDEX=\(.*\)/\1/p' "$CONF")
PSTART=$(sed -n 's/^PORT_START=\(.*\)/\1/p' "$CONF")
TSV=$(sed -n 's#^DEVICES_TSV="\([^"]*\)"#\1#p' "$CONF")

# Encuentra puerto libre (no en TSV y no escuchando)
port=$PSTART
while : ; do
  if ! grep -q -P "^\S+\t${port}$" "$TSV" 2>/dev/null && ! ss -lnt "( sport = :$port )" | grep -q "$port"; then
    break
  fi
  port=$((port+1))
done

# Genera siguiente ID Box-XX
printf -v idx "%02d" "$NEXT"
dev="${PREFIX}-${idx}"
while grep -q -P "^${dev}\t" "$TSV" 2>/dev/null; do
  NEXT=$((NEXT+1))
  printf -v idx "%02d" "$NEXT"
  dev="${PREFIX}-${idx}"
done

echo -e "${dev}\t${port}" >> "$TSV"
sed -i "s/^NEXT_INDEX=.*/NEXT_INDEX=$((NEXT+1))/" "$CONF"
touch "/srv/lumen/heartbeats/${dev}.ts"

echo "DEVICE_ID=\"${dev}\""
echo "PORT=\"${port}\""
SH
chmod +x /usr/local/bin/lumen-assign.sh

echo "[4/5] lumen-list.sh…"
cat > /usr/local/bin/lumen-list.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen-vps.conf"
source "$CONF"
HEART="/srv/lumen/heartbeats"
TSV="$DEVICES_TSV"
now=$(date -u +%s)
printf "%-12s %-6s %-22s %-6s %-3s\n" "DEVICE_ID" "PORT" "Last Seen (UTC)" "Age(s)" "UP?"
while IFS=$'\t' read -r dev port; do
  [[ -z "$dev" || "$dev" =~ ^# ]] && continue
  f="$HEART/$dev.ts"
  if [[ -f "$f" ]]; then
    ts=$(cat "$f")
    last=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
    age=$((now-last))
    up="NO"; [[ $age -le 120 ]] && up="YES"
    printf "%-12s %-6s %-22s %-6s %-3s\n" "$dev" "$port" "$ts" "$age" "$up"
  else
    printf "%-12s %-6s %-22s %-6s %-3s\n" "$dev" "$port" "—" "—" "NO"
  fi
done < "$TSV"
SH
chmod +x /usr/local/bin/lumen-list.sh

echo "[5/5] Ajustando sshd…"
SSHD="/etc/ssh/sshd_config"
cp -f "$SSHD" "${SSHD}.bak.$(date +%F-%H%M)" || true
if grep -q '^AllowTcpForwarding' "$SSHD"; then
  sed -i 's/^AllowTcpForwarding.*/AllowTcpForwarding yes/' "$SSHD"
else
  echo "AllowTcpForwarding yes" >> "$SSHD"
fi
grep -q '^GatewayPorts' "$SSHD" || echo "GatewayPorts no" >> "$SSHD"
systemctl restart ssh

echo "VPS listo ✅  (assign/list instalados)"
