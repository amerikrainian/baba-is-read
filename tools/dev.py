#!/usr/bin/env python3
"""Drive the running game through the mod's dev server (standard library only).

    uv run python tools/dev.py launch            start the game, wait for the dev server
    uv run python tools/dev.py kill              stop the game
    uv run python tools/dev.py health
    uv run python tools/dev.py eval FILE|-       run a Lua chunk from a file or stdin
    uv run python tools/dev.py eval -e 'return 1+1'
    uv run python tools/dev.py speech [--since N] [--tail N]
    uv run python tools/dev.py log [--tail N] [--grep S]
    uv run python tools/dev.py key enter down down enter   synthetic keys, in order
    uv run python tools/dev.py keys              captured virtual keys
    uv run python tools/dev.py menu              dump of the open menu
    uv run python tools/dev.py state             where the game is (menu, level, cursor)
    uv run python tools/dev.py reload            hot-reload the Lua modules
    uv run python tools/dev.py stdout [--tail N] the game's captured stdout (print output)

Environment: BABA_DIR (game folder), BABA_DEV_PORT (default 8772).
"""

import argparse
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

DEFAULT_GAME = r"C:\Program Files (x86)\Steam\steamapps\common\Baba Is You"
GAME_DIR = Path(os.environ.get("BABA_DIR", DEFAULT_GAME))
PORT = int(os.environ.get("BABA_DEV_PORT", "8772"))
BASE = f"http://127.0.0.1:{PORT}"
DATA_DIR = Path(os.environ.get("LOCALAPPDATA", ".")) / "BabaIsRead"
STDOUT_FILE = DATA_DIR / "stdout.txt"
EXE = "Baba Is You.exe"

VK = {
    "backspace": 8, "tab": 9, "enter": 13, "return": 13, "escape": 27, "esc": 27, "space": 32,
    "pageup": 33, "pagedown": 34, "end": 35, "home": 36,
    "left": 37, "up": 38, "right": 39, "down": 40, "insert": 45, "delete": 46,
    "shift": 16, "ctrl": 17, "alt": 18,
    "semicolon": 186, "equals": 187, "comma": 188, "minus": 189, "period": 190, "slash": 191, "grave": 192,
    "leftbracket": 219, "backslash": 220, "rightbracket": 221, "apostrophe": 222,
}
for i in range(10):
    VK[str(i)] = 48 + i
for i in range(26):
    VK[chr(97 + i)] = 65 + i
for i in range(1, 25):
    VK[f"f{i}"] = 111 + i


def request(path, body=None, timeout=30):
    data = body.encode("utf-8") if isinstance(body, str) else body
    req = urllib.request.Request(BASE + path, data=data, method="POST" if data is not None else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read().decode("utf-8", errors="replace")


def health(quiet=False):
    try:
        status, text = request("/health", timeout=2)
        ok = status == 200 and text.strip() == "ok"
    except (urllib.error.URLError, OSError):
        ok = False
    if not quiet:
        print("ok" if ok else "down")
    return ok


def cmd_launch(args):
    if health(quiet=True):
        print("already running")
        return 0
    exe = GAME_DIR / EXE
    if not exe.exists():
        print(f"game not found at {exe}", file=sys.stderr)
        return 1
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    out = open(STDOUT_FILE, "w", encoding="utf-8")
    subprocess.Popen([str(exe)], cwd=str(GAME_DIR), stdout=out, stderr=subprocess.STDOUT,
                     creationflags=getattr(subprocess, "DETACHED_PROCESS", 0))
    print("launched, waiting for the dev server", end="", flush=True)
    for _ in range(60):
        time.sleep(2)
        if health(quiet=True):
            print(" ready")
            return 0
        print(".", end="", flush=True)
    print(" timeout")
    return 1


def cmd_kill(args):
    subprocess.run(["taskkill.exe", "/F", "/IM", EXE], capture_output=True)
    print("killed")
    return 0


def cmd_eval(args):
    if args.expr is not None:
        chunk = args.expr
    elif args.file == "-" or args.file is None:
        chunk = sys.stdin.read()
    else:
        chunk = Path(args.file).read_text(encoding="utf-8")
    status, text = request(f"/eval?timeout={args.timeout}", chunk, timeout=args.timeout / 1000 + 5)
    print(text)
    return 0 if status == 200 else 1


def cmd_speech(args):
    status, text = request(f"/speech?since={args.since}")
    lines = text.splitlines()
    cursor, rest = lines[0], lines[1:]
    if args.tail:
        rest = rest[-args.tail:]
    print(cursor)
    print("\n".join(rest))
    return 0


def cmd_log(args):
    status, text = request(f"/log?tail={args.tail if not args.grep else 5000}")
    lines = text.splitlines()
    if args.grep:
        needle = args.grep.lower()
        lines = [l for l in lines if needle in l.lower()][-args.tail:]
    print("\n".join(lines))
    return 0


def cmd_key(args):
    for name in args.keys:
        how = "press"
        if ":" in name:
            name, how = name.split(":", 1)
        vk = VK.get(name.lower())
        if vk is None:
            print(f"unknown key {name}", file=sys.stderr)
            return 1
        status, text = request("/key", f"{vk} {how}\n")
        print(f"{name}: {text}")
        time.sleep(args.delay)
    return 0


def cmd_keys(args):
    status, text = request("/keys")
    names = {v: k for k, v in VK.items()}
    for line in text.splitlines():
        if not line.strip() or not line.split()[0].isdigit():
            print(line)
            continue
        vk, mask = (line.split() + ["0"])[:2]
        vk = int(vk)
        combos = [m for m in range(8) if int(mask) >> m & 1]
        words = ["+".join(w for w, bit in (("shift", 1), ("ctrl", 2), ("alt", 4)) if m & bit) or "plain" for m in combos]
        print(vk, names.get(vk, "?"), ", ".join(words))
    return 0


def run_lua(chunk):
    status, text = request("/eval", chunk)
    print(text)
    return 0 if status == 200 else 1


def cmd_menu(args):
    return run_lua("return BabaIsRead.menu.dump()")


def cmd_state(args):
    return run_lua("""
local s = {}
s.menu = editor.strings[MENU]
s.inmenu = generaldata2.values[INMENU]
s.cursor = { editor2.values[MENU_XPOS], editor2.values[MENU_YPOS] }
s.menustack = menu
s.world = generaldata.strings[WORLD]
s.level = generaldata.strings[CURRLEVEL]
s.levelname = generaldata.strings[LEVELNAME]
s.frame = BabaIsRead.frame()
s.bindings = BabaIsRead.input.bindings()
return s
""")


def cmd_reload(args):
    return run_lua("return BabaIsRead.reload()")


def cmd_stdout(args):
    if not STDOUT_FILE.exists():
        print("no stdout capture (game not launched through dev.py)")
        return 1
    lines = STDOUT_FILE.read_text(encoding="utf-8", errors="replace").splitlines()
    print("\n".join(lines[-args.tail:]))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("health").set_defaults(fn=lambda a: 0 if health() else 1)
    sub.add_parser("launch").set_defaults(fn=cmd_launch)
    sub.add_parser("kill").set_defaults(fn=cmd_kill)
    e = sub.add_parser("eval")
    e.add_argument("file", nargs="?")
    e.add_argument("-e", dest="expr")
    e.add_argument("--timeout", type=int, default=10000)
    e.set_defaults(fn=cmd_eval)
    s = sub.add_parser("speech")
    s.add_argument("--since", type=int, default=0)
    s.add_argument("--tail", type=int, default=30)
    s.set_defaults(fn=cmd_speech)
    l = sub.add_parser("log")
    l.add_argument("--tail", type=int, default=40)
    l.add_argument("--grep")
    l.set_defaults(fn=cmd_log)
    k = sub.add_parser("key")
    k.add_argument("keys", nargs="+", help="names like enter, down, f8, a; suffix :down or :up for half presses")
    k.add_argument("--delay", type=float, default=0.4)
    k.set_defaults(fn=cmd_key)
    sub.add_parser("keys").set_defaults(fn=cmd_keys)
    sub.add_parser("menu").set_defaults(fn=cmd_menu)
    sub.add_parser("state").set_defaults(fn=cmd_state)
    sub.add_parser("reload").set_defaults(fn=cmd_reload)
    o = sub.add_parser("stdout")
    o.add_argument("--tail", type=int, default=40)
    o.set_defaults(fn=cmd_stdout)
    args = p.parse_args()
    try:
        return args.fn(args)
    except urllib.error.URLError as ex:
        print(f"dev server unreachable at {BASE}: {ex}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
