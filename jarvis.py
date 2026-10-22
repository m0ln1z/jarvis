#!/usr/bin/env python3
"""Jarvis: voice assistant for macOS that drives Claude Code in your projects.

Usage:
  jarvis.py             listen for claps (normal mode)
  jarvis.py --enter     trigger with Enter instead of claps (for testing)
  jarvis.py --levels    print mic levels (to tune clap thresholds)
  jarvis.py --say TEXT  just speak a phrase
  jarvis.py --settings  open the Settings window
  jarvis.py ctl ...     project control (same as ./jarvisctl)
"""
import asyncio
import difflib
import functools
import hashlib
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import warnings
from pathlib import Path

import numpy as np
import sounddevice as sd

warnings.filterwarnings("ignore", category=RuntimeWarning)

HERE = Path(__file__).resolve().parent
CACHE = HERE / "cache"
if not (HERE / "config.json").exists():
    (HERE / "config.json").write_text((HERE / "config.example.json").read_text(encoding="utf-8"), encoding="utf-8")
CFG = json.loads((HERE / "config.json").read_text(encoding="utf-8"))
_cfg_mtime = (HERE / "config.json").stat().st_mtime


def reload_config():
    """Picks up changes made in the Settings window without a restart."""
    global _cfg_mtime
    try:
        m = (HERE / "config.json").stat().st_mtime
        if m != _cfg_mtime:
            new = json.loads((HERE / "config.json").read_text(encoding="utf-8"))
            CFG.clear()
            CFG.update(new)
            _cfg_mtime = m
            log("Настройки обновлены")
    except Exception as e:
        log("Не смог прочитать config.json:", e)
RATE = 16000
BLOCK = 320  # 20 ms


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ---------- voice ----------

def fish_key():
    key = os.environ.get("FISH_API_KEY") or ((HERE / ".fish_key").exists() and (HERE / ".fish_key").read_text().strip())
    if not key:
        raise RuntimeError("нет ключа Fish Audio: положите его в .fish_key или FISH_API_KEY")
    return key


def fish_tts(text, raw):
    """Fish Audio voice (key in .fish_key or FISH_API_KEY)."""
    import urllib.request
    f = CFG["fish"]
    req = urllib.request.Request(
        "https://api.fish.audio/v1/tts",
        data=json.dumps({"text": text, "reference_id": f["reference_id"], "format": "mp3"}).encode(),
        headers={"Authorization": "Bearer " + fish_key(),
                 "Content-Type": "application/json", "model": f["model"]})
    with urllib.request.urlopen(req, timeout=30) as r:
        raw.write_bytes(r.read())


def edge_tts_save(text, raw):
    import edge_tts
    for attempt in range(3):
        try:
            asyncio.run(edge_tts.Communicate(text, CFG["voice"], rate=CFG["voice_rate"],
                                             pitch=CFG.get("voice_pitch", "+0Hz")).save(str(raw)))
            return
        except Exception:
            if attempt == 2:
                raise
            time.sleep(0.5)


def synth(text):
    """Returns path to cached mp3 with the phrase, or None if TTS is unavailable."""
    CACHE.mkdir(exist_ok=True)
    use_fish = CFG.get("tts") == "fish"
    voice_id = f"fish|{CFG['fish']['reference_id']}|{CFG['fish'].get('fx')}" if use_fish else \
        f"{CFG['voice']}|{CFG['voice_rate']}|{CFG.get('voice_pitch')}|{CFG['voice_fx']}"
    key = hashlib.md5(f"{voice_id}|{text}".encode()).hexdigest()
    out = CACHE / f"{key}.mp3"
    if out.exists():
        return out
    raw = CACHE / f"{key}.raw.mp3"
    fx = CFG["fish"].get("fx") if use_fish else CFG["voice_fx"]
    try:
        try:
            (fish_tts if use_fish else edge_tts_save)(text, raw)
        except Exception as e:
            if not use_fish:
                raise
            log("Fish Audio недоступен, говорю запасным голосом:", e)
            fx = CFG["voice_fx"]
            out = CACHE / f"{key}.fallback.mp3"  # don't cache the fallback as the main voice
            edge_tts_save(text, raw)
        cmd = ["ffmpeg", "-loglevel", "error", "-y", "-i", str(raw)] + (["-af", fx] if fx else []) + [str(out)]
        subprocess.run(cmd, check=True)
        raw.unlink(missing_ok=True)
    except Exception as e:
        log("TTS недоступен:", e)
        return None
    return out


SPEAKING = HERE / ".speaking"
HUD_FIFO = HERE / ".hud"
TRIGGER = HERE / ".trigger"  # menu bar 'Слушать'
PAUSED = HERE / ".paused"    # menu bar 'Пауза'
CANCEL = HERE / ".cancel"    # click on the circle / menu 'Отменить'


class Cancelled(BaseException):
    """The user pressed stop. BaseException so that generic 'except Exception' blocks don't swallow it."""


def check_cancel():
    if CANCEL.exists():
        raise Cancelled



def hud(state, text=""):
    """Shows the on-screen reactor: listening | thinking | speaking | hide. Silently does nothing without HUD."""
    try:
        fd = os.open(HUD_FIFO, os.O_WRONLY | os.O_NONBLOCK)
        try:
            os.write(fd, f"{state}\t{' '.join(text.split())[:300]}\n".encode())
        finally:
            os.close(fd)
    except OSError:
        pass


def start_hud():
    binary = HERE / "JarvisHUD"
    if not binary.exists():
        log("HUD не собран (нужен swiftc) — работаю без него")
        return
    if not HUD_FIFO.exists():
        os.mkfifo(HUD_FIFO)
    subprocess.Popen([str(binary), str(HUD_FIFO)])


def speak(text):
    """Plays the phrase; a clap during playback stops it. Returns True if interrupted."""
    out = synth(text)
    hud("speaking", text)
    SPEAKING.touch()
    try:
        p = subprocess.Popen(["afplay", str(out)] if out else ["say", "-v", "Milena", text])
        return wait_or_clap(p)
    finally:
        SPEAKING.unlink(missing_ok=True)


def wait_or_clap(proc):
    try:
        det = ClapDetector()
        det.c = dict(det.c, double=False)
        det.boost = 2.0  # our own voice is in the mic too
        with sd.InputStream(samplerate=RATE, channels=1, blocksize=BLOCK, dtype="float32") as st:
            t = 0.0
            while proc.poll() is None:
                b, _ = st.read(BLOCK)
                t += BLOCK / RATE
                if CANCEL.exists():
                    proc.kill()
                    raise Cancelled
                if t > 0.3 and det.feed(b[:, 0], t):
                    proc.kill()
                    log("Перебили хлопком")
                    return True
    except Exception:
        proc.wait()
    return False


# ---------- projects ----------

TR = dict(zip("абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
              ["a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "i", "k", "l", "m", "n", "o", "p", "r", "s", "t",
               "u", "f", "h", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya"]))


def norm(s):
    s = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", s)
    s = "".join(TR.get(c, c) for c in s.lower())
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def projects():
    found = {}
    for root in CFG["projects_roots"]:
        root = Path(os.path.expanduser(root))
        for p in sorted(root.iterdir()):
            if p.is_dir() and not p.name.startswith(".") and p.name not in CFG["exclude"]:
                found[p.name] = p
    return found


PHON = [("ph", "f"), ("ck", "k"), ("ce", "se"), ("ci", "si"), ("c", "k"), ("q", "k"), ("w", "v"), ("x", "ks"), ("y", "i"), ("z", "s"),
        ("ee", "i"), ("ea", "i"), ("oo", "u"), ("ow", "au")]


def phon(w):
    """Rough 'how it sounds' form, so 'sales' ~ 'сейлз', 'office' ~ 'офис'."""
    for a, b in PHON:
        w = w.replace(a, b)
    return re.sub(r"(.)\1+", r"\1", w)


def word_sim(a, b):
    sim = difflib.SequenceMatcher(None, a, b).ratio()
    pa, pb = phon(a), phon(b)
    sim = max(sim, difflib.SequenceMatcher(None, pa, pb).ratio())
    ca, cb = re.sub("[aeiou]", "", pa), re.sub("[aeiou]", "", pb)  # consonant skeleton
    if min(len(ca), len(cb)) >= 3:
        sim = max(sim, 0.95 * difflib.SequenceMatcher(None, ca, cb).ratio())
    elif ca and ca == cb:  # short words: 'бэк' ~ 'back' only if consonants are identical
        sim = max(sim, 0.9)
    return sim


GENERIC = {"proekt", "proekta", "proekte", "project", "projects"}


@functools.lru_cache(maxsize=200000)
def word_sim_cached(a, b):
    return word_sim(a, b)


def match_key(text, projs):
    """Picks the project whose name/alias words best match the spoken words.
    Key: matched words minus a penalty for unmatched ones, then share covered, then raw similarity."""
    words = [w for w in norm(text).split() if w not in GENERIC]
    words += [a + b for a, b in zip(words, words[1:])]  # 'пиксель паудер' ~ 'pxlpowder'
    best, best_key = None, (0, 0.0, 0.0)
    for name in projs:
        for cand in [name] + CFG["aliases"].get(name, []):
            cw = [w for w in norm(cand).split() if w not in GENERIC] or norm(cand).split()
            sims = [max((word_sim_cached(w, t) for t in words), default=0) for w in cw]
            hits = [x for x, w in zip(sims, cw) if x >= (0.9 if len(w) <= 3 else 0.75)]
            key = (sum(hits) - 0.5 * (len(cw) - len(hits)), sum(hits) / len(cw), sum(sims))
            if key > best_key:
                best, best_key = name, key
    return (best, best_key) if best_key[0] > 0 else (None, (0, 0.0, 0.0))


def match(text, projs):
    name, key = match_key(text, projs)
    return name, key[1]


def spoken_name(name):
    a = CFG["aliases"].get(name)
    if a:
        return a[0]
    words = re.split(r"[-_ ]+", name)
    return " ".join(w for w in words if not (len(w) > 10 and re.search(r"\d", w)))  # drop hashes


# ---------- Claude sessions (each project runs Claude inside tmux, so Jarvis can press keys) ----------

STATE = HERE / "state.json"


def tmux(*args, **kw):
    return subprocess.run(["tmux", "-L", "jarvis", "-f", str(HERE / "tmux.conf"), *args],
                          capture_output=True, text=True, **kw)


def session_name(project):
    return re.sub(r"[^A-Za-z0-9_-]", "_", project)


def alive(project):
    return tmux("has-session", "-t", session_name(project)).returncode == 0


def load_state():
    try:
        return json.loads(STATE.read_text())
    except Exception:
        return {"current": None, "windows": {}}


def save_state(st):
    STATE.write_text(json.dumps(st, ensure_ascii=False))


def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout.strip()


def open_project(project, path, task=None):
    """Opens (or brings to front) the Claude window of the project; sends the task if any."""
    st = load_state()
    st["current"] = project
    if alive(project):
        win = st["windows"].get(project)
        if win and osa(f'tell application "Terminal" to exists window id {win}') == "true":
            osa(f'tell application "Terminal"\n set index of window id {win} to 1\n activate\nend tell')
        else:  # window was closed but Claude still runs: attach a new window
            st["windows"][project] = new_window(f"tmux -L jarvis -f {sh_quote(str(HERE / 'tmux.conf'))} "
                                                f"attach -t {session_name(project)}")
        save_state(st)
        if task:
            send_task(project, task)
        return
    trust(path)
    cmd = (f"cd {sh_quote(str(path))} && tmux -L jarvis -f {sh_quote(str(HERE / 'tmux.conf'))} "
           f"new-session -s {session_name(project)} "
           f"{CFG['launch_command'].format(settings=sh_quote(str(claude_settings())))}")
    if task:
        cmd += " " + sh_quote(task)
    st["windows"][project] = new_window(cmd)
    save_state(st)


def claude_settings():
    """Settings for Claude sessions started by Jarvis: the hook that reads answers aloud."""
    path = HERE / "claude-settings.json"
    hook = f"{sh_quote(sys.executable)} {sh_quote(str(HERE / 'on_stop.py'))}"
    path.write_text(json.dumps({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": hook}]}]}}, indent=2))
    return path


def trust(path):
    """Marks the folder as trusted in Claude Code, so it doesn't ask 'Do you trust this folder?'."""
    cfg = Path.home() / ".claude.json"
    try:
        d = json.loads(cfg.read_text())
        p = d.setdefault("projects", {}).setdefault(str(Path(path).resolve()), {})
        if p.get("hasTrustDialogAccepted"):
            return
        p["hasTrustDialogAccepted"] = True
        tmp = cfg.with_suffix(".jarvis-tmp")
        tmp.write_text(json.dumps(d, indent=2, ensure_ascii=False))
        tmp.replace(cfg)
    except Exception as e:
        log("Не смог отметить папку доверенной:", e)


def new_window(cmd):
    esc = cmd.replace("\\", "\\\\").replace('"', '\\"')
    return osa(f'tell application "Terminal"\n activate\n do script "{esc}"\n return id of front window\nend tell')


def wait_ready(project, timeout=25):
    """Waits until Claude in the project shows its input prompt (it needs a few seconds to start)."""
    end = time.time() + timeout
    while time.time() < end:
        screen = tmux("capture-pane", "-p", "-t", session_name(project)).stdout
        if "bypass permissions" in screen or re.search(r"^\s*❯\s*$", screen, re.M):
            return True
        time.sleep(0.5)
    return False


def interrupt(project):
    tmux("send-keys", "-t", session_name(project), "Escape")


def send_task(project, task):
    """Stops whatever Claude is doing in the project and gives it the new task."""
    s = session_name(project)
    interrupt(project)
    time.sleep(0.4)
    tmux("send-keys", "-t", s, "-l", task)
    time.sleep(0.1)
    tmux("send-keys", "-t", s, "Enter")


def sh_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


# ---------- jarvisctl: the brain drives projects through these commands ----------

def resolve(name):
    projs = projects()
    if name in projs:
        return name
    if name in ("current", "текущий"):
        return load_state().get("current")
    found, _ = match(name, projs)
    return found


def ctl(args):
    cmd, rest = (args[0], args[1:]) if args else ("help", [])
    projs = projects()
    if cmd == "projects":
        print("\n".join(projs))
    elif cmd == "sessions":
        st = load_state()
        live = [p for p in projs if alive(p)]
        print("открыты:", ", ".join(live) or "нет", "| текущий:", st.get("current") if st.get("current") in live else "нет")
    elif cmd in ("open", "send", "stop", "status", "close"):
        if not rest:
            sys.exit("укажи проект")
        p = resolve(rest[0])
        if not p:
            sys.exit(f"проект «{rest[0]}» не найден")
        task = " ".join(rest[1:]).strip() or None
        if cmd == "open":
            open_project(p, projs[p], task)
            print(f"открыт {p}" + (f", задача отправлена" if task else ""))
        elif not alive(p):
            print(f"{p} не открыт")
        elif cmd == "send":
            send_task(p, task or "")
            st = load_state()
            st["current"] = p
            save_state(st)
            print(f"задача отправлена в {p}")
        elif cmd == "stop":
            interrupt(p)
            print(f"{p}: остановлено")
        elif cmd == "status":
            lines = [l for l in tmux("capture-pane", "-p", "-t", session_name(p), "-S", "-80").stdout.splitlines() if l.strip()]
            busy = any("esc to interrupt" in l for l in lines[-6:])
            print(("РАБОТАЕТ сейчас" if busy else "ЖДЁТ задачу") + "\n" + "\n".join(lines[-60:]))
        elif cmd == "close":
            tmux("kill-session", "-t", session_name(p))
            print(f"{p} закрыт")
    else:
        print("projects | sessions | open P [задача] | send P задача | stop P | status P | close P")


# ---------- brain: anything that is not a plain 'project + task' goes to Claude ----------

BRAIN_PROMPT = """Ты — Джарвис, голосовой ассистент владельца этого Mac (macOS). С тобой говорят голосом \
(распознавание речи может искажать слова), твой ответ будет озвучен. Отвечай по-русски, коротко — \
одно-два предложения, без markdown, списков, кода, путей и ссылок. Обращайся «сэр», можно с лёгкой иронией.

Проекты владельца лежат в {roots}. В каждом открытом проекте работает свой Claude Code — «программист». \
Управляй ими ТОЛЬКО через {ctl}:
  {ctl} projects                  — все проекты
  {ctl} sessions                  — какие открыты и какой текущий
  {ctl} open <проект> [задача]    — открыть проект (и дать задачу программисту)
  {ctl} send <проект> <задача>    — прервать его текущую работу и дать новую задачу
  {ctl} stop <проект>             — остановить работу
  {ctl} status <проект>           — экран программиста: работает ли он и что ответил
  {ctl} close <проект>            — закрыть проект
Код в проектах сам не читай и не правь — любую работу с кодом передавай программисту, формулируя задачу \
полно и точно, как её сказал владелец. Если проект не назван, речь о текущем.

Компьютером управляй через bash и osascript: приложения, сайты, поиск в браузере, громкость, музыка, \
время, батарея и т.п. Действуй сразу, без лишних вопросов.
Перед необратимым (удаление файлов, git push, отправка сообщений, покупки, закрытие несохранённого) — \
не делай, а спроси подтверждение одной фразой; владелец ответит следующей репликой.

Проекты: {projects}
Сейчас: {sessions}"""


def think(text):
    """Asks the brain; returns the phrase to say. Keeps one conversation per wake-up."""
    import io, contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        ctl(["sessions"])
    st = load_state()
    prompt = BRAIN_PROMPT.format(ctl=HERE / "jarvisctl", roots=", ".join(CFG["projects_roots"]), projects=", ".join(projects()), sessions=buf.getvalue().strip())
    cmd = ["claude", "-p", "--model", CFG.get("brain_model", "haiku"), "--dangerously-skip-permissions",
           "--output-format", "json", "--append-system-prompt", prompt]
    if st.get("brain_session") and time.time() - st.get("brain_at", 0) < CFG.get("awake_minutes", 15) * 60:
        cmd += ["--resume", st["brain_session"]]
    (HERE / "brain").mkdir(exist_ok=True)
    try:
        p = subprocess.Popen(cmd + [text], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                             cwd=str(HERE / "brain"), stdin=subprocess.DEVNULL)
        end = time.time() + 120
        while p.poll() is None:
            if CANCEL.exists() or time.time() > end:
                p.kill()
                check_cancel()
                raise TimeoutError("мозг думал больше 2 минут")
            time.sleep(0.2)
        d = json.loads(p.stdout.read())
    except Exception as e:
        log("Мозг не ответил:", e)
        return "Простите, сэр, что-то пошло не так."
    st = load_state()
    st["brain_session"], st["brain_at"] = d.get("session_id"), time.time()
    save_state(st)
    return (d.get("result") or "").strip() or "Готово, сэр."


# ---------- listening ----------

_whisper = None


def whisper():
    global _whisper
    if _whisper is None:
        from faster_whisper import WhisperModel
        log("Загружаю модель распознавания…")
        _whisper = WhisperModel(CFG["whisper_model"], device="cpu", compute_type="int8")
    return _whisper


def record_phrase(max_wait=5.0, max_len=7.0, silence=0.9):
    """Records until the speaker goes quiet. Returns float32 audio or None."""
    hud("listening")
    frames, started, quiet_since = [], False, None
    noise = []
    t0 = time.time()
    with sd.InputStream(samplerate=RATE, channels=1, blocksize=BLOCK, dtype="float32") as st:
        while True:
            b, _ = st.read(BLOCK)
            b = b[:, 0]
            check_cancel()
            rms = float(np.sqrt(np.mean(b ** 2)))
            now = time.time() - t0
            if len(noise) < 15:  # first 300 ms -> background level
                noise.append(rms)
                continue
            thr = max(0.012, np.median(noise) * 3)
            if not started:
                frames = (frames + [b])[-15:]  # keep a bit of pre-roll
                if rms > thr:
                    started, quiet_since = True, None
                elif now > max_wait:
                    return None
                continue
            frames.append(b)
            if rms < thr:
                quiet_since = quiet_since or now
                if now - quiet_since > silence:
                    break
            else:
                quiet_since = None
            if len(frames) * BLOCK / RATE > max_len:
                break
    return np.concatenate(frames)


def transcribe(audio, projs):
    hint = (" ".join(wake_words()).capitalize() + ". Проекты: "
            + ", ".join(list(projs) + [a for v in CFG["aliases"].values() for a in v])) if projs else None
    hud("thinking")
    segs, _ = whisper().transcribe(audio, language="ru", initial_prompt=hint, beam_size=1, vad_filter=True)
    text = " ".join(s.text for s in segs).strip()
    if re.search(HALLUCINATIONS, text, re.I):
        log(f"Отброшено (глюк распознавания): «{text}»")
        return ""
    return text


# what Whisper "hears" in silence or noise
HALLUCINATIONS = r"субтитр|редактор|корректор|продолжение следует|спасибо за просмотр|подписывайтесь|dimatorzok|amara\.org"


OPEN_WORDS = r"открой|откро|открыл|открыть|\bсрой|\bкрой|\bотрой|запусти|перейди|переключи|проект|нужно|надо|хочу|слушай|давай|братан|джарвис"
SHUT_UP = r"^\W*(замолчи|тихо|молчи|помолчи|хватит говорить|заткнись)\W*"
STOP = r"^\W*(стоп|отмени|отмена|останови|остановись|прекрати)\W*$"
SLEEP = (r"^\W*(?:(?:ну|всё|ничего|джарвис|ладно)\W+)*(выключись|выключайся|отключись|отключайся|выключи(?:ть)?|"
         r"отключи(?:ть)?|спи|спать|иди спать|отбой|свободен|пока|ничего|всё|хватит|достаточно|спасибо)"
         r"(?:\W+(?:сэр|джарвис|спасибо))*\W*$")  # the whole phrase, so 'выключи музыку' still goes to the brain
JUST_OPEN = r"ничего|не надо|просто откр|пока нет|^\W*(нет|просто)\W*$"


def split_command(text, projs):
    """Finds the project anywhere in the phrase: the words after it are the task.
    'так, слушай, открой мне шоп бэкенд и добавь тёмную тему' -> ('ShopBackend', 'добавь тёмную тему')."""
    words = text.split()
    best, best_key, span = None, (0.74, 0, 0), None  # need at least one solid word
    for i in range(len(words)):
        for k in range(1, 5):
            if i + k > len(words):
                break
            name, key = match_key(" ".join(words[i:i + k]), projs)
            if name and key > best_key:  # strict '>' keeps the shortest/earliest span on ties
                best, best_key, span = name, key, (i, i + k)
    if not best:
        return None, text
    after = " ".join(words[span[1]:])
    after = re.sub(r"^[\s,.:;!-]*((и|там|а|чтобы|потом)\s+)*", "", after).strip(" .,!")
    before = " ".join(words[:span[0]]).strip(" .,!")
    after = re.sub(r"\b(пожалуйста|плиз|please|спасибо|сэр|джарвис)\b", "", after, flags=re.I).strip(" ,.!?")
    if norm(after) in GENERIC:
        after = ""
    if not after and len(before.split()) >= 3 and not re.search(OPEN_WORDS, before.lower()):
        after = before  # 'добавь тёмную тему в шоп бэкенд'
    return best, after


def stop_speaking():
    subprocess.run(["pkill", "-f", f"afplay {CACHE}"], capture_output=True)


def speak_bg(text):
    subprocess.Popen([sys.executable, __file__, "--say", text],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def wake_words():
    return CFG.get("wake_words") or ["просыпайся", "папочка", "вернулся"]
awake_until = 0.0


def strip_wake(text):
    """'Просыпайся, папочка вернулся, открой шоп' -> (True, 'открой шоп').
    Needs at least 2 of the wake words (all of them if there are fewer), in any wording close enough."""
    words = text.split()
    found, last = 0, -1
    wake = wake_words()
    for w in wake:
        for i, t in enumerate(words[:8]):
            if word_sim(norm(w), norm(t)) >= 0.7:
                found, last = found + 1, max(last, i)
                break
    if found < min(2, len(wake)):
        return False, text
    return True, " ".join(words[last + 1:]).strip(" ,.!")


def go_to_sleep():
    global awake_until
    awake_until = 0.0
    log("Ухожу спать")


def on_clap(force=False):
    """Asleep: silently waits for the wake phrase. Awake (or 'Слушать' in the menu): takes a command right away."""
    global awake_until
    if force or time.time() < awake_until:
        awake_until = time.time() + CFG.get("awake_minutes", 15) * 60
        return handle_command()
    audio = record_phrase(max_wait=4.0, max_len=20.0, silence=0.8)
    if audio is None:
        return
    text = transcribe(audio, projects())
    ok, rest = strip_wake(text)
    log(f"Пароль: «{text}» -> {'да' if ok else 'нет'}")
    if not ok:
        return
    awake_until = time.time() + CFG.get("awake_minutes", 15) * 60
    if rest and not re.fullmatch(r"\W*(джарвис|сэр)?\W*", rest.lower()):
        return handle_command(rest)
    speak(CFG["phrases"]["wake"])
    handle_command(greet=False)


def handle_command(text=None, greet=True):
    projs = projects()
    st = load_state()
    current = st.get("current") if st.get("current") and alive(st["current"]) else None
    if text is None and greet:
        speak(CFG["phrases"]["listening"])
    for attempt in range(10):  # a short conversation: up to 10 exchanges
        if text is None:
            audio = record_phrase(max_wait=5.0, max_len=25.0, silence=0.8)
            if audio is None:
                return
            text = transcribe(audio, projs)
        log(f"Услышал: «{text}»")
        t = text.lower().strip()
        if re.match(SHUT_UP, t):  # 'замолчи' — speech is already stopped; maybe a new task follows
            text = re.sub(SHUT_UP, "", text, flags=re.I).strip(" ,.!")
            t = text.lower()
            if not text:
                return
        if re.match(SLEEP, t):
            go_to_sleep()
            speak_bg(CFG["phrases"].get("sleep", "Как скажете, сэр."))
            return
        if re.match(STOP, t):
            if current:
                interrupt(current)
                speak_bg(CFG["phrases"]["stopped"])
            return
        name, task = split_command(text, projs)
        if task and len(task.split()) <= 6 and re.search(JUST_OPEN, task.lower()):
            task = ""
        if name and (not task or re.search(OPEN_WORDS, text.lower())):  # plain 'open X [and do Y]' — fast path
            log(f"Проект: {name}, задача: «{task}»")
            speak_bg(CFG["phrases"]["task" if task else "opening"].format(name=spoken_name(name)))
            open_project(name, projs[name], task or None)
            if task:
                return
            audio = record_phrase(max_wait=8.0, max_len=25.0, silence=0.9)  # 'Открываю X.' -> the task
            follow = transcribe(audio, projs) if audio is not None else ""
            log(f"Задача для {name}: «{follow}»")
            if follow and not re.search(JUST_OPEN, follow.lower()) and len(re.findall(r"\w+", follow)) >= 2:
                wait_ready(name)
                send_task(name, follow)
                speak_bg(CFG["phrases"]["task"])
            return
        if len(re.findall(r"\w+", text)) < 2 and attempt == 0:
            speak(CFG["phrases"]["repeat"])
            text = None
            continue
        subprocess.Popen(["afplay", "/System/Library/Sounds/Tink.aiff"])  # 'thinking…'
        hud("thinking", f"«{text}»")
        answer = think(text)
        log(f"Джарвис: «{answer}»")
        if speak(answer):
            text = None  # interrupted by a clap -> listen right away
            continue
        # follow-up without a clap; a question from Jarvis gets more time to answer
        audio = record_phrase(max_wait=10.0 if answer.rstrip().endswith("?") else 6.0, max_len=25.0, silence=0.9)
        if audio is None:
            return
        text = transcribe(audio, projs)
        if not text.strip():
            return
    return


# ---------- Claude's questions (menus) answered by voice ----------

dialogs = queue.Queue()
NUMS = {"один": 1, "первый": 1, "первое": 1, "два": 2, "второй": 2, "второе": 2, "три": 3, "третий": 3,
        "третье": 3, "четыре": 4, "четвёртый": 4, "четвертый": 4, "пять": 5, "пятый": 5}
YES = r"\b(да|давай|ага|конечно|разрешаю|доверяю|согласен|yes|ок|окей)\b"
NO = r"\b(нет|не надо|отказ|no|отмена)\b"


def parse_menu(screen):
    """Finds a Claude selection menu on the screen: (question, options, selected index) or None."""
    lines = screen.splitlines()
    end = next((i for i in range(len(lines) - 1, -1, -1)
                if re.search(r"Enter to (confirm|select)|Esc to cancel", lines[i])), None)
    if end is None:
        return None
    numbered = [i for i in range(end) if re.match(r"^\s*(❯\s*)?\d+\.\s+\S", lines[i])]
    if numbered:
        idx = numbered
    else:
        idx = [i for i in range(end) if re.match(r"^\s?(❯ |   )\S", lines[i])]
    if not idx:
        return None
    # keep only the last contiguous group of options
    group = [idx[-1]]
    for i in reversed(idx[:-1]):
        if group[0] - i <= 3:
            group.insert(0, i)
        else:
            break
    options = [re.sub(r"^\s*(❯\s*)?(\d+\.\s+)?", "", lines[i]).strip() for i in group]
    selected = next((k for k, i in enumerate(group) if "❯" in lines[i]), 0)
    top = next((i for i in range(group[0] - 1, -1, -1) if re.match(r"^\s*[─━]{5,}", lines[i])), -1)
    question = " ".join(l.strip() for l in lines[top + 1:group[0]] if l.strip() and not l.strip().startswith("/"))
    return question[:250].rsplit(" ", 1)[0] if len(question) > 250 else question, options, selected


def watch_dialogs():
    """Background thread: looks at Claude windows and queues any new question for the voice."""
    seen = {}
    while True:
        out = tmux("list-sessions", "-F", "#{session_name}").stdout.split()
        for s in out:
            screen = tmux("capture-pane", "-p", "-t", s).stdout
            menu = parse_menu(screen)
            sig = json.dumps(menu, ensure_ascii=False) if menu else None
            if menu and seen.get(s) != sig:
                dialogs.put((s, menu))
            seen[s] = sig
        time.sleep(1.0)


def choose(answer, options):
    a = answer.lower()
    for w, n in NUMS.items():
        if re.search(rf"\b{w}\b", a) and n <= len(options):
            return n - 1
    m = re.search(r"\d+", a)
    if m and 1 <= int(m.group()) <= len(options):
        return int(m.group()) - 1
    words = norm(a).split()
    def score(ow):
        sims = [max((word_sim(w, t) for t in words), default=0) for w in ow]
        return max(sum(sims) / len(sims), 0.9 * max(s for s, w in zip(sims, ow) if len(w) >= 4) if any(len(w) >= 4 for w in ow) else 0)

    scores = sorted(((score(norm(o).split()[:4] or ["-"]), k) for k, o in enumerate(options)), reverse=True)
    if scores and scores[0][0] >= 0.75 and (len(scores) == 1 or scores[1][0] < scores[0][0] - 0.15):
        return scores[0][1]  # named the option itself
    if re.search(YES, a):
        return next((k for k, o in enumerate(options) if re.search(r"yes|да|allow|trust|confirm|continue|proceed", o, re.I)), 0)
    if re.search(NO, a):
        return next((k for k, o in enumerate(options) if re.search(r"\bno\b|нет|exit|cancel|deny|reject", o, re.I)), None)
    return None


SERVICE_OPTIONS = r"^(Type something|Chat about this|Other)\b"


def retell(question, options):
    """Short Russian phrase for the voice: the question and its numbered options."""
    shown = [(k, o) for k, o in enumerate(options) if not re.match(SERVICE_OPTIONS, o)]
    raw = question + "\n" + "\n".join(f"{k + 1}. {o}" for k, o in shown)
    prompt = ("Перескажи по-русски для озвучки голосом, максимум 30 слов, без markdown. "
              "Формат: короткий вопрос, затем 'Первый — …, второй — …' с теми же номерами. "
              "Технические названия оставь как есть. Только текст пересказа.\n\n" + raw)
    try:
        r = subprocess.run(["claude", "-p", "--model", "haiku", "--no-session-persistence", prompt],
                           capture_output=True, text=True, timeout=25, cwd=str(HERE), stdin=subprocess.DEVNULL)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except Exception as e:
        log("Пересказ не удался:", e)
    return raw.replace("\n", ". ")


def handle_dialog(session, menu):
    question, options, selected = menu
    if session.startswith("jt"):  # test sessions
        return
    speak_bg("Сэр, у Claude вопрос.")
    if speak(retell(question, options)):
        speak("Слушаю.")
    for attempt in range(2):
        audio = record_phrase(max_wait=6.0, max_len=10.0, silence=0.8)
        if audio is None:
            break
        answer = transcribe(audio, {})
        log(f"Ответ на вопрос: «{answer}»")
        k = choose(answer, options)
        if k is not None:
            moves = k - selected
            for _ in range(abs(moves)):
                tmux("send-keys", "-t", session, "Down" if moves > 0 else "Up")
                time.sleep(0.05)
            tmux("send-keys", "-t", session, "Enter")
            speak_bg(f"Выбрал: {options[k]}.")
            return
        speak("Не понял, сэр. Скажите номер варианта.")
    speak_bg("Оставляю вопрос открытым, сэр. Хлопните, когда будете готовы.")


class ClapDetector:
    """Clap = sudden loud burst that is short (unlike speech/music)."""

    def __init__(self):
        c = CFG["clap"]
        self.c = c
        self.noise = 0.01
        self.loud_since = None
        self.peak = 0.0
        self.claps = []
        self.boost = 1.0

    def feed(self, b, now):
        c = self.c
        peak = float(np.max(np.abs(b)))
        rms = float(np.sqrt(np.mean(b ** 2)))
        thr = max(c["min_level"], self.noise * c["noise_ratio"]) * self.boost
        if self.loud_since is None:
            if peak > thr:
                spec = np.abs(np.fft.rfft(b)) ** 2
                self.hf = float(spec[len(spec) // 4:].sum() / (spec.sum() + 1e-9))  # share above 2 kHz
                self.loud_since, self.peak = now, peak
            else:
                self.noise = 0.995 * self.noise + 0.005 * rms
            return False
        self.peak = max(self.peak, peak)
        if peak > self.peak * 0.3 and now - self.loud_since <= c["max_clap_sec"] + 0.2:
            return False  # still loud
        dur = now - self.loud_since
        self.loud_since = None
        ok = dur <= c["max_clap_sec"] and self.hf >= c.get("min_hf_ratio", 0)
        log(f"звук: пик {self.peak:.1f}, {dur * 1000:.0f} мс, ВЧ {self.hf:.2f} -> {'хлопок' if ok else 'не хлопок'}")
        if not ok:
            self.claps.clear()  # long or dull sound (speech, knock on the table)
            return False
        if self.claps and not (0.2 < self.peak / self.claps[-1][1] < 5):
            self.claps.clear()  # two claps should be about equally loud
        self.claps = [(t, p) for t, p in self.claps if now - t <= c["gap_max_sec"]] + [(now, self.peak)]
        if not c["double"]:
            self.claps.clear()
            return True
        if len(self.claps) >= 2 and now - self.claps[-2][0] >= c["gap_min_sec"]:
            self.claps.clear()
            return True
        return False


def listen_claps():
    q = queue.Queue()

    def cb(indata, frames, t, status):
        q.put(indata[:, 0].copy())

    start_hud()
    threading.Thread(target=watch_dialogs, daemon=True).start()
    while True:
        det = ClapDetector()
        dialog, triggered, clapped = None, False, False
        if PAUSED.exists():  # paused: microphone closed (the orange mic icon goes away) until resumed or 'Слушать'
            log("Пауза: микрофон выключен")
            while PAUSED.exists() and not TRIGGER.exists():
                reload_config()
                if CANCEL.exists():
                    CANCEL.unlink(missing_ok=True)
                    stop_speaking()
                    hud("hide")
                time.sleep(0.3)
            if TRIGGER.exists():
                TRIGGER.unlink(missing_ok=True)
                triggered = True
        if not triggered:
            log("Жду хлопок…")
        with sd.InputStream(samplerate=RATE, channels=1, blocksize=BLOCK, dtype="float32", callback=cb):
            start = time.time()
            n = 0
            while not triggered:
                b = q.get()
                n += 1
                if n < 50:  # first second: learn background noise only
                    det.noise = 0.9 * det.noise + 0.1 * float(np.sqrt(np.mean(b ** 2)))
                    if n == 49 and det.noise == 0:
                        log("ВНИМАНИЕ: микрофон молчит — нет доступа к микрофону?")
                    continue
                if n % 50 == 0:
                    reload_config()
                if n % 10 == 0 and CANCEL.exists():  # stop pressed while idle: silence any read-out
                    CANCEL.unlink(missing_ok=True)
                    stop_speaking()
                    hud("hide")
                if n % 10 == 0 and TRIGGER.exists():  # 'Слушать' in the menu bar = clap + password
                    TRIGGER.unlink(missing_ok=True)
                    triggered = True
                    break
                if PAUSED.exists():
                    break  # close the microphone
                det.boost = 2.0 if SPEAKING.exists() else 1.0  # our own voice from the speakers
                if det.feed(b, start + n * BLOCK / RATE):
                    clapped = True
                    break
                if not dialogs.empty():
                    dialog = dialogs.get()
                    break
        while not q.empty():
            q.get()
        if not (dialog or triggered or clapped):
            continue  # left the loop only to pause
        if dialog:
            log("Вопрос от Claude:", dialog)
            stop_speaking()
            try:
                handle_dialog(*dialog)
            except Exception as e:
                log("Ошибка:", e)
            except Cancelled:
                log("Остановлено кнопкой")
                CANCEL.unlink(missing_ok=True)
                stop_speaking()
                go_to_sleep()
            finally:
                hud("hide")
            continue
        log("Слушаю по кнопке в меню" if triggered else "Хлопок!")
        stop_speaking()
        try:
            on_clap(force=triggered)
        except Exception as e:
            log("Ошибка:", e)
        except Cancelled:
            log("Остановлено кнопкой")
            CANCEL.unlink(missing_ok=True)
            stop_speaking()
            go_to_sleep()
        finally:
            hud("hide")


def show_levels():
    def cb(indata, frames, t, status):
        b = indata[:, 0]
        peak = float(np.max(np.abs(b)))
        print(f"\rпик {peak:5.2f} " + "#" * min(60, int(peak * 10)) + " " * 60, end="", flush=True)

    with sd.InputStream(samplerate=RATE, channels=1, blocksize=BLOCK * 5, dtype="float32", callback=cb):
        input("Говори/хлопай, Enter — выход\n")


def main():
    args = sys.argv[1:]
    if args[:1] == ["--say"]:
        try:
            speak(" ".join(args[1:]))
        except Cancelled:
            pass
        hud("hide")
        return
    if args[:1] == ["--settings"]:
        hud("settings")
        return
    if args[:1] == ["ctl"]:
        ctl(args[1:])
        return
    if args[:1] == ["--levels"]:
        show_levels()
        return
    whisper()  # load model up front so the first answer is fast
    for p in CFG["phrases"].values():  # pre-cache phrases
        if "{" not in p:
            synth(p)
    speak(CFG["phrases"]["ready"])
    if args[:1] == ["--enter"]:
        while True:
            input("Enter — запуск диалога")
            handle_command()
    listen_claps()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
