"""A stub of the Codex daemon's control socket, for the websocket client.

The real socket is a WebSocket endpoint over a Unix domain socket (LLD 5.4, measured
in slice S8). This speaks the same handshake and frames so the client's masking,
fragment reassembly, ping handling and close handling are exercised without a live
daemon — none of which a stub of the JSON alone would reach.

Usage: ws-appserver.py <socket-path>.  Prints one line per case it proved.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import struct
import sys
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "lib", "python"))

from ihar.codex.appserver import AppServerError, DaemonClient  # noqa: E402

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def server_frame(opcode, payload, final=True):
    """A server frame, which RFC 6455 leaves unmasked."""
    header = bytearray([(0x80 if final else 0x00) | opcode])
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length < 65536:
        header.append(126)
        header += struct.pack(">H", length)
    else:
        header.append(127)
        header += struct.pack(">Q", length)
    return bytes(header) + payload


def read_client_frame(conn, buffer):
    def need(count):
        nonlocal buffer
        while len(buffer) < count:
            chunk = conn.recv(65536)
            if not chunk:
                raise ConnectionError
            buffer += chunk

    need(2)
    opcode = buffer[0] & 0x0F
    masked = buffer[1] & 0x80
    length = buffer[1] & 0x7F
    offset = 2
    if length == 126:
        need(4)
        length = struct.unpack(">H", buffer[2:4])[0]
        offset = 4
    elif length == 127:
        need(10)
        length = struct.unpack(">Q", buffer[2:10])[0]
        offset = 10
    if not masked:
        raise AssertionError("a client frame must be masked")
    need(offset + 4)
    key = buffer[offset:offset + 4]
    offset += 4
    need(offset + length)
    payload = bytes(b ^ key[i % 4] for i, b in enumerate(buffer[offset:offset + length]))
    return opcode, payload, buffer[offset + length:]


def serve(path, results):
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(1)
    conn, _ = listener.accept()
    conn.settimeout(15)
    buffer = b""
    try:
        while b"\r\n\r\n" not in buffer:
            buffer += conn.recv(4096)
        head, _, buffer = buffer.partition(b"\r\n\r\n")
        headers = dict(
            line.split(b": ", 1) for line in head.split(b"\r\n")[1:] if b": " in line
        )
        key = headers[b"Sec-WebSocket-Key"]
        accept = base64.b64encode(hashlib.sha1(key + GUID.encode()).digest()).decode()
        conn.sendall((
            "HTTP/1.1 101 Switching Protocols\r\nconnection: Upgrade\r\n"
            f"upgrade: websocket\r\nsec-websocket-accept: {accept}\r\n\r\n"
        ).encode())
        results.append("upgrade ok")

        # initialize, answered whole.
        opcode, payload, buffer = read_client_frame(conn, buffer)
        request = json.loads(payload)
        conn.sendall(server_frame(1, json.dumps(
            {"id": request["id"], "result": {"codexHome": "/stub"}}).encode()))

        # `initialized` is a notification and carries no id.
        opcode, payload, buffer = read_client_frame(conn, buffer)
        if json.loads(payload).get("method") == "initialized":
            results.append("initialize ok")

        # The next request is answered in two fragments, with a ping in between, so
        # both the continuation path and the ping path are exercised at once.
        opcode, payload, buffer = read_client_frame(conn, buffer)
        request = json.loads(payload)
        body = json.dumps({"id": request["id"], "result": {"data": [], "nextCursor": None}}).encode()
        cut = len(body) // 2
        conn.sendall(server_frame(1, body[:cut], final=False))
        conn.sendall(server_frame(0x9, b"are you there"))
        opcode, payload, buffer = read_client_frame(conn, buffer)
        if opcode == 0xA and payload == b"are you there":
            results.append("ping ok")
        conn.sendall(server_frame(0, body[cut:], final=True))

        # A close frame ends it, and the client must report that rather than hang.
        conn.sendall(server_frame(0x8, b""))
    except (ConnectionError, OSError, KeyError, ValueError) as error:
        results.append(f"server error: {type(error).__name__} {error}")
    finally:
        conn.close()
        listener.close()


def main() -> int:
    path = sys.argv[1]
    results: list[str] = []
    thread = threading.Thread(target=serve, args=(path, results), daemon=True)
    thread.start()

    for _ in range(200):
        if os.path.exists(path):
            break
        threading.Event().wait(0.02)

    with DaemonClient(path, timeout=15) as client:
        result = client.request("thread/list", {"cwd": "/tmp", "limit": 1})
        if result == {"data": [], "nextCursor": None}:
            results.append("fragmented ok")
        # The server has sent a close frame and gone. Whether the client notices while
        # writing or while reading depends on timing, and either way the contract is
        # the same: an AppServerError, never a bare socket exception. A BrokenPipeError
        # escaping here is what the callers that catch AppServerError would miss.
        try:
            client.request("thread/list", {"cwd": "/tmp"})
        except AppServerError:
            results.append("close ok")
        except OSError as error:
            results.append(f"close leaked {type(error).__name__}")

    thread.join(timeout=5)
    for line in results:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
