#!/usr/bin/env python3
"""
Curator Studio — Mac side daemon.

Watches for download requests (Telegram, the iPhone app, a Shortcut, or the
command line), runs yt-dlp with iPhone-safe settings, and serves finished files
to the app over your local Wi-Fi.

Nothing leaves your machine except the yt-dlp traffic itself and, if you enable
it, Telegram polling.

Run it in the foreground while you're setting things up:

    python3 curator_daemon.py --foreground

Once it behaves, install.sh registers it as a launchd agent so it starts with
your Mac and restarts if it ever dies.
"""

import argparse
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API_VERSION = 1

HOME = os.path.expanduser("~")
CONFIG_DIR = os.path.join(HOME, ".curator-studio")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")
STATE_PATH = os.path.join(CONFIG_DIR, "state.json")
LOG_PATH = os.path.join(CONFIG_DIR, "daemon.log")

VIDEO_EXTS = {".mp4", ".m4v", ".mov", ".mpg", ".mpeg", ".3gp"}
AUDIO_EXTS = {".mp3", ".m4a", ".m4b", ".aac", ".wav", ".aif", ".aiff", ".caf", ".flac"}
MEDIA_EXTS = VIDEO_EXTS | AUDIO_EXTS

# ---------------------------------------------------------------------------
# Quality tiers
# ---------------------------------------------------------------------------

# Prefer H.264 video + AAC audio so the file is playable on iOS with no
# re-encoding. The later fallbacks accept anything; ensure_compatible() then
# transcodes if YouTube only offered VP9/AV1/Opus.
QUALITY_FORMATS = {
    "best": "bv*[vcodec^=avc1][height<=2160]+ba[acodec^=mp4a]/bv*[height<=2160]+ba/b[height<=2160]/b",
    "high": "bv*[vcodec^=avc1][height<=1080]+ba[acodec^=mp4a]/bv*[height<=1080]+ba/b[height<=1080]/b",
    "mid":  "bv*[vcodec^=avc1][height<=720]+ba[acodec^=mp4a]/bv*[height<=720]+ba/b[height<=720]/b",
    "low":  "bv*[vcodec^=avc1][height<=480]+ba[acodec^=mp4a]/bv*[height<=480]+ba/b[height<=480]/b",
    "audio": "ba[ext=m4a]/ba/b",
}

QUALITY_ALIASES = {
    "best": "best", "max": "best", "4k": "best", "2160": "best", "highest": "best",
    "high": "high", "hd": "high", "1080": "high", "1080p": "high", "full": "high",
    "mid": "mid", "medium": "mid", "720": "mid", "720p": "mid", "normal": "mid",
    "low": "low", "small": "low", "480": "low", "480p": "low", "data": "low",
    "audio": "audio", "sound": "audio", "music": "audio", "mp3": "audio",
    "m4a": "audio", "podcast": "audio", "listen": "audio",
}

DEFAULT_CONFIG = {
    "library_root": os.path.join(HOME, "CuratorStudio"),
    "port": 8787,
    "token": "",
    "device_name": socket.gethostname().replace(".local", "") + "'s Mac",
    "default_quality": "mid",
    "default_folder": "Randoms",
    "force_compatible": True,
    "embed_metadata": True,
    "sponsorblock": True,
    "sponsorblock_categories": "sponsor,selfpromo,interaction",
    "write_sidecar": True,
    "max_concurrent_jobs": 2,
    "advertise_bonjour": True,
    "telegram": {
        "bot_token": "",
        "allowed_chat_ids": [],
        "learn_first_chat": True,
    },
}


def log(*parts):
    line = time.strftime("[%Y-%m-%d %H:%M:%S] ") + " ".join(str(p) for p in parts)
    print(line, flush=True)


# ---------------------------------------------------------------------------
# Config & state
# ---------------------------------------------------------------------------

def load_config():
    os.makedirs(CONFIG_DIR, exist_ok=True)
    config = json.loads(json.dumps(DEFAULT_CONFIG))
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH) as handle:
                stored = json.load(handle)
            for key, value in stored.items():
                if isinstance(value, dict) and isinstance(config.get(key), dict):
                    config[key].update(value)
                else:
                    config[key] = value
        except Exception as exc:
            log("config unreadable, using defaults:", exc)
    if not config.get("token"):
        config["token"] = uuid.uuid4().hex[:20]
        save_config(config)
    config["library_root"] = os.path.expanduser(config["library_root"])
    os.makedirs(config["library_root"], exist_ok=True)
    return config


def save_config(config):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(config, handle, indent=2)
    os.replace(tmp, CONFIG_PATH)


class Store:
    """Job list, persisted to disk, guarded by a lock."""

    def __init__(self):
        self.lock = threading.RLock()
        self.jobs = []
        self._load()

    def _load(self):
        if os.path.exists(STATE_PATH):
            try:
                with open(STATE_PATH) as handle:
                    self.jobs = json.load(handle).get("jobs", [])
            except Exception:
                self.jobs = []
        # Anything mid-flight when we were killed goes back in the queue.
        for job in self.jobs:
            if job.get("status") in ("downloading", "processing"):
                job["status"] = "queued"
                job["progress"] = 0.0

    def save(self):
        with self.lock:
            tmp = STATE_PATH + ".tmp"
            with open(tmp, "w") as handle:
                json.dump({"jobs": self.jobs[-500:]}, handle, indent=2)
            os.replace(tmp, STATE_PATH)

    def add(self, job):
        with self.lock:
            self.jobs.append(job)
            self.save()
        return job

    def update(self, job_id, **fields):
        with self.lock:
            for job in self.jobs:
                if job["id"] == job_id:
                    job.update(fields)
                    job["updated"] = time.time()
                    self.save()
                    return job
        return None

    def get(self, job_id):
        with self.lock:
            for job in self.jobs:
                if job["id"] == job_id:
                    return dict(job)
        return None

    def snapshot(self):
        with self.lock:
            return [dict(j) for j in self.jobs]

    def next_queued(self):
        with self.lock:
            for job in self.jobs:
                if job["status"] == "queued":
                    job["status"] = "downloading"
                    job["updated"] = time.time()
                    self.save()
                    return dict(job)
        return None


# ---------------------------------------------------------------------------
# Parsing requests
# ---------------------------------------------------------------------------

URL_RE = re.compile(r"https?://\S+")


def parse_request(text, config):
    """
    Turns a free-form line into job specs.

      https://youtu.be/abc            -> defaults
      https://youtu.be/abc mid        -> 720p
      https://youtu.be/abc audio learn stuff/german
      https://youtu.be/abc #guitar lessons best

    Returns a list of dicts: {url, quality, folder, playlist}
    """
    matches = list(URL_RE.finditer(text or ""))
    if not matches:
        return []
    urls = [m.group(0) for m in matches]

    # Only what you type *after* the last link counts as options, so pasting a
    # link into the middle of a sentence still does the right thing.
    remainder = (text or "")[matches[-1].end():].strip()
    playlist = False
    tokens = []
    for token in remainder.split():
        low = token.lower().strip("#,")
        if low in ("playlist", "--playlist", "all"):
            playlist = True
            continue
        tokens.append(token)

    quality = None
    folder_tokens = []
    for token in tokens:
        low = token.lower().strip("#,.")
        if quality is None and low in QUALITY_ALIASES:
            quality = QUALITY_ALIASES[low]
        else:
            folder_tokens.append(token.lstrip("#"))

    folder = " ".join(folder_tokens).strip().strip("/")
    jobs = []
    for url in urls:
        jobs.append({
            "url": url.rstrip(".,);"),
            "quality": quality or config["default_quality"],
            "folder": folder or config["default_folder"],
            "playlist": playlist,
        })
    return jobs


def safe_folder(folder):
    """Keeps a relative path, drops anything that would escape the root."""
    parts = []
    for raw in str(folder or "").replace("\\", "/").split("/"):
        piece = re.sub(r'[<>:"|?*\x00-\x1f]', "", raw).strip().strip(".")
        if piece and piece not in (".", ".."):
            parts.append(piece[:80])
    return "/".join(parts[:4])


def safe_filename(name):
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "", str(name or "video")).strip()
    name = re.sub(r"\s+", " ", name)
    return (name or "video")[:120].strip(". ")


# ---------------------------------------------------------------------------
# yt-dlp
# ---------------------------------------------------------------------------

def which(binary):
    return shutil.which(binary) or shutil.which(
        os.path.join("/opt/homebrew/bin", binary)
    ) or shutil.which(os.path.join("/usr/local/bin", binary))


def tool_path(name):
    # launchd agents get a bare PATH, so look in the usual Homebrew spots too.
    for candidate in (
        shutil.which(name),
        "/opt/homebrew/bin/" + name,
        "/usr/local/bin/" + name,
        os.path.expanduser("~/.local/bin/" + name),
    ):
        if candidate and os.path.exists(candidate):
            return candidate
    return None


def probe_metadata(url, playlist=False):
    ytdlp = tool_path("yt-dlp")
    if not ytdlp:
        raise RuntimeError("yt-dlp is not installed. Run: brew install yt-dlp")
    cmd = [ytdlp, "-J", "--no-warnings", "--skip-download"]
    cmd += ["--yes-playlist"] if playlist else ["--no-playlist"]
    cmd.append(url)
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if result.returncode != 0:
        raise RuntimeError((result.stderr or "yt-dlp could not read that link").strip()[-400:])
    return json.loads(result.stdout)


def entries_from(info):
    if info.get("_type") == "playlist":
        return [e for e in (info.get("entries") or []) if e]
    return [info]


def build_download_command(config, job, entry, output_stem):
    ytdlp = tool_path("yt-dlp")
    quality = job["quality"]
    fmt = QUALITY_FORMATS.get(quality, QUALITY_FORMATS["mid"])

    cmd = [
        ytdlp,
        "--no-warnings",
        "--no-playlist",
        "--newline",
        "--no-part",
        "--retries", "6",
        "--fragment-retries", "12",
        "--concurrent-fragments", "4",
        "--progress-template",
        "download:@@P@@%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
        "-f", fmt,
        "-o", output_stem + ".%(ext)s",
    ]

    if quality == "audio":
        cmd += ["-x", "--audio-format", "m4a", "--audio-quality", "0"]
    else:
        cmd += ["--merge-output-format", "mp4", "--remux-video", "mp4"]

    if config.get("embed_metadata", True):
        cmd += ["--embed-metadata", "--embed-chapters", "--embed-thumbnail"]

    if config.get("sponsorblock", True):
        cmd += ["--sponsorblock-remove", config.get(
            "sponsorblock_categories", "sponsor,selfpromo,interaction")]

    cmd.append(entry.get("webpage_url") or entry.get("original_url") or job["url"])
    return cmd


PROGRESS_RE = re.compile(r"@@P@@\s*([\d.]+)%\|([^|]*)\|(.*)")


def run_download(config, store, job, entry, output_stem):
    cmd = build_download_command(config, job, entry, output_stem)
    log("running:", " ".join(cmd[:6]), "...", entry.get("title"))

    process = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1,
    )
    tail = []
    assert process.stdout is not None
    for line in process.stdout:
        line = line.rstrip()
        match = PROGRESS_RE.search(line)
        if match:
            try:
                store.update(
                    job["id"],
                    progress=float(match.group(1)) / 100.0,
                    speed=match.group(2).strip(),
                    eta=match.group(3).strip(),
                )
            except ValueError:
                pass
        else:
            tail.append(line)
            tail[:] = tail[-25:]
    process.wait()
    if process.returncode != 0:
        raise RuntimeError("\n".join(tail)[-600:] or "yt-dlp failed")


def find_output(output_stem):
    directory = os.path.dirname(output_stem)
    stem = os.path.basename(output_stem)
    candidates = []
    for name in os.listdir(directory):
        base, ext = os.path.splitext(name)
        if base == stem and ext.lower() in MEDIA_EXTS:
            candidates.append(os.path.join(directory, name))
    if not candidates:
        return None
    candidates.sort(key=lambda p: os.path.getsize(p), reverse=True)
    return candidates[0]


def probe_codecs(path):
    ffprobe = tool_path("ffprobe")
    if not ffprobe:
        return None, None
    try:
        result = subprocess.run(
            [ffprobe, "-v", "error", "-show_entries", "stream=codec_type,codec_name",
             "-of", "json", path],
            capture_output=True, text=True, timeout=60,
        )
        streams = json.loads(result.stdout).get("streams", [])
    except Exception:
        return None, None
    video = next((s["codec_name"] for s in streams if s.get("codec_type") == "video"), None)
    audio = next((s["codec_name"] for s in streams if s.get("codec_type") == "audio"), None)
    return video, audio


def ensure_compatible(path, store, job):
    """
    Guarantees the file is something AVFoundation on iOS can actually open:
    H.264 video + AAC audio in an MP4 (or AAC in M4A for audio-only).
    """
    ffmpeg = tool_path("ffmpeg")
    if not ffmpeg:
        return path

    ext = os.path.splitext(path)[1].lower()
    video_codec, audio_codec = probe_codecs(path)

    audio_only = video_codec is None
    video_ok = video_codec in (None, "h264", "mpeg4", "mpeg2video")
    audio_ok = audio_codec in (None, "aac", "mp3", "alac", "pcm_s16le")
    container_ok = ext in (".mp4", ".m4v", ".mov", ".m4a", ".mp3")

    if video_ok and audio_ok and container_ok:
        return path

    store.update(job["id"], status="processing", stage="converting for iPhone")
    target_ext = ".m4a" if audio_only else ".mp4"
    target = os.path.splitext(path)[0] + ".converted" + target_ext

    cmd = [ffmpeg, "-y", "-i", path]
    if audio_only:
        cmd += ["-c:a", "aac", "-b:a", "192k", "-vn"]
    else:
        cmd += [
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart",
        ]
    cmd.append(target)

    log("transcoding for iOS:", os.path.basename(path), video_codec, audio_codec)
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0 or not os.path.exists(target):
        log("transcode failed, keeping original:", result.stderr[-300:])
        return path

    final = os.path.splitext(path)[0] + target_ext
    try:
        os.remove(path)
    except OSError:
        pass
    os.replace(target, final)
    return final


def write_sidecar(media_path, entry, job):
    sidecar = os.path.splitext(media_path)[0] + ".curator.json"
    payload = {
        "source_url": entry.get("webpage_url") or job["url"],
        "video_id": entry.get("id"),
        "title": entry.get("title"),
        "channel": entry.get("uploader") or entry.get("channel"),
        "channel_url": entry.get("channel_url"),
        "upload_date": entry.get("upload_date"),
        "duration": entry.get("duration"),
        "description": (entry.get("description") or "")[:4000],
        "quality_requested": job["quality"],
        "downloaded_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "chapters": [
            {"title": c.get("title"), "start": c.get("start_time"), "end": c.get("end_time")}
            for c in (entry.get("chapters") or [])
        ][:200],
    }
    try:
        with open(sidecar, "w") as handle:
            json.dump(payload, handle, indent=2)
    except Exception as exc:
        log("sidecar write failed:", exc)


# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------

class Worker(threading.Thread):
    daemon = True

    def __init__(self, config, store, notifier):
        super().__init__()
        self.config = config
        self.store = store
        self.notifier = notifier
        self.stop_flag = threading.Event()

    def run(self):
        while not self.stop_flag.is_set():
            job = self.store.next_queued()
            if not job:
                time.sleep(1.0)
                continue
            try:
                self.process(job)
            except Exception as exc:
                log("job failed:", job["id"], exc)
                self.store.update(job["id"], status="failed", error=str(exc)[:600])
                self.notifier(job, "failed", str(exc)[:300])

    def process(self, job):
        config = self.config
        self.store.update(job["id"], status="downloading", stage="reading link", progress=0.0)

        info = probe_metadata(job["url"], playlist=job.get("playlist", False))
        entries = entries_from(info)

        # A playlist request fans out into one job per video; this job becomes
        # the first entry so the requester sees something immediately.
        if len(entries) > 1:
            for extra in entries[1:]:
                self.store.add(new_job(
                    url=extra.get("webpage_url") or extra.get("url") or job["url"],
                    quality=job["quality"], folder=job["folder"],
                    source=job.get("source", "app"), chat_id=job.get("chat_id"),
                    title=extra.get("title"),
                ))

        entry = entries[0]
        title = entry.get("title") or "video"
        folder = safe_folder(job["folder"])
        destination = os.path.join(config["library_root"], folder) if folder else config["library_root"]
        os.makedirs(destination, exist_ok=True)

        stem = safe_filename(title)
        output_stem = os.path.join(destination, stem)
        if any(os.path.exists(output_stem + ext) for ext in MEDIA_EXTS):
            stem = safe_filename("%s [%s]" % (title, entry.get("id") or "copy"))
            output_stem = os.path.join(destination, stem)

        self.store.update(
            job["id"], title=title, folder=folder,
            duration=entry.get("duration"), channel=entry.get("uploader"),
            thumbnail=entry.get("thumbnail"), stage="downloading",
        )
        self.notifier(job, "started", title)

        run_download(config, self.store, job, entry, output_stem)

        media_path = find_output(output_stem)
        if not media_path:
            raise RuntimeError("yt-dlp finished but no media file appeared")

        if config.get("force_compatible", True):
            media_path = ensure_compatible(media_path, self.store, job)

        if config.get("write_sidecar", True):
            write_sidecar(media_path, entry, job)

        relative = os.path.relpath(media_path, config["library_root"])
        self.store.update(
            job["id"], status="ready", progress=1.0, stage="ready to transfer",
            file=relative, size=os.path.getsize(media_path),
            filename=os.path.basename(media_path),
        )
        self.notifier(job, "ready", "%s → %s" % (title, folder or "library root"))


def new_job(url, quality, folder, source, chat_id=None, title=None):
    now = time.time()
    return {
        "id": uuid.uuid4().hex[:12],
        "url": url,
        "quality": quality,
        "folder": folder,
        "title": title,
        "status": "queued",
        "progress": 0.0,
        "stage": "queued",
        "speed": "",
        "eta": "",
        "error": None,
        "file": None,
        "filename": None,
        "size": 0,
        "source": source,
        "chat_id": chat_id,
        "created": now,
        "updated": now,
        "delivered": False,
    }


# ---------------------------------------------------------------------------
# HTTP API
# ---------------------------------------------------------------------------

def make_handler(config, store):

    class Handler(BaseHTTPRequestHandler):
        server_version = "CuratorStudio/1.0"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass

        # -- helpers ----------------------------------------------------

        def _send_json(self, payload, code=200):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def _authorised(self):
            supplied = self.headers.get("X-Curator-Token", "")
            if supplied and supplied == config["token"]:
                return True
            query = urllib.parse.urlparse(self.path).query
            token = urllib.parse.parse_qs(query).get("token", [""])[0]
            if token == config["token"]:
                return True
            self._send_json({"error": "bad or missing token"}, 401)
            return False

        def _resolve_library_path(self, relative):
            root = os.path.realpath(config["library_root"])
            candidate = os.path.realpath(os.path.join(root, relative))
            if not candidate.startswith(root + os.sep) and candidate != root:
                return None
            return candidate

        def _content_disposition(self, path):
            # HTTP headers are latin-1 only; video titles routinely carry
            # characters (curly quotes, "…", emoji) outside that range, which
            # would otherwise crash the request with a UnicodeEncodeError.
            name = os.path.basename(path).replace('"', "")
            ascii_name = name.encode("ascii", "ignore").decode("ascii").strip() or "download"
            return 'attachment; filename="%s"; filename*=UTF-8\'\'%s' % (
                ascii_name, urllib.parse.quote(name))

        def _serve_file(self, path):
            if not path or not os.path.isfile(path):
                self._send_json({"error": "not found"}, 404)
                return
            size = os.path.getsize(path)
            start, end = 0, size - 1
            status = 200
            range_header = self.headers.get("Range")
            if range_header:
                match = re.match(r"bytes=(\d*)-(\d*)", range_header)
                if match:
                    if match.group(1):
                        start = int(match.group(1))
                    if match.group(2):
                        end = min(int(match.group(2)), size - 1)
                    if start > end or start >= size:
                        self.send_response(416)
                        self.send_header("Content-Range", "bytes */%d" % size)
                        self.end_headers()
                        return
                    status = 206

            length = end - start + 1
            self.send_response(status)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Disposition", self._content_disposition(path))
            if status == 206:
                self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
            self.end_headers()

            with open(path, "rb") as handle:
                handle.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = handle.read(min(1024 * 512, remaining))
                    if not chunk:
                        break
                    try:
                        self.wfile.write(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        return
                    remaining -= len(chunk)

        def _shelf(self):
            root = config["library_root"]
            items = []
            for base, dirs, files in os.walk(root):
                dirs[:] = [d for d in dirs if not d.startswith(".")]
                for name in files:
                    if name.startswith("."):
                        continue
                    if os.path.splitext(name)[1].lower() not in MEDIA_EXTS:
                        continue
                    full = os.path.join(base, name)
                    try:
                        stat = os.stat(full)
                    except OSError:
                        continue
                    items.append({
                        "path": os.path.relpath(full, root),
                        "name": name,
                        "size": stat.st_size,
                        "modified": stat.st_mtime,
                    })
            items.sort(key=lambda i: i["modified"], reverse=True)
            return items

        # -- routes -----------------------------------------------------

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            route = parsed.path.rstrip("/") or "/"
            params = urllib.parse.parse_qs(parsed.query)

            if route == "/health":
                self._send_json({
                    "service": "curator-studio",
                    "api": API_VERSION,
                    "name": config["device_name"],
                    "library_root": config["library_root"],
                    "queued": sum(1 for j in store.snapshot()
                                  if j["status"] in ("queued", "downloading", "processing")),
                    "ready": sum(1 for j in store.snapshot()
                                 if j["status"] == "ready" and not j.get("delivered")),
                })
                return

            if not self._authorised():
                return

            if route == "/jobs":
                self._send_json({"jobs": store.snapshot()[-200:]})
                return

            if route == "/folders":
                root = config["library_root"]
                folders = []
                for base, dirs, _ in os.walk(root):
                    dirs[:] = [d for d in dirs if not d.startswith(".")]
                    rel = os.path.relpath(base, root)
                    if rel != ".":
                        folders.append(rel)
                folders.sort()
                self._send_json({"folders": folders[:500]})
                return

            if route == "/shelf":
                self._send_json({"items": self._shelf()})
                return

            if route == "/shelf/file":
                rel = params.get("path", [""])[0]
                self._serve_file(self._resolve_library_path(rel))
                return

            if route.startswith("/files/"):
                job = store.get(route.split("/files/", 1)[1])
                if not job or not job.get("file"):
                    self._send_json({"error": "no file for that job"}, 404)
                    return
                self._serve_file(self._resolve_library_path(job["file"]))
                return

            self._send_json({"error": "unknown route"}, 404)

        def do_POST(self):
            parsed = urllib.parse.urlparse(self.path)
            route = parsed.path.rstrip("/") or "/"
            if not self._authorised():
                return

            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b"{}"
            try:
                payload = json.loads(raw.decode() or "{}")
            except Exception:
                payload = {}

            if route == "/jobs":
                text = payload.get("text") or payload.get("url") or ""
                specs = parse_request(text, config)
                if not specs:
                    self._send_json({"error": "no link found in that request"}, 400)
                    return
                created = []
                for spec in specs:
                    if payload.get("quality"):
                        spec["quality"] = QUALITY_ALIASES.get(
                            str(payload["quality"]).lower(), spec["quality"])
                    if payload.get("folder"):
                        spec["folder"] = payload["folder"]
                    job = store.add(new_job(
                        url=spec["url"], quality=spec["quality"],
                        folder=safe_folder(spec["folder"]),
                        source=payload.get("source", "app"),
                    ))
                    created.append(job)
                self._send_json({"created": created})
                return

            if route.startswith("/jobs/") and route.endswith("/ack"):
                job_id = route[len("/jobs/"):-len("/ack")]
                store.update(job_id, delivered=True, status="delivered")
                self._send_json({"ok": True})
                return

            if route.startswith("/jobs/") and route.endswith("/retry"):
                job_id = route[len("/jobs/"):-len("/retry")]
                store.update(job_id, status="queued", error=None, progress=0.0)
                self._send_json({"ok": True})
                return

            self._send_json({"error": "unknown route"}, 404)

        def do_DELETE(self):
            if not self._authorised():
                return
            route = urllib.parse.urlparse(self.path).path.rstrip("/")
            if route.startswith("/jobs/"):
                job_id = route[len("/jobs/"):]
                with store.lock:
                    store.jobs = [j for j in store.jobs if j["id"] != job_id]
                    store.save()
                self._send_json({"ok": True})
                return
            self._send_json({"error": "unknown route"}, 404)

    return Handler


# ---------------------------------------------------------------------------
# Telegram
# ---------------------------------------------------------------------------

class TelegramBridge(threading.Thread):
    daemon = True

    def __init__(self, config, store):
        super().__init__()
        self.config = config
        self.store = store
        self.offset = 0
        self.stop_flag = threading.Event()

    @property
    def token(self):
        return self.config.get("telegram", {}).get("bot_token", "")

    def api(self, method, params=None, timeout=35):
        url = "https://api.telegram.org/bot%s/%s" % (self.token, method)
        data = json.dumps(params or {}).encode()
        request = urllib.request.Request(
            url, data=data, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode())

    def send(self, chat_id, text):
        if not self.token or not chat_id:
            return
        try:
            self.api("sendMessage", {
                "chat_id": chat_id,
                "text": text,
                "disable_web_page_preview": True,
            }, timeout=20)
        except Exception as exc:
            log("telegram send failed:", exc)

    def allowed(self, chat_id):
        telegram = self.config.setdefault("telegram", {})
        allowed = telegram.setdefault("allowed_chat_ids", [])
        if chat_id in allowed:
            return True
        if not allowed and telegram.get("learn_first_chat", True):
            allowed.append(chat_id)
            save_config(self.config)
            log("paired with Telegram chat", chat_id)
            return True
        return False

    def run(self):
        if not self.token:
            log("telegram: no bot token configured, skipping")
            return
        log("telegram: polling for messages")
        while not self.stop_flag.is_set():
            try:
                response = self.api("getUpdates", {
                    "offset": self.offset, "timeout": 25,
                    "allowed_updates": ["message"],
                })
                for update in response.get("result", []):
                    self.offset = update["update_id"] + 1
                    self.handle(update.get("message") or {})
            except Exception as exc:
                log("telegram poll error:", exc)
                time.sleep(5)

    def handle(self, message):
        chat_id = (message.get("chat") or {}).get("id")
        text = message.get("text") or message.get("caption") or ""
        if not chat_id or not text:
            return
        if not self.allowed(chat_id):
            self.send(chat_id, "This Curator Studio isn't paired with you.")
            return

        command = text.strip().lower()
        if command in ("/start", "/help", "help"):
            self.send(chat_id, HELP_TEXT)
            return
        if command == "/status":
            self.send(chat_id, self.status_text())
            return
        if command == "/folders":
            root = self.config["library_root"]
            names = sorted(
                d for d in os.listdir(root)
                if os.path.isdir(os.path.join(root, d)) and not d.startswith("."))
            self.send(chat_id, "Folders:\n" + "\n".join("· " + n for n in names) if names
                      else "No folders yet.")
            return

        specs = parse_request(text, self.config)
        if not specs:
            self.send(chat_id, "I couldn't find a link in that.")
            return

        lines = []
        for spec in specs:
            job = self.store.add(new_job(
                url=spec["url"], quality=spec["quality"],
                folder=safe_folder(spec["folder"]),
                source="telegram", chat_id=chat_id,
            ))
            lines.append("Queued · %s · → %s" % (job["quality"], job["folder"]))
        self.send(chat_id, "\n".join(lines))

    def status_text(self):
        jobs = self.store.snapshot()[-12:]
        if not jobs:
            return "Nothing in the queue."
        rows = []
        for job in reversed(jobs):
            label = job.get("title") or job["url"]
            rows.append("%s %s — %s" % (
                {"queued": "⏳", "downloading": "⬇️", "processing": "⚙️",
                 "ready": "✅", "delivered": "📱", "failed": "⚠️"}.get(job["status"], "•"),
                label[:48],
                job.get("stage") or job["status"],
            ))
        return "\n".join(rows)


HELP_TEXT = """Curator Studio

Send me a link, optionally with a quality and a folder:

  <link>
  <link> mid
  <link> audio Learn Stuff/German
  <link> best Guitar Lessons
  <link> low Bike Stuff playlist

Quality: best · high · mid · low · audio
Folder: anything — it's created if it doesn't exist. Use / to nest.

/status   what's in the queue
/folders  folders I know about
"""


# ---------------------------------------------------------------------------
# Bonjour
# ---------------------------------------------------------------------------

def advertise(config):
    """Publishes _curator._tcp so the iPhone app finds the Mac by itself."""
    dns_sd = shutil.which("dns-sd")
    if not dns_sd:
        return None
    try:
        return subprocess.Popen(
            [dns_sd, "-R", config["device_name"], "_curator._tcp", "local",
             str(config["port"]), "api=%d" % API_VERSION],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception as exc:
        log("bonjour advertise failed:", exc)
        return None


def local_ip():
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        address = sock.getsockname()[0]
        sock.close()
        return address
    except Exception:
        return "127.0.0.1"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Curator Studio Mac daemon")
    parser.add_argument("--foreground", action="store_true", help="log to the terminal")
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--add", metavar="TEXT", help="queue a request and exit")
    parser.add_argument("--status", action="store_true", help="print the queue and exit")
    parser.add_argument("--token", action="store_true", help="print the pairing details and exit")
    args = parser.parse_args()

    config = load_config()
    if args.port:
        config["port"] = args.port

    if args.token:
        print("Host:  %s:%d" % (local_ip(), config["port"]))
        print("Token: %s" % config["token"])
        print("Paste both into Curator Studio → Inbox → Connect to Mac.")
        return

    store = Store()

    if args.add:
        specs = parse_request(args.add, config)
        if not specs:
            print("No link found.")
            return
        for spec in specs:
            store.add(new_job(url=spec["url"], quality=spec["quality"],
                              folder=safe_folder(spec["folder"]), source="cli"))
            print("Queued %s (%s → %s)" % (spec["url"], spec["quality"], spec["folder"]))
        print("The running daemon will pick it up.")
        return

    if args.status:
        for job in store.snapshot()[-20:]:
            print("%-10s %-9s %5.0f%%  %s" % (
                job["status"], job["quality"], job["progress"] * 100,
                job.get("title") or job["url"]))
        return

    telegram = TelegramBridge(config, store)

    def notifier(job, event, detail):
        chat_id = job.get("chat_id")
        if not chat_id:
            return
        icons = {"started": "⬇️ Downloading", "ready": "✅ Ready on your Mac",
                 "failed": "⚠️ Failed"}
        telegram.send(chat_id, "%s\n%s" % (icons.get(event, event), detail))

    workers = [Worker(config, store, notifier)
               for _ in range(max(1, int(config.get("max_concurrent_jobs", 2))))]
    for worker in workers:
        worker.start()

    if telegram.token:
        telegram.start()

    bonjour = advertise(config) if config.get("advertise_bonjour", True) else None

    handler = make_handler(config, store)
    server = ThreadingHTTPServer(("0.0.0.0", int(config["port"])), handler)
    server.daemon_threads = True

    log("Curator Studio daemon ready")
    log("  library : %s" % config["library_root"])
    log("  address : http://%s:%d" % (local_ip(), config["port"]))
    log("  token   : %s" % config["token"])
    log("  telegram: %s" % ("on" if telegram.token else "off"))

    def shutdown(*_):
        log("shutting down")
        for worker in workers:
            worker.stop_flag.set()
        telegram.stop_flag.set()
        if bonjour:
            bonjour.terminate()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
