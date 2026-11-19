#!/usr/bin/env python3
"""Live end-to-end check: drives real Claude Code (Haiku) in a pty against the built permission hook.
The child runs with --setting-sources "" so only the temp --settings file applies (an installed
real hook in ~/.claude/settings.json must not also connect to the fake panel).
Run: scripts/build.sh hook && python3 -I scripts/live-test.py"""
import fcntl, json, os, pty, re, select, shutil, signal, socket, struct, sys, tempfile, termios, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(ROOT, "build", "huddle-permission-hook")
WORK = os.path.join(ROOT, "build", "live-work")
PROMPT = "Use the Write tool to create a file named t.txt containing hi. Do nothing else."
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][0-9A-B]|\x1b[=>78]")


class Panel:
    """Fake panel: JSON lines over a Unix socket. mode: allow | deny | never | None (no socket)."""
    def __init__(self, path, mode):
        self.path, self.mode = path, mode
        self.requests, self.closed_at, self.srv = [], None, None
        if mode is None:
            return
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path); self.srv.listen(4)
        threading.Thread(target=self.loop, daemon=True).start()

    def loop(self):
        while True:
            try: c, _ = self.srv.accept()
            except OSError: return
            threading.Thread(target=self.handle, args=(c,), daemon=True).start()

    def handle(self, c):
        buf = b""
        while b"\n" not in buf:
            d = c.recv(65536)
            if not d: return
            buf += d
        req = json.loads(buf.split(b"\n")[0])
        self.requests.append(req)
        if self.mode in ("allow", "deny"):
            if self.mode == "allow": time.sleep(2)
            c.sendall((json.dumps({"type": "decision", "id": req["id"], "behavior": self.mode}) + "\n").encode())
            c.close()
        else:
            while c.recv(4096): pass          # wait for the hook to hang up
            self.closed_at = time.time()

    def stop(self):
        if self.srv: self.srv.close()


class Claude:
    def __init__(self, env, settings):
        self.buf = ""
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(WORK)
            try:
                os.execvpe("claude", ["claude", "--model", "haiku", "--permission-mode", "default",
                                      "--setting-sources", "", "--settings", settings], env)
            except BaseException:
                os._exit(127)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 130, 0, 0))

    def pump(self, sec):
        end = time.time() + sec
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.2)
            if r:
                try: data = os.read(self.fd, 65536)
                except OSError: return
                self.buf += ANSI.sub("", re.sub(r"\x1b\[\d*C", " ", data.decode("utf-8", "replace")))

    def squashed(self, tail=20000): return re.sub(r"\s+", "", self.buf[-tail:])

    def wait_for(self, pat, sec):
        end = time.time() + sec
        while time.time() < end:
            self.pump(0.5)
            if re.search(pat, self.squashed(), re.I): return True
        return False

    def send(self, s): os.write(self.fd, s.encode())

    def start(self):
        if self.wait_for(r"Itrustthisfolder", 20):
            self.send("\x1b[B"); self.pump(1); self.send("\r")
        self.wait_for(r"forshortcuts|\?for", 30)
        self.pump(5)
        self.buf = ""
        self.send(PROMPT); self.pump(1); self.send("\r")

    def kill(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try: os.killpg(self.pid, sig)
            except OSError: pass
            time.sleep(0.5)
        try: os.waitpid(self.pid, os.WNOHANG)
        except OSError: pass
        try: os.close(self.fd)
        except OSError: pass


def wait_file(path, sec, c):
    end = time.time() + sec
    while time.time() < end:
        if os.path.exists(path): return True
        c.pump(0.5)
    return os.path.exists(path)


def scenario(n, mode, hdir, settings, env):
    name = {1: "Allow", 2: "Deny", 3: "Answered in Terminal", 4: "Panel not running"}[n]
    tfile = os.path.join(WORK, "t.txt")
    if os.path.exists(tfile): os.remove(tfile)
    sock = os.path.join(hdir, "huddle.sock")
    if os.path.exists(sock): os.remove(sock)
    panel = c = None
    detail = ""
    try:
        panel = Panel(sock, mode)
        c = Claude(env, settings)
        c.start()
        dialog = c.wait_for(r"Doyouwant|wantto(create|make)|1\.Yes", 60)
        if n == 1:
            ok = wait_file(tfile, 40, c)
            c.pump(2)
            shown = "AllowedbyPermissionRequesthook" in c.squashed()
            ok = ok and shown and len(panel.requests) == 1
            detail = f"t.txt={os.path.exists(tfile)} allowed-text={shown} requests={len(panel.requests)}"
        elif n == 2:
            c.pump(15)
            gone = not os.path.exists(tfile)
            sq = c.squashed()
            denied = "DeniedfromAgentHuddle" in sq or "Rejectedwritetot.txt" in sq
            marks = [sq.rfind(m) for m in ("DeniedfromAgentHuddle", "Rejectedwritetot.txt")]
            after = sq[max(marks) + 1:] if max(marks) >= 0 else ""
            back = bool(re.search(r"forshortcuts|\?for|manualmodeon", after))
            ok = gone and len(panel.requests) == 1 and denied and back
            detail = f"no t.txt={gone} denial-text={denied} prompt-back={back} requests={len(panel.requests)}"
        elif n == 3:
            if not dialog: raise RuntimeError("no dialog")
            c.pump(2)
            if panel.closed_at is not None: raise RuntimeError("hook hung up before Enter")
            t_enter = time.time(); c.send("\r")
            ok = wait_file(tfile, 30, c)
            c.pump(3)
            dt = (panel.closed_at - t_enter) if panel.closed_at else None
            ok = ok and dt is not None and 0 <= dt <= 2 and len(panel.requests) == 1
            detail = f"t.txt={os.path.exists(tfile)} close-after-enter={dt if dt is None else round(dt, 2)}s requests={len(panel.requests)}"
        else:
            if not dialog: raise RuntimeError("no dialog")
            c.pump(2)
            c.send("\r")
            ok = wait_file(tfile, 30, c)
            detail = f"dialog={dialog} t.txt={os.path.exists(tfile)} (no socket, no panel)"
    except Exception as e:
        ok, detail = False, repr(e) + " TAIL=" + repr(c.buf[-600:])
    finally:
        if c: c.kill()
        if panel: panel.stop()
    print(("PASS" if ok else "FAIL"), f"scenario {n} {name}: {detail}", flush=True)
    return ok


def main():
    if not os.access(HOOK, os.X_OK): sys.exit("build the hook first: scripts/build.sh hook")
    os.makedirs(WORK, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="ah.", dir="/tmp")
    settings = os.path.join(tmp, "settings.json")
    json.dump({"hooks": {"PermissionRequest": [{"matcher": "*", "hooks": [
        {"type": "command", "command": HOOK, "timeout": 3600}]}]}}, open(settings, "w"))
    env = {k: v for k, v in os.environ.items() if not (k.startswith("CLAUDE_CODE_") or k.startswith("CLAUDECODE"))}
    env.update(TERM="xterm-256color", TERM_PROGRAM="Apple_Terminal", AGENT_HUDDLE_DIR=tmp)
    env.pop("AGENT_HUDDLE_SESSIONS_DIR", None)
    results = []
    try:
        for n, mode in ((1, "allow"), (2, "deny"), (3, "never"), (4, None)):
            results.append(scenario(n, mode, tmp, settings, env))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        try: os.remove(os.path.join(WORK, "t.txt"))
        except OSError: pass
    print("LIVE TEST PASS" if all(results) else "LIVE TEST FAIL")
    sys.exit(0 if all(results) else 1)


main()
