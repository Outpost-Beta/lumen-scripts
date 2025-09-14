#!/usr/bin/env bash
set -euo pipefail

# ==== Parámetros base ====
PI_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$PI_USER" | cut -d: -f6)"
SYNC_DIR="${HOME_DIR}/Lumen"
CFG_DIR="${HOME_DIR}/.config/onedrive"
LOG_DIR="${HOME_DIR}/.cache/onedrive"
REPO_DIR="${HOME_DIR}/onedrive-src"

echo "[1/5] Paquetes base…"
sudo apt-get update -y
# Nota: 'ldc' es el compilador D requerido por onedrive (abraunegg)
sudo apt-get install -y curl build-essential libcurl4-openssl-dev libsqlite3-dev pkg-config git ldc

echo "[2/5] Descargar/compilar onedrive (abraunegg)…"
rm -rf "${REPO_DIR}"
git clone https://github.com/abraunegg/onedrive.git "${REPO_DIR}"
cd "${REPO_DIR}"
./configure
make
sudo make install

echo "[3/5] Configuración de OneDrive → ${SYNC_DIR}"
mkdir -p "${SYNC_DIR}" "${CFG_DIR}" "${LOG_DIR}"
# Configuración mínima. Ajusta filtros luego si lo necesitas.
cat > "${CFG_DIR}/config" <<EOF
# === Config de onedrive (cliente nativo abraunegg) ===
# Directorio local de sincronización (tu reproductor ya usa ~/Lumen)
sync_dir = "${SYNC_DIR}"

# Intervalo de monitorización (segundos) cuando corre en modo servicio
monitor_interval = "300"

# Opciones seguras por defecto
skip_dotfiles = "true"
skip_symlinks = "true"

# Ejemplos de exclusiones (descomentar si hace falta):
# sync_list = "~/.config/onedrive/sync_list"
# application_id = "d50d3c1d-f5d9-4b50-bf3c-1f8a60b8b6d8"  # Usar por defecto, no tocar salvo escenarios especiales
EOF

# (Opcional) Archivo de incluye/excluye si lo quieres usar más adelante:
#   echo "*.tmp" >> "${CFG_DIR}/sync_list"

# Asegura ownership para el usuario normal
chown -R "${PI_USER}:${PI_USER}" "${CFG_DIR}" "${SYNC_DIR}" "${LOG_DIR}"

echo "[4/5] Habilitar servicio de usuario y 'linger'…"
# Permite que los servicios de usuario corran sin sesión abierta
sudo loginctl enable-linger "${PI_USER}" >/dev/null 2>&1 || true

# Asegura estructura de systemd --user
sudo -u "${PI_USER}" mkdir -p "${HOME_DIR}/.config/systemd/user"

# Recarga y habilita el servicio user (instalado por make install)
sudo -u "${PI_USER}" systemctl --user daemon-reload
sudo -u "${PI_USER}" systemctl --user enable onedrive.service

echo "[5/5] Primera ejecución (interactiva, pedirá URL + CÓDIGO)…"
echo ">>> Se mostrará una URL y un CÓDIGO. Abre la URL en un navegador, pega el CÓDIGO y autoriza tu cuenta."
# Lanza onedrive una vez en foreground para provocar el flujo de autorización.
# No marcamos error si termina con código distinto (|| true) porque puede salir tras autorizar.
sudo -u "${PI_USER}" onedrive || true

cat <<'MSG'

✅ Instalación completada.

Datos:
- Carpeta local:  ~/Lumen
- Config:         ~/.config/onedrive/config
- Servicio user:  onedrive.service (systemd --user, con linger habilitado)

Siguientes pasos:
1) Completa la autorización en el navegador usando la URL + CÓDIGO mostrados.
2) Inicia el servicio en background:
     systemctl --user start onedrive.service
   (o en el VPS vía túnel SSH:  ssh -p <PORT> admin@localhost 'systemctl --user start onedrive.service')
3) Revisa logs del servicio:
     journalctl --user-unit=onedrive -n 50 --no-pager

Clonar autorización a otras cajas (opcional, tras autorizar 1ª Pi):
- Desde la Pi autorizada (o vía VPS):
     tar -C ~/.config -cz onedrive > /tmp/onedrive_cfg.tar.gz
- Copia ese tar a cada Pi destino y extrae en ~/.config, luego:
     systemctl --user daemon-reload
     systemctl --user enable --now onedrive.service

MSG
