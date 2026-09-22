#!/usr/bin/env python3
"""A fake ACP agent, speaking the protocol measured from @zed-industries/agent-client-protocol.

It exists so the console's chat tab can be exercised without a vendor adapter, an account or
a network: newline-delimited JSON-RPC 2.0 on stdio, `initialize`, `session/new`,
`session/prompt`, one `session/update` notification per chunk, and one
`session/request_permission` so the tab's held-permission path is covered.
"""

import json
import sys


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def update(session_id, payload):
    send({"jsonrpc": "2.0", "method": "session/update",
          "params": {"sessionId": session_id, "update": payload}})


def main() -> int:
    session_id = "fake-session-1"
    pending_prompt = None
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        message = json.loads(line)
        method = message.get("method")
        identifier = message.get("id")

        if method == "initialize":
            send({"jsonrpc": "2.0", "id": identifier,
                  "result": {"protocolVersion": 1,
                             "agentCapabilities": {"loadSession": False},
                             "authMethods": []}})
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": identifier, "result": {"sessionId": session_id}})
        elif method == "session/prompt":
            pending_prompt = identifier
            update(session_id, {"sessionUpdate": "agent_thought_chunk",
                                "content": {"type": "text", "text": "thinking about it"}})
            update(session_id, {"sessionUpdate": "agent_message_chunk",
                                "content": {"type": "text", "text": "here is the answer"}})
            # Ask for permission and wait: the console must not answer this by itself.
            send({"jsonrpc": "2.0", "id": 9001, "method": "session/request_permission",
                  "params": {"sessionId": session_id,
                             "toolCall": {"toolCallId": "call-1", "title": "write a file",
                                          "kind": "edit", "status": "pending"},
                             "options": [{"optionId": "allow", "name": "Allow",
                                          "kind": "allow_once"},
                                         {"optionId": "reject", "name": "Reject",
                                          "kind": "reject_once"}]}})
            # A capability the console refuses, so the refusal path is covered too.
            send({"jsonrpc": "2.0", "id": 9002, "method": "fs/read_text_file",
                  "params": {"sessionId": session_id, "path": "/etc/passwd"}})
        elif method == "session/cancel":
            if pending_prompt is not None:
                send({"jsonrpc": "2.0", "id": pending_prompt,
                      "result": {"stopReason": "cancelled"}})
                pending_prompt = None
        elif identifier is not None and "result" in message:
            # The console answered the permission request; finish the turn with what it said.
            outcome = (message.get("result") or {}).get("outcome") or {}
            update(session_id, {"sessionUpdate": "tool_call_update",
                                "toolCallId": "call-1",
                                "status": "completed" if outcome.get("outcome") == "selected"
                                          else "failed"})
            if pending_prompt is not None:
                send({"jsonrpc": "2.0", "id": pending_prompt,
                      "result": {"stopReason": "end_turn"}})
                pending_prompt = None
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
