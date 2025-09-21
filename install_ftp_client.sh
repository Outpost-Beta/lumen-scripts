#!/bin/bash
set -e

echo "INFO: Instalando y configurando cliente de sincronización FTP (rclone)..."

# Paso 1: Instalar rclone
if ! command -v rclone &> /dev/null; then
    echo "INFO: Instalando rclone..."
    curl -fsSL https://rclone.org/install.sh | sudo bash
else
    echo "INFO: rclone ya está instalado."
fi

# Paso 2: Crear carpeta local
echo "INFO: Asegurando que el directorio /home/admin/Lumen existe."
mkdir -p /home/admin/Lumen
sudo chown -R admin:admin /home/admin

# Paso 3: Solicitar contraseña y crear remoto FTP
echo "INFO: Configurando el remoto 'Lumen' para rclone..."

# --- INICIO DEL CAMBIO ---
# Solicitar la contraseña de forma segura (no se mostrará en pantalla)
echo -n "Por favor, introduce la contraseña del servidor FTP: "
read -s FTP_PASS
echo # Añade un salto de línea para mejorar el formato de la salida
# --- FIN DEL CAMBIO ---

OBSCURED_PASS=$(rclone obscure "$FTP_PASS")

rclone config create \
  "Lumen" \
  "ftp" \
  "host" "audione.net" \
  "user" "audione1" \
  "pass" "$OBSCURED_PASS" \
  "port" "21" \
  "tls" "false" > /dev/null

echo "INFO: Remoto 'Lumen' creado."

# Paso 4: Instalar el script de sincronización
echo "INFO: Instalando el script de sincronización en /usr/local/bin..."
sudo cp ftp_sync_Lumen.sh /usr/local/bin/ftp_sync_Lumen.sh
sudo chmod +x /usr/local/bin/ftp_sync_Lumen.sh

# Paso 5: Crear servicio systemd
echo "INFO: Creando el servicio systemd 'ftp-sync-Lumen.service'."
sudo tee /etc/systemd/system/ftp-sync-Lumen.service >/dev/null <<'UNIT'
[Unit]
Description=Sync FTP (Lumen:/public_html/Lumen) -> /home/admin/Lumen
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=admin
ExecStart=/usr/local/bin/ftp_sync_Lumen.sh
UNIT

# Paso 6: Crear timer de systemd
echo "INFO: Creando el timer systemd 'ftp-sync-Lumen.timer'."
sudo tee /etc/systemd/system/ftp-sync-Lumen.timer >/dev/null <<'UNIT'
[Unit]
Description=Run ftp-sync-Lumen.service every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=ftp-sync-Lumen.service

[Install]
WantedBy=timers.target
UNIT

# Paso 7: Activar el timer
echo "INFO: Activando y iniciando el timer."
sudo systemctl daemon-reload
sudo systemctl enable --now ftp-sync-Lumen.timer

echo "¡Éxito! El cliente de sincronización FTP ha sido instalado."
