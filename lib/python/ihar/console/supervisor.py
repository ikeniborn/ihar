"""One console tab: the process that owns its pseudo-terminal (LLD 13.2).

The supervisor exists so a tab outlives the broker. Without it a broker restart would
send `SIGHUP` to every terminal in the window, which is the outcome the daemon decision
was taken to avoid; `ihar update` restarting the broker would then be destructive.

It holds no policy. It opens the pty, execs the ordinary `ihar` CLI so every gate runs
in the code that owns it, keeps a bounded ring buffer in memory, and serves that buffer
plus live output over a Unix socket. Terminal output is never written to disk.

Failure class: runtime. A supervisor that cannot start its terminal exits non-zero and
the broker reports that tab as failed; nothing else in the window is affected.

Usage: python3 -m ihar.console.supervisor --sid <s> --record <f> --socket <f>
                                          --project <d> --vendor <v> --profile <p>
                                          -- <command> [args…]
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import os
import pty
import select
import signal
import socket
import struct
import sys
import termios
import threading
import time

from .. import jsonio

# Output kept for a reattaching browser. In memory only: a file here would be a second
# uncontrolled copy of the transcript, which the session index contract forbids.
RING_BYTES = 256 * 1024
DROPPED_NOTICE = b"\r\n[ihar] earlier output dropped from the buffer\r\n"

# Frame types on the control socket: one byte, then a four-byte big-endian length.
OUTPUT, INPUT, RESIZE, EXIT = 1, 2, 3, 5

# Names the tab must not inherit from the broker: the interpreter path the broker needed
# for itself has no business inside a vendor process.
_CHILD_DROP = ("PYTHONPATH", "IHAR_CONSOLE_MAX_SESSIONS")


def _frame(kind: int, payload: bytes) -> bytes:
    return bytes([kind]) + len(payload).to_bytes(4, "big") + payload


class Ring:
    """Bounded output buffer that says so when it has dropped anything."""

    def __init__(self, limit: int = RING_BYTES):
        self._limit = limit
        self._data = bytearray()
        self._dropped = False
        self._lock = threading.Lock()

    def append(self, chunk: bytes) -> None:
        with self._lock:
            self._data.extend(chunk)
            if len(self._data) > self._limit:
                del self._data[:len(self._data) - self._limit]
                self._dropped = True

    def replay(self) -> bytes:
        with self._lock:
            return (DROPPED_NOTICE if self._dropped else b"") + bytes(self._data)


class Supervisor:
    def __init__(self, args, command: list[str]):
        self.args = args
        self.command = command
        self.ring = Ring()
        self.clients: list[socket.socket] = []
        self.lock = threading.Lock()
        self.master = -1
        self.child = -1

    # ----------------------------------------------------------------- record
    def write_record(self, **changes) -> None:
        record = {
            "schema": 1, "sid": self.args.sid, "ihar_id": self.args.launch_id,
            "kind": "pty", "vendor": self.args.vendor, "project_root": self.args.project,
            "state_id": hashlib.sha256(self.args.project.encode()).hexdigest()[:8],
            "profile": self.args.profile, "pid": os.getpid(), "socket": self.args.socket,
            "started_at": self.started_at, "exit_code": None,
        }
        record.update(changes)
        jsonio.write("console-session", self.args.record, record)
        os.chmod(self.args.record, 0o600)

    # ------------------------------------------------------------------- pty
    def spawn(self) -> None:
        self.child, self.master = pty.fork()
        if self.child == 0:  # pragma: no cover - replaced by exec
            environment = {key: value for key, value in os.environ.items()
                           if key not in _CHILD_DROP}
            os.chdir(self.args.project)
            try:
                os.execvpe(self.command[0], self.command, environment)
            finally:
                os._exit(127)
        self.resize(self.args.cols, self.args.rows)

    def resize(self, cols: int, rows: int) -> None:
        try:
            fcntl.ioctl(self.master, termios.TIOCSWINSZ,
                        struct.pack("HHHH", rows, cols, 0, 0))
        except OSError:
            pass

    # --------------------------------------------------------------- clients
    def broadcast(self, data: bytes) -> None:
        with self.lock:
            for client in list(self.clients):
                try:
                    client.sendall(data)
                except OSError:
                    self.clients.remove(client)

    def serve_client(self, client: socket.socket) -> None:
        try:
            client.sendall(_frame(OUTPUT, self.ring.replay()))
        except OSError:
            return
        with self.lock:
            self.clients.append(client)
        try:
            while True:
                head = self._recv_exactly(client, 5)
                if head is None:
                    return
                kind, length = head[0], int.from_bytes(head[1:], "big")
                payload = self._recv_exactly(client, length) or b""
                if kind == INPUT and self.master >= 0:
                    os.write(self.master, payload)
                elif kind == RESIZE:
                    cols, _, rows = payload.decode(errors="replace").partition(",")
                    if cols.isdigit() and rows.isdigit():
                        self.resize(int(cols), int(rows))
        finally:
            with self.lock:
                if client in self.clients:
                    self.clients.remove(client)
            client.close()

    @staticmethod
    def _recv_exactly(client: socket.socket, count: int) -> bytes | None:
        data = b""
        while len(data) < count:
            try:
                chunk = client.recv(count - len(data))
            except OSError:
                return None
            if not chunk:
                return None
            data += chunk
        return data

    def accept_loop(self, listener: socket.socket) -> None:
        while True:
            try:
                client, _ = listener.accept()
            except OSError:
                return
            threading.Thread(target=self.serve_client, args=(client,), daemon=True).start()

    # ------------------------------------------------------------------- run
    def run(self) -> int:
        self.started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        os.makedirs(os.path.dirname(self.args.socket), mode=0o700, exist_ok=True)
        if os.path.exists(self.args.socket):
            os.unlink(self.args.socket)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.args.socket)
        os.chmod(self.args.socket, 0o600)
        listener.listen(8)
        self.spawn()
        self.write_record()
        threading.Thread(target=self.accept_loop, args=(listener,), daemon=True).start()

        signal.signal(signal.SIGTERM, lambda *_: self._terminate_child())
        while True:
            try:
                ready, _, _ = select.select([self.master], [], [], 0.5)
            except OSError:
                break
            if ready:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError as error:
                    if error.errno in (errno.EIO, errno.EBADF):
                        break
                    continue
                if not chunk:
                    break
                self.ring.append(chunk)
                self.broadcast(_frame(OUTPUT, chunk))
            pid, status = os.waitpid(self.child, os.WNOHANG)
            if pid:
                code = os.waitstatus_to_exitcode(status)
                self.write_record(exit_code=code)
                self.broadcast(_frame(EXIT, str(code).encode()))
                listener.close()
                if os.path.exists(self.args.socket):
                    os.unlink(self.args.socket)
                return 0
        code = os.waitstatus_to_exitcode(os.waitpid(self.child, 0)[1])
        self.write_record(exit_code=code)
        self.broadcast(_frame(EXIT, str(code).encode()))
        listener.close()
        if os.path.exists(self.args.socket):
            os.unlink(self.args.socket)
        return 0

    def _terminate_child(self) -> None:
        if self.child > 0:
            try:
                os.killpg(os.getpgid(self.child), signal.SIGTERM)
            except OSError:
                pass


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    for name in ("sid", "record", "socket", "project", "vendor", "profile", "launch-id"):
        parser.add_argument(f"--{name}", required=True)
    parser.add_argument("--cols", type=int, default=120)
    parser.add_argument("--rows", type=int, default=32)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = [token for token in args.command if token != "--"]
    if not command:
        print("a console tab needs a command to run", file=sys.stderr)
        return 1
    return Supervisor(args, command).run()


if __name__ == "__main__":
    raise SystemExit(main())
