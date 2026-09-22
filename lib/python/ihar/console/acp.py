"""The console's Agent Client Protocol client (LLD 13.3, plan task S13.1).

Measured, not recalled: `@zed-industries/agent-client-protocol` 0.4.5 was read before this
was written. The transport is newline-delimited JSON-RPC 2.0 over stdio (`dist/stream.js`),
the protocol version constant is `1`, the client-to-agent methods are `initialize`,
`authenticate`, `session/new`, `session/load`, `session/prompt`, `session/cancel`,
`session/set_mode` and `session/set_model`, and the agent answers with the `session/update`
notification plus `session/request_permission`, `fs/*` and `terminal/*` requests.

Two decisions are security-relevant and deliberate:

* **The console declares no client capabilities.** `fs/read_text_file`, `fs/write_text_file`
  and every `terminal/*` method are refused with JSON-RPC "method not found", because an
  agent that already runs locally with its own tools has no need to use the browser window
  as a second filesystem, and a client that offers one is offering an unaudited path.
* **A permission request is never answered by this process.** It is surfaced to the user and
  left pending until they choose, because an automatic answer would be an approval nobody
  gave. A cancelled turn answers `cancelled`, which the protocol requires.

Failure class: fail-soft. The tab reports what the agent said and what it could not do; a
protocol error ends that tab and never the window.
"""

from __future__ import annotations

import json
import subprocess
import threading
import time

PROTOCOL_VERSION = 1
# Refused rather than implemented; see the module docstring.
CLIENT_CAPABILITIES = {"fs": {"readTextFile": False, "writeTextFile": False},
                       "terminal": False}
METHOD_NOT_FOUND = -32601


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class AcpClient:
    """One ACP conversation with one agent process.

    Events are handed to `emit` as plain dictionaries, one per line on the wire, so the
    supervisor can keep them in the same ring buffer a terminal tab uses and a reattaching
    browser replays the conversation exactly as it arrived.
    """

    def __init__(self, command: list[str], cwd: str, environment: dict, emit):
        self.command = command
        self.cwd = cwd
        self.environment = environment
        self.emit = emit
        self.process: subprocess.Popen | None = None
        self.session_id: str | None = None
        self._next_id = 0
        self._pending: dict[int, str] = {}
        self._permissions: dict[str, object] = {}
        self._lock = threading.Lock()

    # ------------------------------------------------------------- transport
    def start(self) -> None:
        self.process = subprocess.Popen(
            self.command, cwd=self.cwd, env=self.environment,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1)
        threading.Thread(target=self._read_loop, daemon=True).start()
        threading.Thread(target=self._stderr_loop, daemon=True).start()
        self._request("initialize", {"protocolVersion": PROTOCOL_VERSION,
                                     "clientCapabilities": CLIENT_CAPABILITIES})

    def _send(self, message: dict) -> None:
        if not self.process or not self.process.stdin:
            return
        with self._lock:
            try:
                self.process.stdin.write(json.dumps(message) + "\n")
                self.process.stdin.flush()
            except (OSError, ValueError):
                self.emit({"type": "error", "at": _now(),
                           "text": "the agent's input stream closed"})

    def _request(self, method: str, params: dict) -> int:
        self._next_id += 1
        identifier = self._next_id
        self._pending[identifier] = method
        self._send({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params})
        return identifier

    def _read_loop(self) -> None:
        assert self.process and self.process.stdout
        for line in self.process.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except ValueError:
                self.emit({"type": "error", "at": _now(), "text": f"unparseable line: {line[:200]}"})
                continue
            self._dispatch(message)
        code = self.process.wait() if self.process else 0
        self.emit({"type": "exit", "at": _now(), "code": code})

    def _stderr_loop(self) -> None:
        assert self.process and self.process.stderr
        for line in self.process.stderr:
            if line.strip():
                self.emit({"type": "agent-stderr", "at": _now(), "text": line.rstrip()})

    # -------------------------------------------------------------- dispatch
    def _dispatch(self, message: dict) -> None:
        if "method" in message and "id" in message:
            self._agent_request(message)
        elif "method" in message:
            self._notification(message)
        elif "id" in message:
            self._response(message)

    def _notification(self, message: dict) -> None:
        if message.get("method") != "session/update":
            return
        params = message.get("params") or {}
        update = params.get("update") or {}
        self.emit({"type": "update", "at": _now(), "kind": update.get("sessionUpdate"),
                   "update": update})

    def _agent_request(self, message: dict) -> None:
        method = message.get("method")
        identifier = message.get("id")
        params = message.get("params") or {}
        if method == "session/request_permission":
            # Held, not answered: the user decides, and the tab shows what for.
            self._permissions[str(identifier)] = params
            self.emit({"type": "permission", "at": _now(), "request_id": identifier,
                       "tool_call": params.get("toolCall"), "options": params.get("options")})
            return
        # Everything else the agent may ask a client for is refused by capability.
        self._send({"jsonrpc": "2.0", "id": identifier,
                    "error": {"code": METHOD_NOT_FOUND,
                              "message": f"the ihar console offers no '{method}'"}})
        self.emit({"type": "refused", "at": _now(), "method": method})

    def _response(self, message: dict) -> None:
        method = self._pending.pop(message.get("id"), "")
        if "error" in message:
            self.emit({"type": "error", "at": _now(), "method": method,
                       "text": json.dumps(message["error"])})
            return
        result = message.get("result") or {}
        if method == "initialize":
            self.emit({"type": "initialized", "at": _now(),
                       "protocol_version": result.get("protocolVersion"),
                       "agent_capabilities": result.get("agentCapabilities"),
                       "auth_methods": result.get("authMethods")})
            self._request("session/new", {"cwd": self.cwd, "mcpServers": []})
        elif method == "session/new":
            self.session_id = result.get("sessionId")
            self.emit({"type": "session", "at": _now(), "session_id": self.session_id})
        elif method == "session/prompt":
            self.emit({"type": "turn-end", "at": _now(), "stop_reason": result.get("stopReason")})
        else:
            self.emit({"type": "result", "at": _now(), "method": method, "result": result})

    # --------------------------------------------------------------- the UI
    def prompt(self, text: str) -> None:
        if not self.session_id:
            self.emit({"type": "error", "at": _now(), "text": "the session is not ready yet"})
            return
        self.emit({"type": "update", "at": _now(), "kind": "user_message_chunk",
                   "update": {"sessionUpdate": "user_message_chunk",
                              "content": {"type": "text", "text": text}}})
        self._request("session/prompt", {"sessionId": self.session_id,
                                         "prompt": [{"type": "text", "text": text}]})

    def cancel(self) -> None:
        if not self.session_id:
            return
        self._send({"jsonrpc": "2.0", "method": "session/cancel",
                    "params": {"sessionId": self.session_id}})
        # The protocol requires every pending permission request to be answered
        # `cancelled` once a turn is cancelled.
        for identifier in list(self._permissions):
            self.answer(identifier, None)

    def answer(self, request_id: str, option_id: str | None) -> None:
        """Answer one permission request with the user's choice, or with `cancelled`."""
        if request_id not in self._permissions:
            return
        self._permissions.pop(request_id, None)
        outcome = ({"outcome": "cancelled"} if option_id is None
                   else {"outcome": "selected", "optionId": option_id})
        self._send({"jsonrpc": "2.0", "id": int(request_id),
                    "result": {"outcome": outcome}})
        self.emit({"type": "permission-answered", "at": _now(),
                   "request_id": request_id, "option_id": option_id})

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
