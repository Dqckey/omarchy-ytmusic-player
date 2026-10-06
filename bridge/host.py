#!/usr/bin/env python3
"""YouTube Music Player bridge: native messaging host.

Chromium starts this for the "YT Music bar bridge" extension only (see
<browser>/NativeMessagingHosts/ytmusic_player.bridge.json, written by setup.sh). It never runs
anything it's sent; it only:

  * writes the page state the extension reports (song, like status, queue) to
    <state>/state.json for the bar's mini player, and
  * forwards a fixed set of commands from the bar (written one JSON object per
    line to the FIFO <state>/cmd) to the extension.

Allowed commands: like, dislike, shuffle, play {index}, remove {index},
move {index, to}, resume, pause, toggle, next, previous, seek {to seconds},
search {q}, library, pick {list, index, action: play|next|queue},
pickid {playlistId | videoId, action, title}, inspect,
reload (the extension restarts itself to pick up edited scripts).
"""
import json
import os
import stat
import struct
import sys
import threading
import time

STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "ytmusic-player")
STATE = os.path.join(STATE_DIR, "state.json")
INSPECT = os.path.join(STATE_DIR, "inspect.json")
FIFO = os.path.join(STATE_DIR, "cmd")
LOG = os.path.join(STATE_DIR, "commands.log")  # last commands, for debugging
OTHER = os.path.join(STATE_DIR, "other.json")  # when other audio (YouTube) last started
RESULTS = os.path.join(STATE_DIR, "results.json")  # last search / library list
COMMANDS = {"like", "dislike", "shuffle", "play", "remove", "move", "inspect", "reload",
            "resume", "pause", "toggle", "next", "previous", "seek", "volume",
            "search", "library", "pick", "pickid", "artist", "artistplay", "artistsongs",
            "artistsongsplay", "speeddial", "repeat", "radio", "lyrics", "saveto", "saveadd"}
MAX_MESSAGE = 1024 * 1024

out_lock = threading.Lock()


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def send(message):
    data = json.dumps(message).encode()
    with out_lock:
        sys.stdout.buffer.write(struct.pack("<I", len(data)) + data)
        sys.stdout.buffer.flush()


def clean_command(raw):
    """Only pass through known commands with a small integer index."""
    try:
        msg = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(msg, dict) or msg.get("cmd") not in COMMANDS:
        return None
    out = {"cmd": msg["cmd"]}
    if msg["cmd"] in ("play", "remove", "move"):
        index = msg.get("index")
        if not isinstance(index, int) or not 0 <= index < 1000:
            return None
        out["index"] = index
        # The title the bar saw, so the page can refuse if the queue moved.
        if isinstance(msg.get("title"), str):
            out["title"] = msg["title"][:300]
        # YouTube video id of that song (11 chars of [A-Za-z0-9_-]).
        vid = msg.get("id")
        if isinstance(vid, str) and len(vid) == 11 and all(c.isalnum() or c in "-_" for c in vid):
            out["id"] = vid
    if msg["cmd"] == "search":
        q = msg.get("q")
        if not isinstance(q, str) or not q.strip():
            return None
        out = {"cmd": "search", "q": q.strip()[:200]}
        chip = msg.get("chip")
        if isinstance(chip, int) and 0 <= chip < 20:
            out["chip"] = chip
        label = msg.get("chipLabel")
        if isinstance(label, str) and 0 < len(label) <= 40:
            out["chipLabel"] = label
        return out
    if msg["cmd"] == "artist":
        lst, index = msg.get("list"), msg.get("index")
        if lst not in ("search", "library", "artist", "speeddial") or not isinstance(index, int) or not 0 <= index < 1000:
            return None
        return {"cmd": "artist", "list": lst, "index": index}
    if msg["cmd"] == "saveadd":
        pid = msg.get("playlistId")
        if not isinstance(pid, str) or not 2 <= len(pid) <= 80 or not all(c.isalnum() or c in "-_" for c in pid):
            return None
        out = {"cmd": "saveadd", "playlistId": pid}
        if isinstance(msg.get("title"), str):
            out["title"] = msg["title"][:200]
        return out
    if msg["cmd"] == "artistsongsplay":
        mode = msg.get("mode")
        if mode not in ("play", "shuffle"):
            return None
        return {"cmd": "artistsongsplay", "mode": mode}
    if msg["cmd"] == "artistplay":
        mode = msg.get("mode")
        if mode not in ("shuffle", "radio"):
            return None
        return {"cmd": "artistplay", "mode": mode}
    if msg["cmd"] == "pickid":
        # A pinned item, by id: a playlist/album id or an 11-char video id.
        action = msg.get("action", "play")
        if action not in ("play", "next", "queue"):
            return None
        out = {"cmd": "pickid", "action": action}
        pid, vid = msg.get("playlistId"), msg.get("videoId")
        if isinstance(pid, str) and 0 < len(pid) <= 80 and all(c.isalnum() or c in "-_" for c in pid):
            out["playlistId"] = pid
        elif isinstance(vid, str) and len(vid) == 11 and all(c.isalnum() or c in "-_" for c in vid):
            out["videoId"] = vid
        else:
            return None
        if isinstance(msg.get("title"), str):
            out["title"] = msg["title"][:300]
        return out
    if msg["cmd"] == "pick":
        lst, index = msg.get("list"), msg.get("index")
        if lst not in ("search", "library", "artist", "artistsongs", "speeddial") or not isinstance(index, int) or not 0 <= index < 1000:
            return None
        action = msg.get("action", "play")
        if action not in ("play", "next", "queue"):
            return None
        return {"cmd": "pick", "list": lst, "index": index, "action": action}
    if msg["cmd"] == "seek":
        to = msg.get("to")
        if not isinstance(to, (int, float)) or not 0 <= to < 36000:
            return None
        out["to"] = float(to)
        return out
    if msg["cmd"] == "volume":
        to = msg.get("to")
        if not isinstance(to, int) or not 0 <= to <= 100:
            return None
        out["to"] = to
        return out
    if msg["cmd"] == "move":
        to = msg.get("to")
        if not isinstance(to, int) or not 0 <= to < 1000:
            return None
        out["to"] = to
    return out


def log_command(cmd):
    """Keep the last 50 forwarded commands (time + command) for debugging."""
    try:
        lines = open(LOG).read().splitlines()[-49:] if os.path.exists(LOG) else []
        lines.append(time.strftime("%H:%M:%S ") + json.dumps(cmd))
        with open(LOG, "w") as f:
            f.write("\n".join(lines) + "\n")
    except OSError:
        pass


def read_commands():
    if os.path.exists(FIFO) and not stat.S_ISFIFO(os.stat(FIFO).st_mode):
        os.remove(FIFO)
    if not os.path.exists(FIFO):
        os.mkfifo(FIFO, 0o600)
    # O_RDWR keeps the FIFO open between writers, so reads block instead of EOF.
    fd = os.open(FIFO, os.O_RDWR)
    buf = b""
    while True:
        chunk = os.read(fd, 4096)
        if not chunk:
            time.sleep(0.1)
            continue
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            cmd = clean_command(line.decode(errors="replace"))
            if cmd:
                send(cmd)
                log_command(cmd)


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    threading.Thread(target=read_commands, daemon=True).start()
    stdin = sys.stdin.buffer
    while True:
        header = stdin.read(4)
        if len(header) < 4:
            break  # Chromium closed the port
        (length,) = struct.unpack("<I", header)
        if length > MAX_MESSAGE:
            break
        try:
            msg = json.loads(stdin.read(length))
        except ValueError:
            continue
        if not isinstance(msg, dict):
            continue
        if msg.get("type") == "state" and isinstance(msg.get("state"), dict):
            state = msg["state"]
            state["ts"] = time.time()
            write_json(STATE, state)
        elif msg.get("type") == "inspect":
            write_json(INSPECT, msg.get("data"))
        elif msg.get("type") == "results" and isinstance(msg.get("data"), dict):
            data = msg["data"]
            data["ts"] = time.time()
            write_json(RESULTS, data)
        elif msg.get("type") == "other":
            write_json(OTHER, {"ts": time.time()})
    try:
        write_json(STATE, {"ts": 0, "connected": False})
    except OSError:
        pass


if __name__ == "__main__":
    main()
