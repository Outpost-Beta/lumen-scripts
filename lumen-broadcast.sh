#!/usr/bin/env bash
# lumen-broadcast.sh  (VPS) • Ejecuta un comando en todas las Pis registradas
# Uso:
#   lumen-broadcast.sh [-u] [-P N] [-t SEC] -- <comando...>
#     -u        : solo las que están UP (heartbeat <120s)
#     -P N      : paralelismo (default 4)
#     -t SEC    : timeout por host (default 120)
#
# Ejemplo:
#   lumen-broadcast.sh -u -P 1 -- 'hostnamectl --static'
#   lumen-broadcast.sh -u -- bash -lc 'sudo apt-get update -y && sudo apt-get -y upgrade'

set -euo pipefail

CONF="/etc/lumen-vps.conf"
source "$CONF" 2>/dev/null || { echo "No existe $CONF"; exit 1; }

ONLY_UP=0
PARALLEL=4
TIMEOUT=120

# Parseo de flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) ONLY_UP=1; shift ;;
    -P) PARALLEL="${2:-4}"; shift 2 ;;
    -t) TIMEOUT="${2:-120}"; shift 2 ;;
    --) shift; break ;;
    *) echo "Flag desconocido: $1"; exit 1 ;;
  fi
done

[[ $# -gt 0 ]] || { echo "Falta el comando a ejecutar. Usa -- <comando>"; exit 1; }
CMD=( "$@" )

# Carga lista de objetivos
[[ -f "$DEVICES_TSV" ]] || { echo "No existe $DEVICES_TSV"; exit 0; }

now=$(date -u +%s)
targets=()

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

# Función para ejecutar por host
run_one() {
  local pair="$1"
  local dev="${pair%%:*}"
  local port="${pair##*:}"

  echo "[${dev}] -> ssh -p ${port} admin@localhost -- ${CMD[*]}"
  if output=$(timeout "${TIMEOUT}" ssh -p "${port}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new admin@localhost -- "${CMD[@]}" 2>&1); then
    echo "[${dev}] [OK]"
    [[ -n "$output" ]] && { echo "----- [${dev}] OUTPUT -----"; echo "$output"; }
  else
    rc=$?
    echo "[${dev}] [FAIL] rc=${rc}"
    [[ -n "$output" ]] && { echo "----- [${dev}] ERROR -----"; echo "$output"; }
  fi
}

export -f run_one
export TIMEOUT CMD

# Ejecuta en paralelo con xargs
printf "%s\n" "${targets[@]}" | xargs -I{} -P "${PARALLEL}" bash -lc 'run_one "$@"' _ {}

