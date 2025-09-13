#!/usr/bin/env bash
set -euo pipefail

# Ejecuta un comando en muchas Raspberry Pi (vía túneles localhost:PUERTO)
# Requiere que ya esté instalado el lado VPS (devices.tsv, heartbeats, etc.)
#
# Uso:
#   lumen-broadcast.sh [opciones] -- <comando y args>
#
# Opciones:
#   -u, --up-only        Solo a dispositivos con heartbeat reciente (<=120s)
#   -m, --match REGEX    Filtra DEVICE_ID por REGEX (e.g., '^Box-0[0-3]$')
#   -P, --parallel N     Concurrencia (default: 4)
#   -t, --timeout SEC    Timeout por equipo (default: 15)
#   -d, --dry-run        Muestra a quién le pegaría, sin ejecutar
#   -h, --help           Ayuda

CONF="/etc/lumen-vps.conf"
[[ -f "$CONF" ]] || { echo "No existe $CONF. ¿Instalaste el VPS?"; exit 1; }
# shellcheck disable=SC1090
source "$CONF"

TSV="${DEVICES_TSV:-/srv/lumen/devices.tsv}"
HEART="/srv/lumen/heartbeats"

UP_ONLY=false
MATCH_REGEX=""
PAR=4
TIMEOUT=15
DRY=false

print_help() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//'
}

# Parse args
ARGS=()
while [[ $# -gt 0 ]]; do
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

if [[ ${#ARGS[@]} -eq 0 ]]; then
  echo "Falta comando. Ejemplo: lumen-broadcast.sh -u -- 'hostnamectl --static'"
  exit 2
fi

CMD=("${ARGS[@]}")

[[ -f "$TSV" ]] || { echo "No existe $TSV"; exit 1; }

now=$(date -u +%s)
list=()

while IFS=$'\t' read -r dev port; do
  [[ -z "${dev:-}" || "$dev" =~ ^# ]] && continue
  if [[ -n "$MATCH_REGEX" && ! "$dev" =~ $MATCH_REGEX ]]; then
    continue
  fi
  if $UP_ONLY; then
    f="$HEART/$dev.ts"
    if [[ ! -f "$f" ]]; then
      continue
    fi
    ts=$(cat "$f")
    last=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
    age=$((now-last))
    (( age <= 120 )) || continue
  fi
  list+=("$dev:$port")
done < "$TSV"

if [[ ${#list[@]} -eq 0 ]]; then
  echo "No hay dispositivos que coincidan con los filtros."
  exit 0
fi

echo "Objetivos (${#list[@]}): ${list[*]}" | sed 's/ /, /g'

if $DRY; then
  echo "[dry-run] No se ejecuta ningún comando."
  exit 0
fi

# Semáforo de concurrencia simple
active=0
rc_all=0

run_one() {
  local devport="$1"; shift
  local dev="${devport%%:*}"
  local port="${devport##*:}"

  echo "[$dev] -> ssh -p ${port} admin@localhost -- ${*}"
  # Usa StrictHostKeyChecking=accept-new vía ~/.ssh/config si lo añadiste en el installer;
  # por compatibilidad lo forzamos también aquí:
  if output=$(timeout "${TIMEOUT}" ssh -o StrictHostKeyChecking=accept-new -p "${port}" admin@localhost -- "$@" 2>&1); then
    echo "[$dev] [OK]"
    echo "----- [$dev] STDOUT -----"
    [[ -n "$output" ]] && echo "$output"
  else
    status=$?
    echo "[$dev] [FAIL] rc=${status}"
    echo "----- [$dev] STDERR -----"
    [[ -n "$output" ]] && echo "$output" 1>&2
    return "$status"
  fi
}

for dp in "${list[@]}"; do
  run_one "$dp" "${CMD[@]}" &
  active=$((active+1))
  if (( active >= PAR )); then
    if ! wait -n; then rc_all=1; fi
    active=$((active-1))
  fi
done

# Espera a que terminen todos
while (( active > 0 )); do
  if ! wait -n; then rc_all=1; fi
  active=$((active-1))
done

exit "$rc_all"
