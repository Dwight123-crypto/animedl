#!/usr/bin/env python3
"""HTTP backend for the AnimeDL iOS app.

Search and episode lists go straight to the animepahe API (through
curl-impersonate, like animepahe-dl.sh does). Downloads run animepahe-dl.sh's
own functions via pahe-job.sh, one episode at a time. Finished files are
served with HTTP range support so the phone can stream or save them.

Stdlib only. Run:  python3 server.py
"""

import hashlib
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import socket
import subprocess
import threading
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PAHE_SCRIPT = ROOT / "animepahe-dl" / "animepahe-dl.sh"
JOB_SCRIPT = ROOT / "pahe-job.sh"
CONFIG_FILE = ROOT / "config.json"  # {"cf": ..., "ua": ...}, read by animepahe-dl.sh too
TOKEN_FILE = ROOT / ".token"
IMAGE_CACHE = ROOT / ".cache" / "images"
DOWNLOAD_DIR = Path(os.environ.get("ANIMEDL_DIR", ROOT / "downloads")).expanduser().resolve()
PORT = int(os.environ.get("ANIMEDL_PORT", "8765"))

HOST = "https://animepahe.pw"
DEPENDENCIES = ["curl-impersonate", "jq", "fzf", "yt-dlp", "ffmpeg"]

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
PROGRESS = re.compile(r"(\d{1,3}(?:\.\d+)?)%")
EPISODE = re.compile(r"\d+(?:\.\d+)?")
SLUG = re.compile(r"[A-Za-z0-9-]+")


class PaheError(Exception):
    """animepahe or a local tool failed; message is shown in the app."""


class BadRequest(Exception):
    pass


# --- config & auth -----------------------------------------------------------

def load_config():
    try:
        cfg = json.loads(CONFIG_FILE.read_text())
    except (OSError, ValueError):
        cfg = {}
    return {"cf": cfg.get("cf") or "", "ua": cfg.get("ua") or ""}


def save_config(cf, ua):
    CONFIG_FILE.write_text(json.dumps({"cf": cf, "ua": ua}, indent=2) + "\n")
    CONFIG_FILE.chmod(0o600)


def load_token():
    token = os.environ.get("ANIMEDL_TOKEN")
    if token:
        return token
    if TOKEN_FILE.exists():
        return TOKEN_FILE.read_text().strip()
    token = secrets.token_urlsafe(16)
    TOKEN_FILE.write_text(token + "\n")
    TOKEN_FILE.chmod(0o600)
    return token


TOKEN = load_token()


# --- animepahe ---------------------------------------------------------------

CHROME_LOCK = threading.Lock()


def refresh_from_chrome():
    """Copy animepahe's cf_clearance and Chrome's user-agent into config.json.

    Runs chrome_cf.py with yt-dlp's Python, which knows how to decrypt Chrome
    cookies. Returns None on success, else an error message.
    """
    ytdlp = shutil.which("yt-dlp")
    if not ytdlp:
        return "yt-dlp is not installed."
    with open(Path(ytdlp).resolve(), errors="replace") as f:
        first = f.readline()
    python = shlex.split(first[2:]) if first.startswith("#!") else ["python3"]
    with CHROME_LOCK:
        try:
            r = subprocess.run(python + ["-I", str(ROOT / "chrome_cf.py")],
                               capture_output=True, text=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired) as e:
            return f"Reading Chrome cookies failed: {e}"
        if r.returncode != 0:
            return (r.stderr.strip().splitlines() or ["Reading Chrome cookies failed."])[-1]
        try:
            got = json.loads(r.stdout)
        except ValueError:
            return "Reading Chrome cookies failed."
        save_config(got["cf"], got["ua"])
    return None


def pahe_get(url):
    cfg = load_config()
    if not cfg["cf"] or not cfg["ua"]:
        err = refresh_from_chrome()
        if err:
            raise PaheError(f"No Cloudflare cookie: {err}")
        cfg = load_config()
    curl = shutil.which("curl-impersonate")
    if not curl:
        raise PaheError("curl-impersonate is not installed on the server.")
    cmd = [curl, "-sS", "-L", "--compressed", "--max-time", "30",
           "-b", f"cf_clearance={cfg['cf']}", "-A", cfg["ua"], url]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=40)
    except subprocess.TimeoutExpired:
        raise PaheError("animepahe timed out.")
    if r.returncode != 0:
        raise PaheError("curl-impersonate failed: " + r.stderr.decode(errors="replace").strip())
    return r.stdout


def pahe_json(url):
    try:
        return json.loads(pahe_get(url))
    except ValueError:
        pass
    # Probably a Cloudflare challenge: grab a fresh cookie from Chrome and retry once.
    err = refresh_from_chrome()
    try:
        return json.loads(pahe_get(url))
    except ValueError:
        raise PaheError("Cloudflare blocked the request. Open https://animepahe.pw in Chrome on the "
                        "Mac, pass the check, then try again." + (f" ({err})" if err else ""))


def search(query):
    d = pahe_json(f"{HOST}/api?m=search&q={urllib.parse.quote(query)}")
    return [{
        "slug": a.get("session"),
        "title": a.get("title") or "",
        "type": a.get("type"),
        "episodes": a.get("episodes"),
        "status": a.get("status"),
        "year": a.get("year"),
        "score": a.get("score"),
        "poster": a.get("poster"),
    } for a in d.get("data") or [] if a.get("session")]


def episode_number(value):
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    return str(value)


def episodes(slug):
    url = f"{HOST}/api?m=release&id={slug}&sort=episode_asc&page="
    first = pahe_json(url + "1")
    data = list(first.get("data") or [])
    for page in range(2, int(first.get("last_page") or 1) + 1):
        data += pahe_json(url + str(page)).get("data") or []
    return [{
        "episode": episode_number(e.get("episode")),
        "title": e.get("title") or "",
        "duration": e.get("duration"),
        "snapshot": e.get("snapshot"),
        "audio": e.get("audio"),
        "createdAt": e.get("created_at"),
    } for e in data]


def image(url):
    """Fetch and cache a poster/snapshot (they sit behind Cloudflare too)."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or "pahe" not in (parts.hostname or ""):
        raise BadRequest("image host not allowed")
    IMAGE_CACHE.mkdir(parents=True, exist_ok=True)
    cached = IMAGE_CACHE / hashlib.sha1(url.encode()).hexdigest()
    if cached.exists():
        return cached.read_bytes()
    body = pahe_get(url)
    if body.lstrip()[:1] == b"<":
        raise PaheError("image blocked by Cloudflare")
    cached.write_bytes(body)
    return body


def image_type(body):
    if body.startswith(b"\x89PNG"):
        return "image/png"
    if body[8:12] == b"WEBP":
        return "image/webp"
    return "image/jpeg"


# --- download queue ----------------------------------------------------------

def stop(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)  # bash, curl and yt-dlp together
    except ProcessLookupError:
        pass


class Jobs:
    """Runs one pahe-job.sh at a time, in the order episodes were queued."""

    def __init__(self):
        self.cond = threading.Condition()
        self.jobs = []
        self.procs = {}
        threading.Thread(target=self._worker, daemon=True).start()

    def add(self, slug, title, eps, resolution, audio):
        added = []
        with self.cond:
            for ep in eps:
                job = {"id": uuid.uuid4().hex[:12], "slug": slug, "title": title, "episode": ep,
                       "resolution": resolution, "audio": audio, "status": "queued",
                       "progress": 0.0, "message": "", "file": None, "createdAt": time.time()}
                self.jobs.append(job)
                added.append(dict(job))
            self.cond.notify()
        return added

    def list(self):
        with self.cond:
            return [dict(j) for j in self.jobs]

    def cancel(self, job_id):
        with self.cond:
            job = next((j for j in self.jobs if j["id"] == job_id), None)
            if not job:
                raise BadRequest("no such job")
            if job["status"] in ("queued", "downloading"):
                job["status"] = "cancelled"
                job["message"] = "Cancelled"
                proc = self.procs.get(job_id)
                if proc:
                    stop(proc)
            else:
                self.jobs.remove(job)

    def clear_finished(self):
        with self.cond:
            self.jobs = [j for j in self.jobs if j["status"] in ("queued", "downloading")]

    def _worker(self):
        while True:
            with self.cond:
                while True:
                    job = next((j for j in self.jobs if j["status"] == "queued"), None)
                    if job:
                        break
                    self.cond.wait()
                job["status"] = "downloading"
                job["message"] = "Finding video link…"
            try:
                self._run(job)
            except Exception as e:  # keep the worker alive no matter what
                with self.cond:
                    job["status"] = "failed"
                    job["message"] = str(e)

    def _run(self, job):
        refresh_from_chrome()  # cookie may have rotated since the last request
        env = dict(os.environ, PAHE_SCRIPT=str(PAHE_SCRIPT), PAHE_DOWNLOAD_DIR=str(DOWNLOAD_DIR))
        proc = subprocess.Popen(
            ["bash", str(JOB_SCRIPT), job["slug"], job["title"], job["episode"],
             job["resolution"], job["audio"]],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        with self.cond:
            self.procs[job["id"]] = proc
            if job["status"] == "cancelled":
                stop(proc)

        tail, buf = [], b""
        while chunk := os.read(proc.stdout.fileno(), 4096):
            *lines, buf = re.split(rb"[\r\n]", buf + chunk)
            for raw in lines:
                self._line(job, raw, tail)
        self._line(job, buf, tail)
        code = proc.wait()

        with self.cond:
            self.procs.pop(job["id"], None)
            if job["status"] == "cancelled":
                return
            if code == 0 and job["file"] and (DOWNLOAD_DIR / job["file"]).is_file():
                job.update(status="done", progress=100.0, message="")
            else:
                job["status"] = "failed"
                job["message"] = tail[-1] if tail else f"exited with code {code}"

    def _line(self, job, raw, tail):
        line = ANSI.sub("", raw.decode(errors="replace")).strip()
        if not line:
            return
        with self.cond:
            if line.startswith("@@FILE "):
                job["file"] = line[len("@@FILE "):]
                return
            m = PROGRESS.search(line)
            if m and "[download]" in line:
                job["progress"] = min(float(m.group(1)), 100.0)
                job["message"] = line.replace("[download]", "").strip()
                return
            job["message"] = re.sub(r"^\[(INFO|WARNING|ERROR)\]\s*", "", line)
            tail.append(job["message"])
            del tail[:-20]


JOBS = Jobs()


# --- library -----------------------------------------------------------------

def sort_key(path):
    try:
        return (0, float(path.stem))
    except ValueError:
        return (1, path.stem)


def library():
    if not DOWNLOAD_DIR.exists():
        return []
    shows = []
    for d in sorted((p for p in DOWNLOAD_DIR.iterdir() if p.is_dir()), key=lambda p: p.name.lower()):
        eps = [{"episode": f.stem, "path": f.relative_to(DOWNLOAD_DIR).as_posix(),
                "size": f.stat().st_size}
               for f in sorted(d.glob("*.mp4"), key=sort_key)]
        if eps:
            shows.append({"name": d.name, "episodes": eps})
    return shows


def library_path(rel):
    path = (DOWNLOAD_DIR / rel).resolve()
    if DOWNLOAD_DIR not in path.parents:
        raise BadRequest("bad path")
    return path


def status():
    cfg = load_config()
    return {
        "missing": [d for d in DEPENDENCIES if not shutil.which(d)],
        "configured": bool(cfg["cf"] and cfg["ua"]),
        "ua": cfg["ua"],
        "downloadDir": str(DOWNLOAD_DIR),
    }


# --- HTTP --------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "AnimeDL/1.0"
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self._dispatch()

    def do_HEAD(self):
        self._dispatch()

    def do_POST(self):
        self._dispatch()

    def do_PUT(self):
        self._dispatch()

    def do_DELETE(self):
        self._dispatch()

    def log_message(self, fmt, *args):
        # Never log the token from ?token=...
        print(f"{self.address_string()} {self.command} {self.path.split('?')[0]} {args[1] if len(args) > 1 else ''}")

    def _dispatch(self):
        url = urllib.parse.urlsplit(self.path)
        query = {k: v[-1] for k, v in urllib.parse.parse_qs(url.query).items()}
        try:
            if not self._authorized(query):
                return self._json({"error": "Wrong or missing token."}, 401)
            self._route(self.command, url.path, query)
        except BadRequest as e:
            self._json({"error": str(e)}, 400)
        except PaheError as e:
            self._json({"error": str(e)}, 502)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _authorized(self, query):
        auth = self.headers.get("Authorization", "")
        given = auth[7:] if auth.startswith("Bearer ") else query.get("token", "")
        return secrets.compare_digest(given.encode(), TOKEN.encode())

    def _route(self, method, path, q):
        if path.startswith("/files/") and method in ("GET", "HEAD"):
            return self._file(library_path(urllib.parse.unquote(path[len("/files/"):])))
        route = (method, path)
        if route == ("GET", "/api/status"):
            return self._json(status())
        if route == ("GET", "/api/search"):
            return self._json(search(q.get("q", "").strip()))
        if route == ("GET", "/api/episodes"):
            return self._json(episodes(self._slug(q.get("slug", ""))))
        if route == ("GET", "/api/image"):
            body = image(q.get("url", ""))
            return self._send(200, body, image_type(body), {"Cache-Control": "max-age=604800"})
        if route == ("GET", "/api/downloads"):
            return self._json(JOBS.list())
        if route == ("POST", "/api/downloads"):
            b = self._body()
            eps = [str(e) for e in b.get("episodes") or []]
            if not eps or not all(EPISODE.fullmatch(e) for e in eps):
                raise BadRequest("episodes must be a list of episode numbers")
            resolution = str(b.get("resolution") or "")
            audio = str(b.get("audio") or "")
            if not re.fullmatch(r"\d*", resolution) or not re.fullmatch(r"[a-z]*", audio):
                raise BadRequest("bad resolution or audio")
            title = str(b.get("title") or "").strip()
            if not title:
                raise BadRequest("title is required")
            return self._json(JOBS.add(self._slug(b.get("slug", "")), title, eps, resolution, audio), 201)
        if route == ("DELETE", "/api/downloads"):
            if q.get("finished"):
                JOBS.clear_finished()
            else:
                JOBS.cancel(q.get("id", ""))
            return self._json({"ok": True})
        if route == ("GET", "/api/library"):
            return self._json(library())
        if route == ("DELETE", "/api/library"):
            path = library_path(q.get("path", ""))
            if path.suffix != ".mp4" or not path.is_file():
                raise BadRequest("not a downloaded episode")
            path.unlink()
            return self._json({"ok": True})
        if route == ("POST", "/api/config/refresh"):
            err = refresh_from_chrome()
            if err:
                raise PaheError(err)
            return self._json(status())
        if route == ("PUT", "/api/config"):
            b = self._body()
            cf, ua = str(b.get("cf") or "").strip(), str(b.get("ua") or "").strip()
            if not cf or not ua:
                raise BadRequest("cf and ua are both required")
            save_config(cf, ua)
            return self._json(status())
        self._json({"error": "not found"}, 404)

    def _slug(self, slug):
        if not SLUG.fullmatch(str(slug)):
            raise BadRequest("bad anime slug")
        return slug

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            raise BadRequest("body must be JSON")
        if not isinstance(body, dict):
            raise BadRequest("body must be a JSON object")
        return body

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj).encode(), "application/json")

    def _send(self, code, body, content_type, headers=None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _file(self, path):
        if path.suffix != ".mp4" or not path.is_file():
            return self._json({"error": "not found"}, 404)
        size = path.stat().st_size
        start, end, code = 0, size - 1, 200
        m = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers.get("Range", "").strip())
        if m and (m.group(1) or m.group(2)):
            if m.group(1):
                start = int(m.group(1))
                end = min(int(m.group(2)), size - 1) if m.group(2) else size - 1
            else:  # suffix range: last N bytes
                start = max(0, size - int(m.group(2)))
            if start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            code = 206
        self.send_response(code)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if code == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD":
            return
        with path.open("rb") as f:
            f.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                chunk = f.read(min(1 << 20, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)


def lan_ip():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("10.255.255.255", 1))  # no packets are sent
            return s.getsockname()[0]
        except OSError:
            return "127.0.0.1"


def main():
    if not PAHE_SCRIPT.exists():
        raise SystemExit(f"Missing {PAHE_SCRIPT}. Run: git clone https://github.com/KevCui/animepahe-dl.git {PAHE_SCRIPT.parent}")
    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
    print("Reading animepahe's Cloudflare cookie from Chrome (allow Keychain access if asked)…")
    err = refresh_from_chrome()
    print(f"  {err}" if err else "  Got it.")
    s = status()
    print(f"AnimeDL server\n  URL:       http://{lan_ip()}:{PORT}\n  Token:     {TOKEN}\n"
          f"  Downloads: {DOWNLOAD_DIR}")
    if s["missing"]:
        print("  WARNING: missing tools: " + ", ".join(s["missing"]))
    if not s["configured"]:
        print("  WARNING: no Cloudflare cookie yet. Open https://animepahe.pw in Chrome; the server picks it up automatically.")
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
