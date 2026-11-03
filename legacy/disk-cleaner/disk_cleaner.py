#!/usr/bin/env python3
"""Local disk cleaner: scans your Mac, shows everything sorted by size,
and deletes (or moves to Trash) only what you tick.

Run:  python3 ~/Documents/disk-cleaner/disk_cleaner.py
Then open http://127.0.0.1:8765 (it opens automatically).
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PORT = 8765
MIN_NODE = 20 * 1024 ** 2  # items smaller than 20 MB are folded into "small items"
HOME = os.path.expanduser("~")


def user_tmp_root():
    out = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout
    return os.path.realpath(os.path.dirname(out.strip().rstrip("/")))


TMP = user_tmp_root()
ROOTS = [HOME, "/Applications", TMP]
DATA_VOLUME = "/System/Volumes/Data" if os.path.exists("/System/Volumes/Data") else "/"

# Folders that must never be deleted as a whole (their contents can be).
PROTECTED = {os.path.realpath(p) for p in [
    HOME, "/Applications", TMP,
    *[os.path.join(HOME, d) for d in [
        "Library", "Library/Application Support", "Library/Caches", "Library/Preferences",
        "Library/Keychains", "Library/Containers", "Library/Group Containers", "Library/Mail",
        "Library/Mobile Documents", "Library/CloudStorage",
        "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", ".ssh",
    ]],
    *[os.path.join(TMP, d) for d in ["T", "C", "X", "0"]],
]}
NEVER_INSIDE = [os.path.join(HOME, "Library/Keychains"), os.path.join(HOME, ".ssh")]

# (path, label, safety, note)
SUGGESTIONS = [
    (f"{TMP}/X/com.google.Chrome.code_sign_clone", "Chrome leftover copies", "safe",
     "A Chrome bug leaves old copies of the app here. Quit Chrome first."),
    (f"{TMP}/X/com.brave.Browser.code_sign_clone", "Brave leftover copies", "safe",
     "Same bug as Chrome. Quit Brave first."),
    ("~/Library/Caches/go-build", "Go build cache", "safe", "Rebuilt on the next go build."),
    ("~/Library/Caches/pnpm", "pnpm metadata cache", "safe", "Re-downloaded when needed."),
    ("~/Library/Caches/BraveSoftware", "Brave browser cache", "safe", "Quit Brave first."),
    ("~/Library/Caches/com.brave.Browser", "Brave browser cache (2)", "safe", "Quit Brave first."),
    ("~/Library/Caches/Google", "Chrome browser cache", "safe", "Quit Chrome first."),
    ("~/Library/Caches/com.microsoft.VSCode.ShipIt", "VS Code old update files", "safe", "Leftovers from past updates."),
    ("~/Library/Caches/Homebrew", "Homebrew downloads", "safe", "Old installer downloads."),
    ("~/Library/Application Support/Google/GoogleUpdater/crx_cache", "Google updater cache", "safe", "Old update packages."),
    ("~/.gradle/caches", "Gradle cache", "safe", "Re-downloaded on the next Android/Gradle build."),
    ("~/.npm/_cacache", "npm cache", "safe", "Re-downloaded when needed."),
    ("~/go/pkg/mod", "Go module downloads", "safe", "Re-downloaded on the next go build."),
    ("~/.Trash", "Trash contents", "safe", "Things you already deleted. (Empties the Trash.)"),
    ("~/Library/pnpm/store", "pnpm package store", "check",
     "Projects re-download packages on the next pnpm install. Files still used by node_modules stay on disk until those projects are reinstalled."),
    ("~/Library/Application Support/com.apple.wallpaper/aerials/videos", "Aerial wallpaper videos", "check",
     "Downloaded screen-saver videos; macOS re-downloads the one you use."),
    ("~/.ollama/models", "Ollama AI models", "check", "Your downloaded models. Delete only if you no longer use them."),
    ("~/.android/avd", "Android emulator phones", "check", "Your emulators. Delete only if you don't use them."),
    ("~/Library/Android/sdk/system-images", "Android system images", "check", "Needed to create/run emulators."),
    ("~/.codeium", "Codeium / Windsurf index", "check", "Rebuilt when you reopen the editor."),
]

state = {"scanning": False, "files": 0, "started": 0.0, "took": 0.0, "job": {"running": False}}
lock = threading.Lock()
nodes = {}    # path -> node dict
parents = {}  # path -> parent path
big_files = []


def disk_size(st):
    return st.st_blocks * 512


def scan_dir(path, dev, seen, parent):
    """Return a node for path; children under MIN_NODE are folded."""
    node = {"p": path, "n": os.path.basename(path) or path, "s": 0, "d": True, "c": [], "o": 0}
    try:
        it = os.scandir(path)
    except OSError:
        node["err"] = True
        return node
    with it:
        for e in it:
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            if stat.S_ISDIR(st.st_mode):
                if st.st_dev != dev:
                    continue  # other volume / mount (e.g. ~/OrbStack)
                child = scan_dir(e.path, dev, seen, path)
            else:
                state["files"] += 1
                if st.st_nlink > 1:
                    key = (st.st_dev, st.st_ino)
                    if key in seen:
                        continue  # hard link already counted
                    seen.add(key)
                size = disk_size(st)
                child = {"p": e.path, "n": e.name, "s": size, "d": False}
                if size >= MIN_NODE and stat.S_ISREG(st.st_mode):
                    big_files.append({"p": e.path, "s": size, "m": st.st_mtime})
            node["s"] += child["s"]
            if child["s"] >= MIN_NODE:
                node["c"].append(child)
                nodes[child["p"]] = child
                parents[child["p"]] = path
            else:
                node["o"] += child["s"]
    node["c"].sort(key=lambda c: -c["s"])
    return node


def run_scan():
    with lock:
        state.update(scanning=True, files=0, started=time.time())
        nodes.clear()
        parents.clear()
        big_files.clear()
    seen = set()
    root = {"p": "/", "n": "Scanned folders", "s": 0, "d": True, "c": [], "o": 0}
    for r in ROOTS:
        try:
            dev = os.lstat(r).st_dev
        except OSError:
            continue
        n = scan_dir(r, dev, seen, "/")
        nodes[r] = n
        parents[r] = "/"
        root["c"].append(n)
        root["s"] += n["s"]
    root["c"].sort(key=lambda c: -c["s"])
    nodes["/"] = root
    big_files.sort(key=lambda f: -f["s"])
    state.update(scanning=False, took=time.time() - state["started"])


def suggestions():
    out = []
    for path, label, safety, note in SUGGESTIONS:
        p = os.path.expanduser(path)
        if not os.path.exists(p):
            continue
        n = nodes.get(p)
        size = n["s"] if n else 0
        if size < MIN_NODE:
            continue
        out.append({"p": p, "label": label, "safety": safety, "note": note, "s": size})
    out.sort(key=lambda s: -s["s"])
    return out


def can_delete(path):
    rp = os.path.realpath(path)
    if not os.path.lexists(path):
        return "no longer exists"
    if rp in PROTECTED or os.path.realpath(os.path.dirname(rp)) == "/":
        return "protected folder"
    if any(rp == n or rp.startswith(n + "/") for n in NEVER_INSIDE):
        return "protected folder"
    if not any(rp.startswith(os.path.realpath(r) + "/") for r in ROOTS):
        return "outside scanned folders"
    return None


def make_writable_and_retry(func, path, _exc):
    # Go's module cache is read-only; make it writable and try again.
    os.chmod(os.path.dirname(path), 0o700)
    os.chmod(path, 0o700)
    func(path)


def remove_path(path, to_trash):
    if path == os.path.join(HOME, ".Trash"):
        # "Empty Trash": delete its contents, keep the folder.
        for e in os.scandir(path):
            remove_path(e.path, False)
        return
    if to_trash:
        trash = os.path.join(HOME, ".Trash")
        dest = os.path.join(trash, os.path.basename(path))
        if os.path.lexists(dest):
            dest += time.strftime(" %H.%M.%S")
        shutil.move(path, dest)
    elif os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path, onerror=make_writable_and_retry)
    else:
        os.unlink(path)


def drop_node(path, freed):
    """Remove path from the tree and subtract its size from ancestors."""
    node = nodes.pop(path, None)
    p = parents.pop(path, None)
    if node is None:
        return
    if path == os.path.join(HOME, ".Trash"):
        nodes[path] = node
        parents[path] = p
        node["c"], node["o"] = [], 0
    elif p in nodes:
        nodes[p]["c"] = [c for c in nodes[p]["c"] if c["p"] != path]
    while p is not None and p in nodes:
        nodes[p]["s"] = max(0, nodes[p]["s"] - freed)
        p = parents.get(p)
    big_files[:] = [f for f in big_files if f["p"] != path and not f["p"].startswith(path + "/")]


def delete(paths, to_trash):
    # Skip anything whose ancestor is also selected.
    paths = sorted(set(paths), key=len)
    chosen = []
    for p in paths:
        if not any(p.startswith(c + "/") for c in chosen):
            chosen.append(p)
    results = []
    job = state["job"]
    job.update(total=len(chosen), done=0, free_start=disk()["free"], results=results)
    for p in chosen:
        job["current"] = p
        job["done"] = len(results)
        reason = can_delete(p)
        if reason:
            results.append({"p": p, "ok": False, "err": reason})
            continue
        size = nodes[p]["s"] if p in nodes else 0
        try:
            remove_path(p, to_trash)
            with lock:
                drop_node(p, size)
            results.append({"p": p, "ok": True, "s": size})
        except Exception as e:  # noqa: BLE001 - report every failure to the page
            results.append({"p": p, "ok": False, "err": str(e)})
    job.update(running=False, done=len(results), current="")


def job_status():
    job = state["job"]
    out = {k: v for k, v in job.items() if k != "free_start"}
    if "free_start" in job:
        out["freed"] = max(0, disk()["free"] - job["free_start"])
    return out


def disk():
    u = shutil.disk_usage(DATA_VOLUME)
    return {"total": u.total, "used": u.used, "free": u.free}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html"), "rb") as f:
                return self.send(200, f.read(), "text/html; charset=utf-8")
        if path == "/api/status":
            return self.send(200, {**state, "job": job_status(), "disk": disk()})
        if path == "/api/data":
            if state["scanning"]:
                return self.send(409, {"error": "scanning"})
            with lock:
                return self.send(200, {
                    "tree": nodes.get("/"),
                    "files": big_files[:3000],
                    "suggestions": suggestions(),
                    "disk": disk(),
                    "home": HOME,
                })
        self.send(404, {"error": "not found"})

    def do_POST(self):
        # Only accept requests from our own page.
        origin = self.headers.get("Origin", "")
        if origin and origin not in (f"http://127.0.0.1:{PORT}", f"http://localhost:{PORT}"):
            return self.send(403, {"error": "bad origin"})
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        path = urlparse(self.path).path
        if path == "/api/delete":
            if state["job"].get("running"):
                return self.send(409, {"error": "a delete is already running"})
            # Big folders take minutes; run in the background and let the page poll /api/status.
            state["job"] = {"running": True, "trash": bool(body.get("trash")), "results": []}
            threading.Thread(target=delete, args=(body.get("paths", []), bool(body.get("trash"))), daemon=True).start()
            return self.send(200, {"ok": True})
        if path == "/api/rescan":
            if not state["scanning"]:
                threading.Thread(target=run_scan, daemon=True).start()
            return self.send(200, {"ok": True})
        self.send(404, {"error": "not found"})


def main():
    sys.setrecursionlimit(20000)
    threading.Thread(target=run_scan, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    url = f"http://127.0.0.1:{PORT}"
    print(f"Disk cleaner running at {url}  (Ctrl+C to stop)")
    if "--no-open" not in sys.argv:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
