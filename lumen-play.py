#!/usr/bin/env python3
# /usr/local/bin/lumen-play.py
# Reproductor Lumen con salida de audio forzada a ALSA analógica (hw:0,0)
# Puedes cambiar el dispositivo con la variable de entorno LUMEN_ALSA_DEVICE (p. ej. hw:1,0 para HDMI).
import os, sys, time, random, glob, json, datetime
import vlc

LUMEN_DIR = os.path.expanduser("~/Lumen")
DIR_CANC = os.path.join(LUMEN_DIR, "Canciones")
DIR_ANUN = os.path.join(LUMEN_DIR, "Anuncios")
DIR_TEMP = os.path.join(LUMEN_DIR, "Temporada")
DIR_NAV  = os.path.join(LUMEN_DIR, "Navideña")
CONF_DIR = "/etc/lumen"
CONF_FILE = os.path.join(CONF_DIR, "player.conf")

# Dispositivo ALSA: por defecto analógico hw:0,0; permite override por env
ALSA_DEVICE = os.getenv("LUMEN_ALSA_DEVICE", "hw:0,0")

def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)

def list_mp3(folder):
    files = sorted(glob.glob(os.path.join(folder, "*.mp3")))
    return [f for f in files if os.path.isfile(f)]

def in_date_range(start_iso, end_iso, today=None):
    """start/end: 'YYYY-MM-DD' (permite wrap de año si end < start)"""
    if not start_iso or not end_iso:
        return False
    if today is None:
        today = datetime.date.today()
    s = datetime.date.fromisoformat(start_iso)
    e = datetime.date.fromisoformat(end_iso)
    if e >= s:
        return s <= today <= e
    # Rango que envuelve fin de año
    return today >= s or today <= e

def in_mmdd_range(start_mmdd, end_mmdd, today=None):
    """start/end: 'MM-DD' para navidad; permite wrap."""
    if not start_mmdd or not end_mmdd:
        return False
    if today is None:
        today = datetime.date.today()
    t = (today.month, today.day)
    sm, sd = map(int, start_mmdd.split("-"))
    em, ed = map(int, end_mmdd.split("-"))
    s = (sm, sd); e = (em, ed)
    if e >= s:
        return s <= t <= e
    return t >= s or t <= e

def load_conf():
    # Defaults compatibles con tu flujo actual
    conf = {
        "playback": {
            "songs_per_cycle": 3,      # cambia a 1 para “uno y uno”
            "pause_between_tracks_s": 1
        },
        "navidad": {"start": "12-01", "end": "01-07", "enabled": True},
        # Si define fechas, Temporada se activa automáticamente dentro del rango.
        # Además, si pones force_replace=true, usará Temporada aunque no esté en fechas.
        "temporada": {"start": "", "end": "", "force_replace": False}
    }
    try:
        if os.path.isfile(CONF_FILE):
            with open(CONF_FILE, "r") as f:
                user = json.load(f)
            # merge superficial
            for k, v in user.items():
                if isinstance(v, dict) and isinstance(conf.get(k), dict):
                    conf[k].update(v)
                else:
                    conf[k] = v
    except Exception as e:
        log(f"[WARN] No se pudo leer {CONF_FILE}: {e}")
    return conf

def play_file(path):
    log(f"▶ Reproduciendo: {os.path.basename(path)} -> {ALSA_DEVICE}")
    inst = vlc.Instance("--aout=alsa", f"--alsa-audio-device={ALSA_DEVICE}", "--intf=dummy")
    player = inst.media_player_new()
    media = inst.media_new(path)
    player.set_media(media)
    player.play()
    # Espera a que empiece
    for _ in range(100):
        state = player.get_state()
        if state in (vlc.State.Playing, vlc.State.Paused):
            break
        time.sleep(0.05)
    # Espera a que termine
    while True:
        state = player.get_state()
        if state in (vlc.State.Ended, vlc.State.Error, vlc.State.Stopped):
            break
        time.sleep(0.2)
    player.stop()
    time.sleep(0.2)

def cycle(items):
    """Generador circular sobre lista (no vacía)."""
    i = 0
    while True:
        yield items[i]
        i = (i + 1) % len(items)

def main():
    os.makedirs(CONF_DIR, exist_ok=True)
    conf = load_conf()

    # Carga catálogos
    songs = list_mp3(DIR_CANC)
    anuncios_norm = list_mp3(DIR_ANUN)
    anuncios_temp = list_mp3(DIR_TEMP)
    navidad = list_mp3(DIR_NAV)

    if not songs and not anuncios_norm and not anuncios_temp and not navidad:
        log("[WARN] No hay MP3 en Lumen/* — esperando 30s…")
        time.sleep(30)

    # Determinar fuente de “anuncios”
    temporada_cfg = conf.get("temporada", {})
    temporada_activa = in_date_range(
        temporada_cfg.get("start", ""), temporada_cfg.get("end", "")
    )
    if temporada_activa or temporada_cfg.get("force_replace", False):
        anuncio_src = anuncios_temp
        if temporada_activa:
            log("[INFO] Temporada ACTIVA: usando carpeta 'Temporada' para anuncios.")
        else:
            log("[INFO] Temporada FORZADA: usando carpeta 'Temporada' para anuncios.")
    else:
        anuncio_src = anuncios_norm

    anuncio_cycle = cycle(anuncio_src) if anuncio_src else None

    # Bolsas aleatorias (sin repetición hasta agotar)
    song_bag = songs.copy()
    nav_bag = navidad.copy()

    def take_random(bag, source):
        if not bag:
            bag.extend(source)
        if not bag:
            return None
        i = random.randrange(len(bag))
        return bag.pop(i)

    songs_per_cycle = max(1, int(conf.get("playback", {}).get("songs_per_cycle", 3)))
    pause_s = max(0, int(conf.get("playback", {}).get("pause_between_tracks_s", 1)))

    while True:
        # (1) N canciones aleatorias sin repetir según config
        for _ in range(songs_per_cycle):
            track = take_random(song_bag, songs)
            if track:
                play_file(track)
            else:
                log("[INFO] No hay canciones en Canciones/; esperando 10s")
                time.sleep(10)

        # (2) 1 anuncio en orden alfabético (si hay)
        if anuncio_cycle:
            play_file(next(anuncio_cycle))
        else:
            log("[INFO] No hay anuncios disponibles en la fuente seleccionada.")

        # (3) ¿Navidad activa? entonces 1 navideña aleatoria sin repetir
        nav_cfg = conf.get("navidad", {})
        if nav_cfg.get("enabled", True) and in_mmdd_range(
            nav_cfg.get("start", "12-01"), nav_cfg.get("end", "01-07")
        ):
            track = take_random(nav_bag, navidad)
            if track:
                play_file(track)

        # Pausa corta entre ciclos
        time.sleep(pause_s)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
