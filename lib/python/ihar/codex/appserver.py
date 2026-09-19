"""JSON-RPC clients for the Codex app-server, over stdio and over the daemon socket
(LLD 5.4, 5.5).

Framing, id allocation and the rule that a server-initiated request is declined are
lifted from icodex:lib/profile/app_server.py, which speaks stdio only.

The daemon transport was an open question in LLD 20 — "the `app-server-control` socket
framing over a socket transport against stdio" — and slice S8 measured it against the
pinned 0.154.0 rather than guessing. The answer is that the control socket is a
**WebSocket endpoint carried over a Unix domain socket**: a plain newline-delimited
request gets no reply at all, and an RFC 6455 upgrade request is answered with
`HTTP/1.1 101 Switching Protocols`. After the upgrade the messages are the same JSON
objects the stdio transport exchanges, which is why the protocol below is shared.

`codex app-server proxy` is not a way around that. Its own help says it proxies stdio
*bytes* to the control socket, and measurement agrees: piped a plain JSON-RPC request
it stays alive and answers nothing. The framing belongs to the client either way, so
ihar connects to the socket directly and saves the extra process.

Failure class: the caller's. This module raises; it never decides.
"""

from __future__ import annotations

import base64
import contextlib
import json
import os
import socket
import struct
import subprocess


class AppServerError(RuntimeError):
    pass


class _Protocol:
    """Request and notify over whatever transport the subclass provides.

    A subclass supplies `_send(obj)` and `_recv()`; `_recv` returns one decoded
    message, or None for a frame that carries no message.
    """

    def __init__(self):
        self._next_id = 0

    def _send(self, obj) -> None:
        raise NotImplementedError

    def _recv(self):
        raise NotImplementedError

    def notify(self, method: str, params) -> None:
        self._send({"method": method, "params": params})

    def request(self, method: str, params):
        self._next_id += 1
        request_id = self._next_id
        self._send({"id": request_id, "method": method, "params": params})

        # Bounded: a malformed stream must not hang a launch. Notifications and
        # server-initiated requests arrive interleaved with the answer.
        for _ in range(500):
            message = self._recv()
            if message is None:
                continue
            if message.get("id") == request_id:
                if "error" in message:
                    raise AppServerError(f"{method}: {json.dumps(message['error'])[:300]}")
                return message.get("result")
            if "method" in message and "id" in message:
                # A server-initiated request. ihar answers none of them, and leaving
                # it unanswered would leave the server waiting.
                self._send({"id": message["id"],
                            "error": {"code": -32601, "message": "ihar declines server requests"}})
        raise AppServerError(f"{method}: no answer within the message budget")

    def handshake(self) -> None:
        self.request("initialize", {
            "clientInfo": {"name": "ihar", "title": "ihar", "version": "0"},
        })
        self.notify("initialized", {})


class AppServer(_Protocol):
    """One short-lived `codex app-server` child, used for a handful of requests."""

    def __init__(self, binary: str, home: str, timeout: float = 30.0):
        super().__init__()
        self._binary = binary
        self._home = home
        self._timeout = timeout
        self._proc: subprocess.Popen | None = None

    def __enter__(self):
        env = dict(os.environ, CODEX_HOME=self._home)
        self._proc = subprocess.Popen(
            [self._binary, "app-server"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, text=True, bufsize=1,
        )
        self.handshake()
        return self

    def __exit__(self, *_):
        proc = self._proc
        if proc is None:
            return False
        try:
            if proc.stdin:
                proc.stdin.close()
            proc.wait(timeout=5)
        except (subprocess.TimeoutExpired, OSError):
            proc.kill()
        self._proc = None
        return False

    def _send(self, obj) -> None:
        proc = self._proc
        if proc is None or proc.stdin is None:
            raise AppServerError("the app-server is not running")
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    def _recv(self):
        proc = self._proc
        if proc is None or proc.stdout is None:
            raise AppServerError("the app-server is not running")
        line = proc.stdout.readline()
        if not line:
            stderr = proc.stderr.read() if proc.stderr else ""
            raise AppServerError(f"the app-server closed the stream: {stderr.strip()[:300]}")
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            return None


class DaemonClient(_Protocol):
    """The running daemon, over its control socket.

    Only the frames a JSON-RPC conversation uses are implemented: text, continuation,
    ping and close. Binary frames do not occur, and a client that invented handling
    for them would be asserting something about the protocol that was never measured.
    """

    OP_CONTINUATION, OP_TEXT, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x8, 0x9, 0xA

    def __init__(self, socket_path: str, timeout: float = 30.0):
        super().__init__()
        self._path = socket_path
        self._timeout = timeout
        self._conn: socket.socket | None = None
        self._buffer = b""
        self._partial = b""

    def __enter__(self):
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(self._timeout)
        try:
            conn.connect(self._path)
        except OSError as error:
            conn.close()
            raise AppServerError(f"cannot reach the daemon at {self._path}: {error}") from error
        self._conn = conn
        self._upgrade()
        self.handshake()
        return self

    def __exit__(self, *_):
        if self._conn is not None:
            try:
                self._frame(self.OP_CLOSE, b"")
            except (OSError, AppServerError):
                # A courtesy close on a connection the daemon has already dropped.
                # Failing here would turn a finished conversation into an error.
                pass
            self._conn.close()
            self._conn = None
        return False

    # ----------------------------------------------------------------- #

    def _upgrade(self) -> None:
        key = base64.b64encode(os.urandom(16)).decode()
        self._raw_send(
            "GET / HTTP/1.1\r\n"
            "Host: localhost\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n".encode()
        )
        while b"\r\n\r\n" not in self._buffer:
            self._fill()
        head, _, rest = self._buffer.partition(b"\r\n\r\n")
        status = head.split(b"\r\n", 1)[0]
        if b" 101 " not in status:
            raise AppServerError(f"the daemon refused the upgrade: {status.decode(errors='replace')[:120]}")
        self._buffer = rest

    def _raw_send(self, data: bytes) -> None:
        # Every transport failure leaves as AppServerError. A daemon that goes away
        # mid-conversation otherwise surfaces as a bare BrokenPipeError, which the
        # callers that catch AppServerError do not catch — so a launch would abort
        # with a traceback instead of falling back to a stdio child.
        if self._conn is None:
            raise AppServerError("the daemon connection is closed")
        try:
            self._conn.sendall(data)
        except OSError as error:
            raise AppServerError(f"the daemon connection failed: {error}") from error

    def _fill(self) -> None:
        if self._conn is None:
            raise AppServerError("the daemon connection is closed")
        try:
            chunk = self._conn.recv(65536)
        except OSError as error:
            raise AppServerError(f"the daemon connection failed: {error}") from error
        if not chunk:
            raise AppServerError("the daemon closed the connection")
        self._buffer += chunk

    def _need(self, count: int) -> None:
        while len(self._buffer) < count:
            self._fill()

    def _frame(self, opcode: int, payload: bytes) -> None:
        """One masked client frame. RFC 6455 requires the mask on every client frame,
        and a server is entitled to close the connection on an unmasked one."""
        header = bytearray([0x80 | opcode])
        mask = os.urandom(4)
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", length)
        header += mask
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self._raw_send(bytes(header) + masked)

    def _send(self, obj) -> None:
        self._frame(self.OP_TEXT, json.dumps(obj).encode())

    def _recv(self):
        self._need(2)
        first, second = self._buffer[0], self._buffer[1]
        final = bool(first & 0x80)
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        offset = 2
        if length == 126:
            self._need(4)
            length = struct.unpack(">H", self._buffer[2:4])[0]
            offset = 4
        elif length == 127:
            self._need(10)
            length = struct.unpack(">Q", self._buffer[2:10])[0]
            offset = 10
        key = b""
        if masked:
            self._need(offset + 4)
            key = self._buffer[offset:offset + 4]
            offset += 4
        self._need(offset + length)
        payload = self._buffer[offset:offset + length]
        self._buffer = self._buffer[offset + length:]
        if masked:
            payload = bytes(byte ^ key[index % 4] for index, byte in enumerate(payload))

        if opcode == self.OP_CLOSE:
            raise AppServerError("the daemon closed the connection")
        if opcode == self.OP_PING:
            self._frame(self.OP_PONG, payload)
            return None
        if opcode == self.OP_PONG:
            return None
        if opcode not in (self.OP_TEXT, self.OP_CONTINUATION):
            return None

        self._partial += payload
        if not final:
            return None
        message, self._partial = self._partial, b""
        try:
            return json.loads(message)
        except json.JSONDecodeError:
            return None


def daemon_socket(home: str) -> str:
    """Where the daemon puts its control socket, which is why §2.2 budgets the state
    path: `sun_path` is 108 bytes including the NUL."""
    return os.path.join(home, "app-server-control", "app-server-control.sock")


@contextlib.contextmanager
def connect(binary: str, home: str):
    """The daemon when one is listening, a stdio child otherwise.

    Preferring the daemon is not an optimisation: a stdio child started while a daemon
    holds the same CODEX_HOME opens the same sqlite state, and the point of §5.5 is
    that there is one server per home rather than two.
    """
    path = daemon_socket(home)
    if os.path.exists(path):
        client = DaemonClient(path)
        try:
            client.__enter__()
        except AppServerError:
            client = None
        if client is not None:
            try:
                yield client
            finally:
                client.__exit__()
            return
    with AppServer(binary, home) as server:
        yield server


def hooks_list(binary: str, home: str, cwds: list[str]) -> list[dict]:
    """Every hook the vendor sees for the given directories, with its trust state."""
    with AppServer(binary, home) as server:
        result = server.request("hooks/list", {"cwds": cwds})
    entries = (result or {}).get("data", []) or []
    hooks: list[dict] = []
    for entry in entries:
        for hook in entry.get("hooks", []) or []:
            hooks.append(hook)
    return hooks
