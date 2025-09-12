#!/usr/bin/env bash
set -euo pipefail

BASE="/srv/lumen"
CONF="/etc/lumen-vps.conf"

echo "[1/5] Estructura…"
sudo mkdir -p $BASE/{config/devices,cmd/devices,heartbeats}
sudo chown -R root:root $BASE

echo "[2/5] Config VPS (prefijo y puertos)…"
sudo tee $CONF >/dev/null <<'CFG'
DEVICE_PREFIX="Box"
NEXT_INDEX=0
PORT_START=2201
DEVICES_TSV="/srv/lumen/devices.tsv"
CFG

if [[ ! -f $BASE/devices.tsv ]]; then
  echo -e "# DEVICE_ID\tPORT" | sudo tee $BASE/devices.tsv >/dev/null
fi

echo "[3/5] Asignador de IDs y puertos…"
/usr/bin/env bash -c 'cat << "SH" | sudo tee /usr/local/bin/lumen-assign.sh >/dev/null
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen-vps.conf"
source "$CONF"
LOCK="/srv/lumen/.assign.lock"

MODE=""; HOSTNAME_IN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --register) MODE=register; shift;;
    --hostname) HOSTNAME_IN="$2"; shift 2;;
    *) echo "Uso: lumen-assign.sh --register"; exit 1;;
  esac
done
[[ "$MODE" == "register" ]] || exit 1

exec 9>"$LOCK"
flock -x 9

PREFIX=$(grep -E "^DEVICE_PREFIX=" "$CONF" | cut -d= -f2 | tr -d \")
NEXT=$(grep -E "^NEXT_INDEX=" "$CONF" | cut -d= -f2 | tr -d \")
PSTART=$(grep -E "^PORT_START=" "$CONF" | cut -d= -f2 | tr -d \")
TSV=$(grep -E "^DEVICES_TSV=" "$CONF" | cut -d= -f2 | tr -d \")

port=$PSTART
while : ; do
  if ! grep -q -P "^\S+\t${port}$" "$TSV" 2>/dev/null && ! ss -lnt "( sport = :$port )" | grep -q "$port"; then
    break
  fi
  port=$((port+1))
done

printf -v idx "%02d" "$NEXT"
dev="${PREFIX}-${idx}"

while grep -q -P "^${dev}\t" "$TSV" 2>/dev/null; do
  NEXT=$((NEXT+1))
  printf -v idx "%02d" "$NEXT"
  dev="${PREFIX}-${idx}"
done

echo -e "${dev}\t${port}" | tee -a "$TSV" >/dev/null
sudo sed -i "s/^NEXT_INDEX=.*/NEXT_INDEX=$((NEXT+1))/" "$CONF"

touch "/srv/lumen/heartbeats/${dev}.ts"

echo "DEVICE_ID=\"${dev}\""
echo "PORT=\"${port}\""
SH'
sudo chmod +x /usr/local/bin/lumen-assign.sh

echo "[4/5] Utilidad para listar estado…"
/usr/bin/env bash -c 'cat << "SH" | sudo tee /usr/local/bin/lumen-list.sh >/dev/null
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
    ts=$(cat "$f"); last=$(date -u -d "$ts" +%s 2>/dev/null || echo 0); age=$((now-last))
    up="NO"; [[ $age -le 120 ]] && up="YES"
    printf "%-12s %-6s %-22s %-6s %-3s\n" "$dev" "$port" "$ts" "$age" "$up"
  else
    printf "%-12s %-6s %-22s %-6s %-3s\n" "$dev" "$port" "—" "—" "NO"
  fi
done < "$TSV"
SH'
sudo chmod +x /usr/local/bin/lumen-list.sh

echo "[5/5] Ajustando SSHD…"
SSHD="/etc/ssh/sshd_config"
sudo cp $SSHD ${SSHD}.bak.$(date +%F-%H%M)
sudo sed -i 's/^#\?AllowTcpForwarding.*/AllowTcpForwarding yes/' $SSHD
if ! grep -q "^GatewayPorts" $SSHD; then
  echo "GatewayPorts no" | sudo tee -a $SSHD >/dev/null
fi
sudo systemctl restart ssh

echo "VPS listo ✅
- lumen-assign.sh para nuevas Pis
- lumen-list.sh para estado
- Devices en /srv/lumen/devices.tsv
- Heartbeats en /srv/lumen/heartbeats/
"
