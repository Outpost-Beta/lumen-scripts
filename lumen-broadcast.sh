#!/usr/bin/env bash
# lumen-broadcast.sh  (VPS) • Ejecuta un comando en todas las Pis registradas
# Uso:
#   lumen-broadcast.sh [-u] [-P N] [-t SEC] -- <comando...>
#     -u        : solo las que están UP (heartbeat <120s)
#     -P N      : paralelismo (default 4)
#     -t SEC    : timeout por host (default 120)
#
# Requiere: /etc/lumen-vps.conf con DEVICES_TSV y heartbeats.

set -euo pipefail

CONF="/etc/lumen-vps.conf"
source "$CONF" 2>/dev/null || { echo "No existe $CONF"; exit 1; }

ONLY_UP=0
PARALLEL=4
TIMEOUT=120
KNOWN="/srv/lumen/known_hosts"   # known_hosts dedicado para broadcast
mkdir -p /srv/lumen
touch "$KNOWN"

# Parseo de flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) ONLY_UP=1; shift ;;
    -P) PARALLEL="${2:-4}"; shift 2 ;;
    -t) TIMEOUT="${2:-120}"; shift 2 ;;
    --) shift; break ;;
    *) echo "Flag desconocido: $1"; exit 1 ;;
  esac
done
[[ $# -gt 0 ]] || { echo "Falta el comando a ejecutar. Usa -- <comando>"; exit 1; }
CMD=( "$@" )

[[ -f "$DEVICES_TSV" ]] || { echo "No existe $DEVICES_TSV"; exit 0; }

now=$(date -u +%s)
targets=()

# Construir lista de objetivos
while read -r DEVICE_ID PORT HOSTNAME; do
  [[ -z "${DEVICE_ID:-}" ]] && continue
  if (( ONLY_UP )); then
    hb="/srv/lumen/heartbeats/${DEVICE_ID}.ts"
    if [[ -f "$hb" ]]; then
      ts=$(cat "$hb")
      last=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
      age=$((now - last))
      (( age < 120 )) || continue
    else
      continue
    fi
  fi
  targets+=( "${DEVICE_ID}:${PORT}" )
done < "$DEVICES_TSV"

# Salida si no hay objetivos
if (( ${#targets[@]} == 0 )); then
  echo "Sin objetivos."
  exit 0
fi

echo "Objetivos, (${#targets[@]}):, ${targets[*]// /, }"

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN")

run_one() {
  local pair="$1"
  local dev="${pair%%:*}"
  local port="${pair##*:}"

  # Purga clave previa del puerto para evitar "REMOTE HOST IDENTIFICATION HAS CHANGED!"
  ssh-keygen -R "[localhost]:${port}" -f "$KNOWN" >/dev/null 2>&1 || true

  echo "[${dev}] -> ssh -p ${port} admin@localhost -- ${CMD[*]}"
  local output rc=0
  if output=$(timeout "${TIMEOUT}" ssh -p "${port}" "${SSH_OPTS[@]}" admin@localhost -- "${CMD[@]}" 2>&1); then
    echo "[${dev}] [OK]"
    [[ -n "$output" ]] && { echo "----- [${dev}] OUTPUT -----"; echo "$output"; }
  else
    rc=$?
    echo "[${dev}] [FAIL] rc=${rc}"
    [[ -n "$output" ]] && { echo "----- [${dev}] ERROR -----"; echo "$output"; }
  fi
}

# Paralelismo controlado
active=0
for pair in "${targets[@]}"; do
  run_one "$pair" &
  ((active++))
  if (( active >= PARALLEL )); then
    wait -n
    ((active--))
  fi
done
wait
