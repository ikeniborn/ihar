"""The console broker: one loopback surface over several ihar sessions (LLD 13.2).

The broker starts launches and serves terminals; it holds no vendor credential, sees no
model payload and stores no conversation. Its token is therefore a local credential of
shell weight, and the three checks below are what bound it: the listener is loopback
only, every request carries the token cookie, and every upgrade carries this origin.

A tab runs the ordinary `ihar` CLI under a pseudo-terminal owned by a detached
supervisor, so profile resolution, store verification, conformance, gateway, sandbox and
daemon reconciliation all happen once, in the code that owns them (LLD 3.3).

Failure class: fail-closed. A non-loopback bind, a second broker or an unwritable token
aborts before the listener exists; a refused cookie, origin, profile or session cap is a
per-request refusal that leaves the rest of the window serving.

Usage: python3 -m ihar.console.broker [--port <n>] [--bind <addr>]
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import http.server
import ipaddress
import json
import os
import re
import secrets
import socket
import socketserver
import subprocess
import sys
import threading
import time
from pathlib import Path

from .. import ids, jsonio
from . import supervisor as sup

MAX_SESSIONS = 8
MAX_BODY = 64 * 1024
_GUID = "258EAFA5-E914-47DA-95CA-5AB0DC85B11F"
_CONFIG_LINE = re.compile(r"^(IHAR_[A-Z0-9_]+)=(.*)$")
# The tab's environment, rebuilt rather than inherited: one shell's AWS_* and
# GITHUB_TOKEN must not follow a cross-project window into every project (LLD 3.4).
_BASE_ENV = ("HOME", "PATH", "TERM", "LANG", "LC_ALL", "SHELL", "USER", "LOGNAME", "TMPDIR")
_PASSED_ROOTS = ("IHAR_ROOT", "IHAR_STORE", "IHAR_STATE_ROOT", "PYTHONPATH")


def _is_loopback(address: str) -> bool:
    try:
        return ipaddress.ip_address(address).is_loopback
    except ValueError:
        return False


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class Broker:
    def __init__(self, state_root: Path, root: Path, max_sessions: int):
        self.root = root
        self.directory = state_root / "console"
        self.sessions = self.directory / "s"
        self.max_sessions = max_sessions
        self.token = secrets.token_urlsafe(32)
        self.port = 0
        # Tabs this broker started. A record is written by its supervisor a moment later,
        # so counting only records would let two quick requests both pass the cap.
        self.spawned: dict[str, subprocess.Popen] = {}

    # --------------------------------------------------------------- startup
    def claim(self) -> None:
        """Refuse a second broker for this user; one window owns the surface."""
        record_path = self.directory / "daemon.json"
        if record_path.is_file():
            try:
                existing = json.loads(record_path.read_text(encoding="utf-8"))
            except ValueError:
                existing = {}
            if _alive(int(existing.get("pid") or 0)):
                raise SystemExit(f"a console broker already runs as pid {existing['pid']}")
        self.directory.mkdir(parents=True, exist_ok=True)
        os.chmod(self.directory, 0o700)
        self.sessions.mkdir(exist_ok=True)
        os.chmod(self.sessions, 0o700)
        token_path = self.directory / "token"
        token_path.write_text(self.token + "\n", encoding="utf-8")
        os.chmod(token_path, 0o600)

    def record(self) -> None:
        receipt = Path(os.environ.get("IHAR_STORE", "")) / "install-receipt.json"
        digest = None
        if receipt.is_file():
            try:
                digest = json.loads(receipt.read_text(encoding="utf-8")).get("release_digest")
            except ValueError:
                digest = None
        jsonio.write("console-daemon", str(self.directory / "daemon.json"), {
            "schema": 1, "pid": os.getpid(), "port": self.port,
            "token_sha256": hashlib.sha256(self.token.encode()).hexdigest(),
            "release_digest": digest,
            "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "max_sessions": self.max_sessions,
        })
        os.chmod(self.directory / "daemon.json", 0o600)

    # ---------------------------------------------------------------- tabs
    def live(self) -> list[dict]:
        out = []
        for path in sorted(self.sessions.glob("*.json")):
            try:
                out.append(json.loads(path.read_text(encoding="utf-8")))
            except ValueError:
                continue
        return out

    def running(self) -> set[str]:
        live = {record["sid"] for record in self.live()
                if record.get("exit_code") is None and _alive(int(record.get("pid") or 0))}
        for sid, process in list(self.spawned.items()):
            if process.poll() is None:
                live.add(sid)
            else:
                self.spawned.pop(sid, None)
        return live

    def profile_of(self, project: Path, requested: str | None) -> str:
        """Resolve the project's profile the way a launch does: flag, file, default."""
        if requested:
            return requested
        config = project / ".ihar_config"
        if config.is_file():
            for line in config.read_text(encoding="utf-8", errors="replace").splitlines():
                match = _CONFIG_LINE.match(line.strip())
                if match and match.group(1) == "IHAR_PROFILE":
                    return match.group(2).strip().strip("\"'")
        return "standard"

    def console_allowed(self, profile: str) -> bool:
        path = self.root / "manifests" / "profiles" / f"{profile}.json"
        if not path.is_file():
            raise FileNotFoundError(profile)
        return jsonio.read("profile", str(path)).get("console") == "allow"

    def cli(self) -> str:
        candidate = self.root / "ihar.sh"
        return str(candidate) if candidate.is_file() else "ihar"

    def tab_environment(self, launch_id: str) -> dict:
        environment = {name: os.environ[name] for name in _BASE_ENV if name in os.environ}
        environment.update({name: os.environ[name] for name in _PASSED_ROOTS
                            if name in os.environ})
        environment.update({name: value for name, value in os.environ.items()
                            if name.startswith("XDG_")})
        environment["IHAR_CONSOLE"] = "1"
        environment["IHAR_CONSOLE_LAUNCH_ID"] = launch_id
        return environment

    def open_tab(self, project: str, vendor: str, requested: str | None) -> dict:
        root = Path(project).resolve()
        if not root.is_dir():
            raise ValueError(f"no such project directory: {project}")
        if vendor not in ("claude", "codex"):
            raise ValueError(f"unknown vendor: {vendor}")
        if len(self.running()) >= self.max_sessions:
            raise RuntimeError(f"the console already runs {self.max_sessions} sessions")
        profile = self.profile_of(root, requested)
        if not self.console_allowed(profile):
            raise PermissionError(f"profile '{profile}' sets console: refuse")
        launch_id = str(ids.uuid7())
        sid = launch_id.replace("-", "")[:12]
        command = [sys.executable, "-m", "ihar.console.supervisor",
                   "--sid", sid, "--record", str(self.sessions / f"{sid}.json"),
                   "--socket", str(self.sessions / f"{sid}.sock"),
                   "--project", str(root), "--vendor", vendor, "--profile", profile,
                   "--launch-id", launch_id, "--", self.cli(), vendor]
        environment = self.tab_environment(launch_id)
        environment["PYTHONPATH"] = os.environ.get("PYTHONPATH", "")
        self.spawned[sid] = subprocess.Popen(
            command, env=environment, start_new_session=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return {"sid": sid, "ihar_id": launch_id, "vendor": vendor, "profile": profile,
                "project_root": str(root)}

    def stop_tab(self, sid: str) -> bool:
        path = self.sessions / f"{sid}.json"
        if not path.is_file():
            return False
        record = json.loads(path.read_text(encoding="utf-8"))
        pid = int(record.get("pid") or 0)
        if pid and _alive(pid):
            os.kill(pid, 15)
        return True


def _ws_send(stream: socket.socket, opcode: int, payload: bytes) -> None:
    header = bytes([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header += bytes([length])
    elif length < 1 << 16:
        header += bytes([126]) + length.to_bytes(2, "big")
    else:
        header += bytes([127]) + length.to_bytes(8, "big")
    stream.sendall(header + payload)


def _ws_read(stream: socket.socket) -> tuple[int, bytes] | None:
    def need(count: int) -> bytes | None:
        data = b""
        while len(data) < count:
            chunk = stream.recv(count - len(data))
            if not chunk:
                return None
            data += chunk
        return data

    head = need(2)
    if head is None:
        return None
    opcode = head[0] & 0x0F
    masked = bool(head[1] & 0x80)
    length = head[1] & 0x7F
    if length == 126:
        extended = need(2)
        length = int.from_bytes(extended or b"\x00\x00", "big")
    elif length == 127:
        extended = need(8)
        length = int.from_bytes(extended or bytes(8), "big")
    if length > MAX_BODY:
        return None
    mask = need(4) if masked else b""
    payload = need(length) or b"" if length else b""
    if masked and mask:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return opcode, payload


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ihar-console"
    sys_version = ""
    broker: Broker

    def log_message(self, format, *args):  # noqa: A002 - the broker keeps no request log
        return

    # ------------------------------------------------------------------ auth
    def cookie_token(self) -> str:
        for part in (self.headers.get("Cookie") or "").split(";"):
            name, _, value = part.strip().partition("=")
            if name == "ihar_console":
                return value
        return ""

    def authorised(self) -> bool:
        return hmac.compare_digest(self.cookie_token(), self.broker.token)

    def same_origin(self) -> bool:
        expected = {f"http://127.0.0.1:{self.broker.port}",
                    f"http://localhost:{self.broker.port}"}
        return (self.headers.get("Origin") or "") in expected

    def reply(self, status: int, body: bytes = b"", kind="text/plain; charset=utf-8",
              extra: dict | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in (extra or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def json_reply(self, status: int, payload: dict) -> None:
        self.reply(status, json.dumps(payload).encode(), "application/json")

    # ------------------------------------------------------------------ GET
    def do_GET(self) -> None:
        path, _, query = self.path.partition("?")
        if path == "/" and query.startswith("t="):
            token = query[2:]
            if not hmac.compare_digest(token, self.broker.token):
                self.reply(401, b"unauthorised\n")
                return
            self.reply(302, b"", extra={
                "Location": "/",
                "Set-Cookie": f"ihar_console={token}; Path=/; HttpOnly; SameSite=Strict",
            })
            return
        if path.startswith("/ws/"):
            self.upgrade(path[4:])
            return
        if not self.authorised():
            self.reply(401, b"unauthorised\n")
            return
        if path == "/":
            self.reply(200, b"ihar console\n", "text/html; charset=utf-8")
        elif path == "/api/state":
            self.json_reply(200, {"schema": 1, "port": self.broker.port,
                                  "max_sessions": self.broker.max_sessions,
                                  "sessions": self.broker.live()})
        else:
            self.reply(404, b"no such route\n")

    # ----------------------------------------------------------------- POST
    def do_POST(self) -> None:
        if not self.authorised():
            self.reply(401, b"unauthorised\n")
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            self.reply(413, b"body too large\n")
            return
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self.reply(400, b"body is not JSON\n")
            return
        if self.path == "/api/tabs":
            self.create_tab(body)
        elif self.path.startswith("/api/tabs/") and self.path.endswith("/stop"):
            sid = self.path[len("/api/tabs/"):-len("/stop")]
            self.json_reply(200 if self.broker.stop_tab(sid) else 404, {"sid": sid})
        else:
            self.reply(404, b"no such route\n")

    def create_tab(self, body: dict) -> None:
        try:
            tab = self.broker.open_tab(body.get("project_root") or "",
                                       body.get("vendor") or "",
                                       body.get("profile"))
        except (PermissionError, jsonio.SchemaError) as error:
            # A profile that refuses the console and a profile whose contract does not
            # validate are the same outcome: the tab does not start. Neither is a bad
            # request, so neither is reported as one.
            self.json_reply(403, {"error": str(error)})
        except RuntimeError as error:
            self.json_reply(409, {"error": str(error)})
        except (ValueError, FileNotFoundError) as error:
            self.json_reply(400, {"error": str(error)})
        else:
            self.json_reply(201, tab)

    # ------------------------------------------------------------ WebSocket
    def upgrade(self, sid: str) -> None:
        if not self.authorised():
            self.reply(401, b"unauthorised\n")
            return
        if not self.same_origin():
            self.reply(403, b"origin refused\n")
            return
        key = self.headers.get("Sec-WebSocket-Key")
        if not key or (self.headers.get("Upgrade") or "").lower() != "websocket":
            self.reply(400, b"not a websocket upgrade\n")
            return
        path = self.broker.sessions / f"{sid}.sock"
        if not path.exists():
            self.reply(404, b"no such tab\n")
            return
        accept = base64.b64encode(hashlib.sha1((key + _GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.bridge(str(path))

    def bridge(self, socket_path: str) -> None:
        """Copy terminal bytes both ways; nothing is buffered here and nothing stored."""
        stream = self.connection
        tab = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            tab.connect(socket_path)
        except OSError:
            _ws_send(stream, 0x8, b"")
            return
        stop = threading.Event()

        def from_tab() -> None:
            pending = b""
            while not stop.is_set():
                try:
                    chunk = tab.recv(65536)
                except OSError:
                    break
                if not chunk:
                    break
                pending += chunk
                while len(pending) >= 5:
                    length = int.from_bytes(pending[1:5], "big")
                    if len(pending) < 5 + length:
                        break
                    kind, payload = pending[0], pending[5:5 + length]
                    pending = pending[5 + length:]
                    try:
                        if kind == sup.OUTPUT:
                            _ws_send(stream, 0x2, payload)
                        elif kind == sup.EXIT:
                            _ws_send(stream, 0x1, json.dumps(
                                {"type": "exit", "code": payload.decode()}).encode())
                    except OSError:
                        stop.set()
                        return
            stop.set()

        reader = threading.Thread(target=from_tab, daemon=True)
        reader.start()
        try:
            while not stop.is_set():
                frame = _ws_read(stream)
                if frame is None:
                    break
                opcode, payload = frame
                if opcode == 0x8:
                    break
                if opcode == 0x9:
                    _ws_send(stream, 0xA, payload)
                    continue
                try:
                    message = json.loads(payload or b"{}")
                except ValueError:
                    continue
                if message.get("type") == "input":
                    tab.sendall(sup._frame(sup.INPUT, str(message.get("data", "")).encode()))
                elif message.get("type") == "resize":
                    cols, rows = int(message.get("cols", 120)), int(message.get("rows", 32))
                    tab.sendall(sup._frame(sup.RESIZE, f"{cols},{rows}".encode()))
        finally:
            stop.set()
            tab.close()


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = False


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=int(os.environ.get("IHAR_CONSOLE_PORT") or 0))
    parser.add_argument("--bind", default="127.0.0.1")
    args = parser.parse_args(argv)

    if not _is_loopback(args.bind):
        print(f"the console binds loopback only; '{args.bind}' is not a loopback address",
              file=sys.stderr)
        return 2
    state_root = os.environ.get("IHAR_STATE_ROOT")
    root = os.environ.get("IHAR_ROOT")
    if not state_root or not root:
        print("the console needs IHAR_STATE_ROOT and IHAR_ROOT", file=sys.stderr)
        return 2
    try:
        cap = int(os.environ.get("IHAR_CONSOLE_MAX_SESSIONS") or MAX_SESSIONS)
    except ValueError:
        print("IHAR_CONSOLE_MAX_SESSIONS must be an integer", file=sys.stderr)
        return 2

    # A detached daemon must not keep its starter's descriptors alive. `ihar console
    # start` runs under a required lock held on one of them, and inheriting it made every
    # later `console stop` time out waiting for a lock whose holder had already exited.
    os.closerange(3, 256)

    broker = Broker(Path(state_root), Path(root), cap)
    try:
        broker.claim()
    except SystemExit as error:
        print(str(error), file=sys.stderr)
        return 3
    handler = type("BoundHandler", (Handler,), {"broker": broker})
    server = Server((args.bind, args.port), handler)
    broker.port = server.server_address[1]
    broker.record()
    print(f"http://127.0.0.1:{broker.port}/?t={broker.token}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        record = broker.directory / "daemon.json"
        if record.is_file():
            record.unlink()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
