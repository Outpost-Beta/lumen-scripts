#!/usr/bin/env bash
set -euo pipefail

VPS_HOST="200.234.230.254"
VPS_USER="root"
DEVICE_ID="$(hostname -s)"
LUMEN_DIR="/home/pi/Lumen"
CONF_DIR="/etc/lumen"
BIN_DIR="/usr/local/bin"
LOG_DIR="/var/log"
PORT_DEFAULT="2201"  # cambia si agregas más Raspberry

sudo mkdir -p "$CONF_DIR"
sudo mkdir -p /var/local/rpi-setup
mkdir -p "$LUMEN_DIR"/{Canciones,Anuncios,Navideña,Temporada}

echo "[1/8] Actualizando paquetes…"
sudo apt update
sudo apt install -y autossh openssh-client python3 python3-pip vlc python3-vlc alsa-utils jq rsync

echo "[2/8] Generando clave SSH si no existe…"
if [[ ! -f /home/pi/.ssh/id_ed25519 ]]; then
  sudo -u pi mkdir -p /home/pi/.ssh
  sudo -u pi ssh-keygen -t ed25519 -f /home/pi/.ssh/id_ed25519 -N "" -C "pi@${DEVICE_ID}"
fi
chmod 700 /home/pi/.ssh
chmod 600 /home/pi/.ssh/id_ed25519
chmod 644 /home/pi/.ssh/id_ed25519.pub

echo "[3/8] Configuración inicial…"
sudo tee "$CONF_DIR/lumen.conf" >/dev/null <<CFG
DEVICE_ID="${DEVICE_ID}"
VPS_HOST="${VPS_HOST}"
VPS_USER="${VPS_USER}"
PORT="${PORT_DEFAULT}"
VOLUME="90"
XMAS_START="12-01"
XMAS_END="01-07"
SEASON_START=""
SEASON_END=""
ADS_SOURCE="Anuncios"
CFG

echo "[4/8] Servicio AutoSSH…"
sudo tee /etc/systemd/system/autossh-lumen.service >/dev/null <<'UNIT'
[Unit]
Description=AutoSSH reverse tunnel to VPS
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/lumen/lumen.conf
User=pi
ExecStart=/usr/bin/autossh -M 0 -N \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new \
  -i /home/pi/.ssh/id_ed25519 \
  -R ${PORT}:localhost:22 ${VPS_USER}@${VPS_HOST}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

echo "[5/8] Player de música…"
/usr/bin/python3 -m pip install --break-system-packages watchdog

sudo tee ${BIN_DIR}/lumen_player.py >/dev/null <<'PY'
#!/usr/bin/env python3
import os, random, time, subprocess, datetime
from pathlib import Path

CONF = "/etc/lumen/lumen.conf"
HOME = Path.home()
LUMEN = HOME / "Lumen"
CANC = LUMEN / "Canciones"
ANUN = LUMEN / "Anuncios"
NAVI = LUMEN / "Navideña"
TEMP = LUMEN / "Temporada"

def read_conf():
    env = {}
    try:
        with open(CONF) as f:
            for line in f:
                line=line.strip()
                if not line or line.startswith("#"): continue
                k,v = line.split("=",1)
                env[k.strip()] = v.strip().strip('"')
    except Exception:
        pass
    return env

def within_range(today, start, end):
    if not start or not end: return False
    sm,sd = map(int,start.split("-"))
    em,ed = map(int,end.split("-"))
    tm,td = map(int,today.split("-"))
    if sm>em or (sm==em and sd>ed):
        return (tm>sm or (tm==sm and td>=sd)) or (tm<em or (tm==em and td<=ed))
    return (tm>sm or (tm==sm and td>=sd)) and (tm<em or (tm==em and td<=ed))

def list_mp3s(folder):
    if not folder.exists(): return []
    return sorted([str(p) for p in folder.glob("*.mp3")])

def play_file(path, vol):
    subprocess.run(["amixer","set","PCM",f"{vol}%"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["cvlc","--play-and-exit","--no-video","--aout=alsa",path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def main():
    pool={"songs":[],"xmas":[],"ads":[],"temp":[]}
    while True:
        env = read_conf()
        vol = int(env.get("VOLUME","90"))
        ads_source = env.get("ADS_SOURCE","Anuncios")
        today = datetime.datetime.now().strftime("%m-%d")
        xmas = within_range(today, env.get("XMAS_START",""), env.get("XMAS_END",""))
        season = within_range(today, env.get("SEASON_START",""), env.get("SEASON_END",""))

        songs=list_mp3s(CANC); ads=list_mp3s(ANUN); xms=list_mp3s(NAVI); temp=list_mp3s(TEMP)
        if not pool["songs"]: pool["songs"]=random.sample(songs,len(songs)) if songs else []
        if not pool["ads"]:   pool["ads"]=ads[:]
        if not pool["xmas"]:  pool["xmas"]=random.sample(xms,len(xms)) if xms else []
        if not pool["temp"]:  pool["temp"]=temp[:]

        seq=[]
        for _ in range(3):
            if pool["songs"]: seq.append(pool["songs"].pop(0))
        if season and pool["temp"]: seq.append(pool["temp"].pop(0))
        else:
            if ads_source=="Temporada" and pool["temp"]: seq.append(pool["temp"].pop(0))
            elif pool["ads"]: seq.append(pool["ads"].pop(0))
        if xmas and pool["xmas"]: seq.append(pool["xmas"].pop(0))

        if not seq: time.sleep(5); continue
        for track in seq:
            if track and os.path.exists(track): play_file(track, vol)
        time.sleep(1)

if __name__=="__main__": main()
PY
sudo chmod +x ${BIN_DIR}/lumen_player.py

sudo tee /etc/systemd/system/lumen-player.service >/dev/null <<'UNIT'
[Unit]
Description=Lumen MP3 Player
After=sound.target network-online.target
Wants=network-online.target

[Service]
User=pi
Restart=always
RestartSec=2
ExecStart=/usr/local/bin/lumen_player.py
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT

echo "[6/8] Agente de sincronización y heartbeat…"
sudo tee ${BIN_DIR}/lumen-agent.sh >/dev/null <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/lumen/lumen.conf"
source "$CONF"
ssh -i /home/pi/.ssh/id_ed25519 ${VPS_USER}@${VPS_HOST} "date -u +%Y-%m-%dT%H:%M:%SZ > /srv/lumen/heartbeats/${DEVICE_ID}.ts" || true
AGENT
sudo chmod +x ${BIN_DIR}/lumen-agent.sh

sudo tee /etc/systemd/system/lumen-agent.timer >/dev/null <<'UNIT'
[Unit]
Description=Lumen Agent Timer

[Timer]
OnBootSec=30
OnUnitActiveSec=60
Unit=lumen-agent.service

[Install]
WantedBy=timers.target
UNIT

sudo tee /etc/systemd/system/lumen-agent.service >/dev/null <<'UNIT'
[Unit]
Description=Lumen Agent
After=network-online.target
Wants=network-online.target

[Service]
User=pi
Type=oneshot
ExecStart=/usr/local/bin/lumen-agent.sh
UNIT

echo "[7/8] Habilitando servicios…"
sudo systemctl daemon-reload
sudo systemctl enable --now autossh-lumen.service lumen-player.service lumen-agent.timer

echo "✅ Instalación completada.
Recuerda ejecutar: ssh-copy-id -i ~/.ssh/id_ed25519.pub ${VPS_USER}@${VPS_HOST}"
