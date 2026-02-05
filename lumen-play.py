#!/usr/bin/env python3
# /usr/local/bin/lumen-play.py
# Reproductor Lumen Dinámico v3.0
# Controlado por /home/admin/Lumen/player_config.txt

import os, sys, time, random, glob, vlc
from datetime import datetime

# --- CONFIGURACIÓN ---
BASE_DIR = "/home/admin/Lumen"
CONF_FILE = os.path.join(BASE_DIR, "player_config.txt")

# Carpetas de Audio
DIR_CANC = os.path.join(BASE_DIR, "Canciones")
DIR_ANUN = os.path.join(BASE_DIR, "Anuncios")
DIR_TEMP = os.path.join(BASE_DIR, "Temporada")
DIR_NAV  = os.path.join(BASE_DIR, "Navideña")

# Audio Output (ALSA hw:0,0 por defecto)
ALSA_DEVICE = os.getenv("LUMEN_ALSA_DEVICE", "hw:0,0")

# Estado Global
state = {
    "config": {},
    "last_conf_mtime": 0,
    "anuncio_idx": 0,    # Índice para anuncios alfabéticos
    "temporada_idx": 0,  # Índice para anuncios temporada alfabéticos
    "song_bag": [],      # Bolsa aleatoria canciones
    "nav_bag": []        # Bolsa aleatoria navidad
}

def log(msg):
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}", flush=True)

def get_files(folder):
    """Busca MP3 ignorando mayúsculas/minúsculas"""
    if not os.path.isdir(folder): return []
    files = glob.glob(os.path.join(folder, "*.[mM][pP]3"))
    return sorted([f for f in files if os.path.isfile(f)])

def parse_date(date_str):
    """Convierte 'dd/mm/aa' a objeto date. Retorna None si falla."""
    if not date_str: return None
    try:
        return datetime.strptime(date_str.strip(), "%d/%m/%y").date()
    except ValueError:
        log(f"[WARN] Fecha inválida en config: {date_str}")
        return None

def load_config():
    """Lee el TXT y actualiza la configuración en memoria"""
    default_conf = {
        "Canciones": 2, "Anuncios": 1, "Temporada": 0, "Navidad": 0,
        "TempFechaIni": None, "TempFechaFin": None,
        "NavFechaIni": None, "NavFechaFin": None
    }
    
    if not os.path.isfile(CONF_FILE):
        log("[WARN] No existe player_config.txt, usando defaults.")
        return default_conf

    try:
        mtime = os.path.getmtime(CONF_FILE)
        # Si no ha cambiado, no hacemos nada (optimización)
        if mtime == state["last_conf_mtime"]:
            return state["config"]
        
        log("[INFO] Recargando configuración...")
        new_conf = default_conf.copy()
        
        with open(CONF_FILE, 'r') as f:
            for line in f:
                if ':' not in line: continue
                key, val = line.split(':', 1)
                key = key.strip()
                val = val.strip()
                
                if key in ["Canciones", "Anuncios", "Temporada", "Navidad"]:
                    try: new_conf[key] = int(val)
                    except: pass
                elif "Fecha" in key:
                    new_conf[key] = parse_date(val)
        
        state["last_conf_mtime"] = mtime
        state["config"] = new_conf
        return new_conf
        
    except Exception as e:
        log(f"[ERROR] Leyendo config: {e}")
        return default_conf

def is_active(start_date, end_date):
    """Verifica si hoy está dentro del rango"""
    if not start_date or not end_date:
        return False
    today = datetime.now().date()
    return start_date <= today <= end_date

def play_track(path):
    """Reproduce un archivo con VLC y espera a que termine"""
    if not path: return
    
    filename = os.path.basename(path)
    log(f"▶ {filename}")
    
    inst = vlc.Instance("--aout=alsa", f"--alsa-audio-device={ALSA_DEVICE}", "--intf=dummy", "--quiet")
    player = inst.media_player_new()
    media = inst.media_new(path)
    player.set_media(media)
    player.play()
    
    # Robustez: Esperar arranque
    for _ in range(50): # 5 segundos timeout arranque
        if player.get_state() == vlc.State.Playing: break
        time.sleep(0.1)
        
    # Esperar fin
    while True:
        s = player.get_state()
        if s in (vlc.State.Ended, vlc.State.Error, vlc.State.Stopped): break
        time.sleep(0.2)
        
    player.stop()
    time.sleep(0.5) # Breve pausa técnica

def get_random_norepeat(bag, source_list):
    """Saca aleatorio sin repetir hasta vaciar la bolsa"""
    if not source_list: return None
    if not bag:
        bag.extend(source_list)
        random.shuffle(bag) 
    
    valid_bag = [x for x in bag if x in source_list]
    if not valid_bag:
        bag.clear()
        bag.extend(source_list)
        if not bag: return None
    
    choice = random.choice(bag)
    bag.remove(choice)
    return choice

def get_next_alphabetical(idx, source_list):
    """Obtiene el siguiente en orden alfabético circular"""
    if not source_list: return None, 0
    clean_idx = idx % len(source_list)
    return source_list[clean_idx], clean_idx + 1

def main():
    log("--- INICIANDO LUMEN PLAYER (TXT CONFIG) ---")
    
    while True:
        conf = load_config()
        
        f_songs = get_files(DIR_CANC)
        f_ads = get_files(DIR_ANUN)
        f_temp = get_files(DIR_TEMP)
        f_nav = get_files(DIR_NAV)
        
        if not (f_songs or f_ads or f_temp or f_nav):
            log("[WAIT] Carpetas vacías. Esperando 10s...")
            time.sleep(10)
            continue

        # 1. CANCIONES NORMALES
        count = conf.get("Canciones", 1)
        for _ in range(count):
            track = get_random_norepeat(state["song_bag"], f_songs)
            if track: 
                play_track(track)
                load_config()

        # 2. ANUNCIOS (A-Z)
        count = conf.get("Anuncios", 1)
        for _ in range(count):
            track, new_idx = get_next_alphabetical(state["anuncio_idx"], f_ads)
            state["anuncio_idx"] = new_idx
            if track:
                play_track(track)
                load_config()

        # 3. TEMPORADA (A-Z, si fecha activa)
        if is_active(conf["TempFechaIni"], conf["TempFechaFin"]):
            count = conf.get("Temporada", 0)
            for _ in range(count):
                track, new_idx = get_next_alphabetical(state["temporada_idx"], f_temp)
                state["temporada_idx"] = new_idx
                if track:
                    play_track(track)
                    load_config()

        # 4. NAVIDAD (Random, si fecha activa)
        if is_active(conf["NavFechaIni"], conf["NavFechaFin"]):
            count = conf.get("Navidad", 0)
            for _ in range(count):
                track = get_random_norepeat(state["nav_bag"], f_nav)
                if track:
                    play_track(track)
                    load_config()
        
        time.sleep(0.1)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
