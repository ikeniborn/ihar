"""The explicit-mode gateway: a loopback reverse proxy for model traffic (LLD 8.2).

Explicit mode terminates no TLS, negotiates no ALPN, and serves no client that was
not pointed at it by this harness, so the stdlib server is adequate here and keeps
the protected path free of a heavy dependency.

Failure class: fail-closed per request. An unknown route, an unparseable body, a
compressed body, an oversized body, a payload the masker cannot promise anything
about: each is a refusal with a status, never a relay.

Usage: python3 -m ihar.gateway.explicit --port <n> [--log-dir <d>]
"""

from __future__ import annotations

import argparse
import http.client
import http.server
import json
import os
import socket
import sys
import threading
import time
import urllib.parse
import uuid

from ..mask import shapes
from ..mask.engine import Masker, MaskingUnavailable
from . import limits, log, routes

UPSTREAMS = {
    routes.ANTHROPIC: os.environ.get("IHAR_GATEWAY_ANTHROPIC_UPSTREAM", "https://api.anthropic.com"),
    routes.OPENAI: os.environ.get("IHAR_GATEWAY_OPENAI_UPSTREAM", "https://api.openai.com"),
    routes.CHATGPT: os.environ.get("IHAR_GATEWAY_CHATGPT_UPSTREAM", "https://chatgpt.com"),
}

# Headers the gateway owns; everything else, including the caller's credentials, is
# forwarded untouched. ihar never holds a vendor credential and never rewrites one.
_DROP_REQUEST = {"host", "content-length", "transfer-encoding", "connection",
                 "accept-encoding"}
_DROP_RESPONSE = {"transfer-encoding", "connection", "content-encoding", "content-length"}

_METRICS = {"masked": 0, "refused": 0, "relayed": 0, "started": time.time()}
_METRICS_LOCK = threading.Lock()


def _bump(name: str) -> None:
    with _METRICS_LOCK:
        _METRICS[name] = _METRICS.get(name, 0) + 1


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ihar"
    sys_version = ""

    masker: Masker
    enforced: bool

    def log_message(self, *_):
        """Silence the stdlib access log: it prints the full path, query included."""

    # ------------------------------------------------------------------ #

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_PUT(self):
        self._dispatch("PUT")

    def do_DELETE(self):
        self._dispatch("DELETE")

    # ------------------------------------------------------------------ #

    def _dispatch(self, method: str):
        request_id = uuid.uuid4().hex[:12]
        started = time.time()
        try:
            limits.check_headers(self.headers)
        except limits.TooLarge as reason:
            return self._refuse(request_id, 431, f"headers: {reason}", method)

        kind, upstream = routes.classify(method, self.path, self.headers)

        if kind == routes.LOCAL:
            return self._local(request_id, method)
        if kind == routes.MODEL:
            return self._model(request_id, method, upstream, started)
        if kind == routes.TRANSIT:
            return self._relay(request_id, method, started)

        # Unknown. With masking off there is nothing to protect, so relaying is
        # honest; with masking on, relaying would carry an unexamined model payload.
        if self.masker.level == "off":
            return self._relay(request_id, method, started)
        return self._refuse(request_id, 502, "unknown route", method)

    # ------------------------------------------------------------------ #

    def _read_body(self) -> bytes:
        length = self.headers.get("Content-Length")
        if length is not None:
            size = int(length)
            limits.check_body_length(size)
            return self.rfile.read(size)
        if (self.headers.get("Transfer-Encoding") or "").lower() == "chunked":
            chunks, total = [], 0
            while True:
                line = self.rfile.readline().strip()
                size = int(line.split(b";")[0] or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    break
                total += size
                limits.check_body_length(total)
                chunks.append(self.rfile.read(size))
                self.rfile.readline()
            return b"".join(chunks)
        return b""

    def _model(self, request_id: str, method: str, upstream: str, started: float):
        try:
            body = self._read_body()
        except limits.TooLarge as reason:
            return self._refuse(request_id, 413, str(reason), method)

        encoding = (self.headers.get("Content-Encoding") or "").lower()
        if encoding and encoding != "identity":
            # A compressed body cannot be masked without decompressing it, and
            # decompressing an untrusted stream is its own hazard.
            return self._refuse(request_id, 415, f"content-encoding {encoding}", method)

        try:
            payload = json.loads(body or b"{}")
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            return self._refuse(request_id, 400, f"body not parseable: {error}", method)

        try:
            limits.check_depth(payload)
        except limits.TooLarge as reason:
            return self._refuse(request_id, 413, str(reason), method)

        try:
            masked, kinds = shapes.transform(
                payload, self.masker,
                family=shapes.family_for(self.path), enforced=self.enforced,
            )
        except shapes.Unsupported as reason:
            return self._refuse(request_id, 502, str(reason), method)
        except MaskingUnavailable as reason:
            # The engine that the profile promises could not run on this body. Relaying
            # it masked by something weaker would be the silent degradation this refusal
            # exists to prevent.
            return self._refuse(request_id, 502, str(reason), method)

        outgoing = json.dumps(masked).encode()
        _bump("masked")
        self._forward(request_id, method, UPSTREAMS[upstream], outgoing, started,
                      masked=len(kinds))

    def _relay(self, request_id: str, method: str, started: float):
        try:
            body = self._read_body()
        except limits.TooLarge as reason:
            return self._refuse(request_id, 413, str(reason), method)
        _bump("relayed")
        self._forward(request_id, method, UPSTREAMS[routes.ANTHROPIC], body, started,
                      masked=0)

    def _forward(self, request_id, method, upstream, body, started, *, masked):
        parsed = urllib.parse.urlsplit(upstream)
        connection_class = (http.client.HTTPSConnection if parsed.scheme == "https"
                            else http.client.HTTPConnection)
        connection = connection_class(parsed.netloc, timeout=limits.READ_TIMEOUT)

        headers = {key: value for key, value in self.headers.items()
                   if key.lower() not in _DROP_REQUEST}
        headers["Host"] = parsed.netloc
        headers["Content-Length"] = str(len(body))

        try:
            connection.request(method, self.path, body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read()
        except (OSError, http.client.HTTPException) as error:
            connection.close()
            return self._refuse(request_id, 502, f"upstream: {error}", method)

        self.send_response(response.status)
        for key, value in response.getheaders():
            if key.lower() not in _DROP_RESPONSE:
                self.send_header(key, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        connection.close()

        log.record(request_id=request_id, event="forward", method=method,
                   host=parsed.netloc, path_class=log.path_class(self.path),
                   status=response.status, request_bytes=len(body),
                   response_bytes=len(payload), masked=masked,
                   duration_ms=int((time.time() - started) * 1000))

    def _local(self, request_id: str, method: str):
        body = json.dumps(self._local_body()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("x-ihar-gateway", "1")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _local_body(self) -> dict:
        path = log.path_class(self.path)
        if path == "/api/metrics":
            with _METRICS_LOCK:
                snapshot = dict(_METRICS)
            snapshot["uptime_seconds"] = int(time.time() - snapshot.pop("started"))
            return snapshot
        return {"ok": True, "mode": "explicit", **self.masker.describe()}

    def _refuse(self, request_id: str, status: int, reason: str, method: str):
        _bump("refused")
        body = json.dumps({"error": {"type": "ihar_refused", "message": reason}}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        log.record(request_id=request_id, event="refuse", method=method,
                   host=self.headers.get("Host", ""), path_class=log.path_class(self.path),
                   status=status, refused=1, reason=reason)


def build(port: int, level: str, engine: str, enforced: bool):
    handler = type("BoundHandler", (Handler,), {
        "masker": Masker(level=level, engine=engine),
        "enforced": enforced,
    })
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    server.daemon_threads = True
    return server


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="ihar.gateway.explicit")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--log-dir")
    parser.add_argument("--port-file")
    parser.add_argument("--level", default=os.environ.get("IHAR_GATEWAY_MASKING_LEVEL", "standard"))
    parser.add_argument("--engine", default=os.environ.get("IHAR_GATEWAY_ENGINE", "presidio"))
    parser.add_argument("--enforced", action="store_true")
    args = parser.parse_args(argv)

    log.open_log(args.log_dir)

    # A requested port is a preference, not a requirement. The caller remembers the
    # port an instance last used so that the base_url rendered into the vendor's
    # configuration stays the same across restarts — an ephemeral port every time
    # would change that file, and the runtime home keyed by it would read as drifted
    # on the very next launch. If something else has taken the port meanwhile, an
    # ephemeral one is correct: the home is then genuinely a different configuration.
    try:
        server = build(args.port, args.level, args.engine, args.enforced)
    except OSError as error:
        if args.port == 0:
            print(f"ihar: the gateway cannot bind: {error}", file=sys.stderr)
            return 3
        try:
            server = build(0, args.level, args.engine, args.enforced)
        except OSError as fallback:
            print(f"ihar: the gateway cannot bind: {fallback}", file=sys.stderr)
            return 3

    port = server.server_address[1]
    if args.port_file:
        with open(args.port_file, "w", encoding="utf-8") as handle:
            handle.write(f"{port}\n")

    masker = Masker(level=args.level, engine=args.engine)
    log.record(event="start", port=port, mode="explicit", **masker.describe())
    print(port, flush=True)

    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))


# Referenced so a reader looking for the bind address finds it named rather than
# buried in build(): the gateway is loopback-only by construction, never 0.0.0.0.
BIND_ADDRESS = "127.0.0.1"
assert socket.inet_aton(BIND_ADDRESS)
