#!/usr/bin/env bash
set -euo pipefail

BASE="/srv/lumen"
CONF="/etc/lumen-vps.conf"

echo "[1/8] Estructura en ${BASE}…"
mkdir -p "$BASE"/{config/devices,cmd/devices,heartbeats,keys}
chown -R root:root "$BASE"

echo "[2/8] Config del VPS…"
tee "$CONF" >/dev/null <<'CFG'
DEVICE_PREFIX="Box"
NEXT_INDEX=0
PORT_START=2201
DEVICES_TSV="/srv/lumen/devices.tsv"
KEYS_DIR="/srv/lumen/keys"
CFG

[[ -f "$BASE/devices.tsv" ]] || echo -e "# DEVICE_ID\tPORT" > "$BASE/devices.tsv"

echo "[3/8] Clave del root del VPS y publicación…"
mkdir -p /root/.ssh && chmod 700 /root/.ssh
if [[ ! -f /root/.ssh/id_ed25519 ]]; then
  ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -C "root@$(hostname -s)"
fi
install -m 644 /root/.ssh/id_ed25519.pub /srv/lumen/vps_root_id_ed25519.pub

echo "[4/8] lumen-assign.sh (reuso por clave pública)…"
cat > /usr/local/bin/lumen-assign.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen-vps.conf"; source "$CONF"
LOCK="/srv/lumen/.assign.lock"

PUBKEY_B64=""
MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --register) MODE="register"; shift;;
    --pubkey-b64) PUBKEY_B64="$2"; shift 2;;
    *) echo "Uso: lumen-assign.sh --register --pubkey-b64 <BASE64>"; exit 1;;
  esac
done
[[ "$MODE" == "register" && -n "$PUBKEY_B64" ]] || { echo "Falta --pubkey-b64"; exit 1; }

PUBKEY=$(printf "%s" "$PUBKEY_B64" | base64 -d)

exec 9> "$LOCK"; flock -x 9

PREFIX=$(sed -n 's/^DEVICE_PREFIX="\([^"]*\)"/\1/p' "$CONF")
NEXT=$(sed -n 's/^NEXT_INDEX=\(.*\)/\1/p' "$CONF")
PSTART=$(sed -n 's/^PORT_START=\(.*\)/\1/p' "$CONF")
TSV=$(sed -n 's#^DEVICES_TSV="\([^"]*\)"#\1#p' "$CONF")
KEYS=$(sed -n 's#^KEYS_DIR="\([^"]*\)"#\1#p' "$CONF")

choose_port() {
  local port=$PSTART
  while : ; do
    if ! grep -q -P "^\S+\t${port}$" "$TSV" 2>/dev/null && ! ss -lnt "( sport = :$port )" | grep -q "$port"; then
      echo "$port"; return 0
    fi
    port=$((port+1))
  done
}

# Reusar por clave pública
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
  PORT="$(awk -F'\t' -v d="$FOUND_DEV" '$1==d{print $2}' "$TSV" | tail -n1 || true)"
  if [[ -z "${PORT:-}" ]]; then
    PORT="$(choose_port)"
    echo -e "${FOUND_DEV}\t${PORT}" >> "$TSV"
  fi
  touch "/srv/lumen/heartbeats/${FOUND_DEV}.ts"
  echo "DEVICE_ID=\"${FOUND_DEV}\""
  echo "PORT=\"${PORT}\""
  exit 0
fi

# Nueva clave: asigna ID+puerto
port="$(choose_port)"
printf -v idx "%02d" "$NEXT"
dev="${PREFIX}-${idx}"
while grep -q -P "^${dev}\t" "$TSV" 2>/dev/null; do
  NEXT=$((NEXT+1)); printf -v idx "%02d" "$NEXT"; dev="${PREFIX}-${idx}"
done

echo -e "${dev}\t${port}" >> "$TSV"
echo "$PUBKEY" > "$KEYS/${dev}.pub"
chmod 644 "$KEYS/${dev}.pub"
sed -i "s/^NEXT_INDEX=.*/NEXT_INDEX=$((NEXT+1))/" "$CONF"
touch "/srv/lumen/heartbeats/${dev}.ts"

echo "DEVICE_ID=\"${dev}\""
echo "PORT=\"${port}\""
SH
chmod +x /usr/local/bin/lumen-assign.sh

echo "[5/8] lumen-list.sh (UTC + Local)…"
cat > /usr/local/bin/lumen-list.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen-vps.conf"; source "$CONF"
HEART="/srv/lumen/heartbeats"
TSV="$DEVICES_TSV"
now_utc_s=$(date -u +%s)
printf "%-12s %-6s %-22s %-25s %-3s\n" "DEVICE_ID" "PORT" "Last Seen (UTC)" "Last Seen (Local)" "UP?"
while IFS=$'\t' read -r dev port; do
  [[ -z "${dev:-}" || "$dev" =~ ^# ]] && continue
  f="$HEART/$dev.ts"
  if [[ -f "$f" ]]; then
    ts=$(cat "$f")
    last_utc_s=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
    ts_local=$(date -d "$ts" +"%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || echo "—")
    age=$(( now_utc_s - last_utc_s ))
    up="NO"; [[ $age -le 120 ]] && up="YES"
    printf "%-12s %-6s %-22s %-25s %-3s\n" "$dev" "$port" "$ts" "$ts_local" "$up"
  else
    printf "%-12s %-6s %-22s %-25s %-3s\n" "$dev" "$port" "—" "—" "NO"
  fi
done < "$TSV"
SH
chmod +x /usr/local/bin/lumen-list.sh

echo "[6/8] lumen-broadcast.sh…"
cat > /usr/local/bin/lumen-broadcast.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen-vps.conf"; source "$CONF"
TSV="${DEVICES_TSV:-/srv/lumen/devices.tsv}"
HEART="/srv/lumen/heartbeats"

UP_ONLY=false; MATCH_REGEX=""; PAR=4; TIMEOUT=15; DRY=false
print_help(){ grep '^#' "$0" | sed 's/^# \{0,1\}//'; }
[[ $# -eq 0 ]] && { echo "Uso: lumen-broadcast.sh [-u] [-m REGEX] [-P N] [-t SEC] [-d] -- <cmd>"; exit 2; }

ARGS=(); while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--up-only) UP_ONLY=true; shift;;
    -m|--match) MATCH_REGEX="$2"; shift 2;;
    -P|--parallel) PAR="$2"; shift 2;;
    -t|--timeout) TIMEOUT="$2"; shift 2;;
    -d|--dry-run) DRY=true; shift;;
    -h|--help) print_help; exit 0;;
    --) shift; ARGS+=("$@"); break;;
    *) ARGS+=("$1"); shift;;
  esac
done
[[ ${#ARGS[@]} -gt 0 ]] || { echo "Falta comando tras --"; exit 2; }
CMD=("${ARGS[@]}")

[[ -f "$TSV" ]] || { echo "No existe $TSV"; exit 1; }

now=$(date -u +%s); list=()
while IFS=$'\t' read -r dev port; do
  [[ -z "${dev:-}" || "$dev" =~ ^# ]] && continue
  [[ -n "$MATCH_REGEX" && ! "$dev" =~ $MATCH_REGEX ]] && continue
  if $UP_ONLY; then
    f="$HEART/$dev.ts"; [[ -f "$f" ]] || continue
    ts=$(cat "$f"); last=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
    age=$((now-last)); (( age <= 120 )) || continue
  fi
  list+=("$dev:$port")
done < "$TSV"

[[ ${#list[@]} -gt 0 ]] || { echo "No hay objetivos."; exit 0; }
echo "Objetivos (${#list[@]}): ${list[*]}" | sed 's/ /, /g'
$DRY && { echo "[dry-run] fin."; exit 0; }

run_one(){ local dp="$1"; shift; local dev="${dp%%:*}"; local port="${dp##*:}"
  echo "[$dev] -> ssh -p ${port} admin@localhost -- $*"
  if output=$(timeout "${TIMEOUT}" ssh -o StrictHostKeyChecking=accept-new -p "${port}" admin@localhost -- "$@" 2>&1); then
    echo "[$dev] [OK]"; [[ -n "$output" ]] && echo "----- [$dev] OUTPUT -----"$'\n'"$output"
  else status=$?; echo "[$dev] [FAIL] rc=$status"; [[ -n "$output" ]] && echo "----- [$dev] ERROR -----"$'\n'"$output" 1>&2; return $status; fi
}

active=0; rc_all=0
for dp in "${list[@]}"; do
  run_one "$dp" "${CMD[@]}" &
  active=$((active+1))
  if (( active >= PAR )); then if ! wait -n; then rc_all=1; fi; active=$((active-1)); fi
done
while (( active > 0 )); do if ! wait -n; then rc_all=1; fi; active=$((active-1)); done
exit "$rc_all"
SH
chmod +x /usr/local/bin/lumen-broadcast.sh

echo "[7/8] sshd: forwarding + keepalive…"
SSHD="/etc/ssh/sshd_config"
cp -f "$SSHD" "${SSHD}.bak.$(date +%F-%H%M)" || true
grep -q '^AllowTcpForwarding' "$SSHD" && sed -i 's/^AllowTcpForwarding.*/AllowTcpForwarding yes/' "$SSHD" || echo "AllowTcpForwarding yes" >> "$SSHD"
grep -q '^GatewayPorts' "$SSHD" || echo "GatewayPorts no" >> "$SSHD"
grep -q '^ClientAliveInterval' "$SSHD" && sed -i 's/^ClientAliveInterval.*/ClientAliveInterval 300/' "$SSHD" || echo "ClientAliveInterval 300" >> "$SSHD"
grep -q '^ClientAliveCountMax' "$SSHD" && sed -i 's/^ClientAliveCountMax.*/ClientAliveCountMax 12/' "$SSHD" || echo "ClientAliveCountMax 12" >> "$SSHD"
systemctl restart ssh

echo "[8/8] SSH config (host key auto-acept)…"
mkdir -p /root/.ssh && chmod 700 /root/.ssh
if ! grep -q '^Host localhost' /root/.ssh/config 2>/dev/null; then
  cat >> /root/.ssh/config <<'CFG'

# Acepta automáticamente nuevas huellas para túneles localhost:PUERTO
Host localhost
    StrictHostKeyChecking accept-new
    UserKnownHostsFile /root/.ssh/known_hosts
CFG
  chmod 600 /root/.ssh/config
fi

echo "[VPS] Listo ✅"
echo "  - lumen-list.sh, lumen-assign.sh, lumen-broadcast.sh instalados"
