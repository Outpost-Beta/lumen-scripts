# /usr/local/bin/lumen-clean.sh
#!/usr/bin/env bash
set -euo pipefail

USER_HOME="${HOME:-/home/admin}"
CONF_DIR="$USER_HOME/.config/onedrive"
SYNC_DIR="$USER_HOME"
LOCAL_ROOT="$USER_HOME/Lumen"
DRY="${1:-}"   # usar: lumen-clean.sh --dry-run

# ---- Guardas de seguridad ----
if ! grep -qE '^\s*sync_dir\s*=\s*"/home/admin"\s*$' "$CONF_DIR/config"; then
  echo "[ABORT] sync_dir no es /home/admin (revisa $CONF_DIR/config)"; exit 1
fi

# sync_list debe contener *sólo* Lumen (una línea)
if ! [ -f "$CONF_DIR/sync_list" ] || ! [ "$(wc -l < "$CONF_DIR/sync_list" | tr -d ' ')" = "1" ] || ! grep -qx 'Lumen' "$CONF_DIR/sync_list"; then
  echo "[ABORT] sync_list debe contener solo 'Lumen' (revisa $CONF_DIR/sync_list)"; exit 1
fi

# Si no existe la raíz local, nada que limpiar
[ -d "$LOCAL_ROOT" ] || { echo "[OK] $LOCAL_ROOT no existe todavía, nada que limpiar."; exit 0; }

# ---- Obtener listado real en la nube dentro del scope ----
# 'onedrive --list' enumera rutas bajo el scope definido por config/sync_list.
# Normalizamos para quedarnos con rutas relativas a ~/Lumen (sin el prefijo 'Lumen/').
CLOUD_LIST="$(onedrive --confdir "$CONF_DIR" --list || true)"

# Construir set (hash) de rutas válidas en la nube
declare -A CLOUD_SET
while IFS= read -r line; do
  # Tomar solo entradas dentro de Lumen/… y convertir a relativo a ~/Lumen
  rel="${line#Lumen/}"
  # Saltar líneas que no sean de Lumen/ o que sean exactamente 'Lumen'
  [[ "$line" == Lumen ]] && continue
  [[ "$line" == "$rel" ]] && continue
  CLOUD_SET["$rel"]=1
done <<< "$CLOUD_LIST"

deleted=0
preview() { [[ "$DRY" == "--dry-run" ]]; }

# ---- Borrar archivos locales huérfanos ----
while IFS= read -r -d '' f; do
  rel="${f#${LOCAL_ROOT}/}"
  if [[ -z "${CLOUD_SET[$rel]+x}" ]]; then
    if preview; then
      echo "[DRY] delete file: $f"
    else
      rm -f -- "$f" && echo "deleted: $f" || true
    fi
    ((deleted++)) || true
  fi
done < <(find "$LOCAL_ROOT" -type f -print0)

# ---- Quitar directorios vacíos (de mayor a menor profundidad) ----
while IFS= read -r -d '' d; do
  if preview; then
    rmdir --ignore-fail-on-non-empty "$d" 2>/dev/null && echo "[DRY] rmdir: $d" || true
  else
    rmdir --ignore-fail-on-non-empty "$d" 2>/dev/null && echo "rmdir: $d" || true
  fi
done < <(find "$LOCAL_ROOT" -type d -depth -print0)

echo "[DONE] removed $deleted file(s)."
