#!/usr/bin/env bash
set -euo pipefail

BASE="/srv/lumen"
CONF="/etc/lumen-vps.conf"

echo "[1/6] Estructura…"
mkdir -p "$BASE"/{config/devices,cmd/devices,heartbeats,keys}
chown -R root:root "$BASE"

echo "[2/6] Config VPS…"
tee "$CONF" >/dev/null <<'CFG'
DEVICE_PREFIX="Box"
NEXT_INDEX=0
PORT_START=2201
DEVICES_TSV="/srv/lumen/devices.tsv"
KEYS_DIR="/srv/lumen/keys"
CFG

[[ -f "$BASE/devices.tsv" ]] || echo -e "# DEVICE_ID\tPORT" > "$BASE/devices.tsv"

echo "[3/6] lumen-assign.sh (con reuso por clave)…"
cat > /usr/local/bin/lumen-assign.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen-vps.conf"; source "$CONF"
LOCK="/srv/lumen/.assign.lock"

# Uso:
#   lumen-assign.sh --register --pubkey-b64 <BASE64>
# Salida (eval-friendly):
#   DEVICE_ID="Box-00"
#   PORT="2201"

PUBKEY_B64=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --register) MODE=register; shift;;
    --pubkey-b64) PUBKEY_B64="$2"; shift 2;;
    *) echo "Uso: lumen-assign.sh --register --pubkey-b64 <BASE64>"; exit 1;;
  esac
done
[[ "${MODE:-}" == "register" && -n "$PUBKEY_B64" ]] || { echo "Falta --pubkey-b64"; exit 1; }

# Decodifica la clave pública
PUBKEY=$(printf "%s" "$PUBKEY_B64" | base64 -d)

exec 9>"$LOCK"
flock -x 9

PREFIX=$(sed -n 's/^DEVICE_PREFIX="\([^"]*\)"/\1/p' "$CONF")
NEXT=$(sed -n 's/^NEXT_INDEX=\(.*\)/\1/p' "$CONF")
PSTART=$(sed -n 's/^PORT_START=\(.*\)/\1/p' "$CONF")
TSV=$(sed -n 's#^DEVICES_TSV="\([^"]*\)"#\1#p' "$CONF")
KEYS=$(sed -n 's#^KEYS_DIR="\([^"]*\)"#\1#p' "$CONF")

# 1) ¿Esta clave ya existe? -> Reusar ID/puerto
FOUND_DEV=""
if ls "$KEYS"/*.pub >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do
    if cmp -s <(printf "%s\n" "$PUBKEY") "$f"; then
      FOUND_DEV="$(basename "$f" .pub)"
      break
    fi
  done < <(find "$KEYS" -maxdepth 1 -type f -name '*.pub' -print0)
fi

if [[ -n "$FOUND_DEV" ]]; then
  # Busca puerto en TSV
  PORT="$(awk -F'\t' -v d="$FOUND_DEV" '$1==d{print $2}' "$TSV" | tail -n1)"
  if [[ -z "$PORT" ]]; then
    # Si por alguna razón no está en TSV, asígnale uno libre y escríbelo
    port=$PSTART
    while : ; do
      if ! grep -q -P "^\S+\t${port}$" "$TSV" 2>/dev/null && ! ss -lnt "( sport = :$port )" | grep -q "$port"; then
        break
      fi
      port=$((port+1))
    done
    echo -e "${FOUND_DEV}\t${port}" >> "$TSV"
    PORT="$port"
  fi
  touch "/srv/lumen/heartbeats/${FOUND_DEV}.ts"
  echo "DEVICE_ID=\"${FOUND_DEV}\""
  echo "PORT=\"${PORT}\""
  exit 0
fi

# 2) Clave nueva -> asignar ID/puerto nuevos
# Puerto libre
port=$PSTART
while : ; do
  if ! grep -q -P "^\S+\t${port}$" "$TSV" 2>/dev/null && ! ss -lnt "( sport = :$port )" | grep -q "$port"; then
    break
  fi
  port=$((port+1))
done

# ID secuencial
printf -v idx "%02d" "$NEXT"
dev="${PREFIX}-${idx}"
while grep -q -P "^${dev}\t" "$TSV" 2>/dev/null; do
  NEXT=$((NEXT+1))
  printf -v idx "%02d" "$NEXT"
  dev="${PREFIX}-${idx}"
done

# Guarda asignación y clave
echo -e "${dev}\t${port}" >> "$TSV"
echo "$PUBKEY" > "$KEYS/${dev}.pub"
chmod 644 "$KEYS/${dev}.pub"
sed -i "s/^NEXT_INDEX=.*/NEXT_INDEX=$((NEXT+1))/" "$CONF"

touch "/srv/lumen/heartbeats/${dev}.ts"
echo "DEVICE_ID=\"${dev}\""
echo "PORT=\"${port}\""
SH
chmod +x /usr/local/bin/lumen-assign.sh

echo "[4/6] lumen-list.sh…"
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

echo "[5/6] sshd (keepalive/túneles)…"
SSHD="/etc/ssh/sshd_config"
cp -f "$SSHD" "${SSHD}.bak.$(date +%F-%H%M)" || true
# Mantener sesiones
grep -q '^ClientAliveInterval' "$SSHD" && sed -i 's/^ClientAliveInterval.*/ClientAliveInterval 300/' "$SSHD" || echo "ClientAliveInterval 300" >> "$SSHD"
grep -q '^ClientAliveCountMax' "$SSHD" && sed -i 's/^ClientAliveCountMax.*/ClientAliveCountMax 12/' "$SSHD" || echo "ClientAliveCountMax 12" >> "$SSHD"
# Túneles
if grep -q '^AllowTcpForwarding' "$SSHD"; then
  sed -i 's/^AllowTcpForwarding.*/AllowTcpForwarding yes/' "$SSHD"
else
  echo "AllowTcpForwarding yes" >> "$SSHD"
fi
grep -q '^GatewayPorts' "$SSHD" || echo "GatewayPorts no" >> "$SSHD"
systemctl restart ssh

echo "[6/6] Listo ✅  (asignador con reuso por clave)"
