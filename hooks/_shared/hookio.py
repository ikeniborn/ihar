"""Canonical hook input and output for both vendors (LLD 6.2).

Runs under the system interpreter with `python3 -I`, stdlib only: a hook must still
work when the store venv is broken, because a hook that cannot start is enforcement
that is not there.

Failure class is the script's, not this module's. `deny` and `update_input` exit;
everything else returns.

What this absorbs so no script has to know it:

- Codex names the shell tool `Bash` and the edit tool `apply_patch`; Claude sends
  `Bash`, `Edit`, `Write`, `Read`, `Grep` and `mcp__*`.
- The input object is `tool_input` on Claude, and may be `tool_input`, `input` or
  `arguments` on Codex.
- A command is `command` or `cmd`; a path is `file_path`, `path`, `target_file` or
  `notebook_path`, and for a patch it is the `*** Add|Update|Delete File:` headers.
- The Codex output schema is `additionalProperties: false`, so a key neither vendor
  documents is not merely ignored, it is a protocol error.
"""

from __future__ import annotations

import json
import re
import sys

__all__ = [
    "Event", "HookIOError", "read_event", "command_of", "paths_of",
    "text_fields", "set_text", "allow", "deny", "update_input", "context",
]


class HookIOError(RuntimeError):
    """A script tried to emit something the vendor does not accept."""


# Canonical tool names. The value is what a script sees; the key is what a vendor
# may send.
_TOOL_ALIASES = {
    "apply_patch": "Edit",
    "Shell": "Bash",
    "MultiEdit": "Edit",
}

_PATCH_HEADER = re.compile(r"^\*\*\* (?:Add|Update|Delete) File: (.+)$", re.MULTILINE)

_PATH_KEYS = ("file_path", "path", "target_file", "target_path", "notebook_path")
_PATCH_KEYS = ("patch", "input", "content", "text")

# Per tool, the fields whose text a redacting hook may rewrite. `old_string` is
# deliberately absent: it is the anchor an edit matches against, and rewriting it
# would make the edit fail rather than make it safe.
_TEXT_FIELDS = {
    "Bash": ("command", "cmd"),
    "Edit": ("new_string", "content", "patch", "text"),
    "Write": ("content", "patch", "text"),
}


class Event:
    __slots__ = ("vendor", "event", "tool", "raw_tool", "input", "session_id", "cwd", "raw")

    def __init__(self, vendor, event, tool, raw_tool, payload, session_id, cwd, raw):
        self.vendor = vendor
        self.event = event
        self.tool = tool
        self.raw_tool = raw_tool
        self.input = payload
        self.session_id = session_id
        self.cwd = cwd
        self.raw = raw


def _vendor_from(argv, raw):
    for index, token in enumerate(argv):
        if token == "--vendor" and index + 1 < len(argv):
            return argv[index + 1]
        if token.startswith("--vendor="):
            return token.split("=", 1)[1]
    # The flag is rendered into every hook command, so its absence means the manifest
    # and this module disagree. Guessing from the payload would hide that.
    raise HookIOError("no --vendor argument; the hook was not rendered by ihar")


def read_event(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    raw_text = sys.stdin.read()
    try:
        raw = json.loads(raw_text) if raw_text.strip() else {}
    except json.JSONDecodeError as error:
        raise HookIOError(f"stdin is not JSON: {error}") from error

    vendor = _vendor_from(argv, raw)

    raw_tool = raw.get("tool_name") or raw.get("tool") or raw.get("name") or ""
    tool = _TOOL_ALIASES.get(raw_tool, raw_tool)

    payload = raw.get("tool_input")
    if payload is None:
        payload = raw.get("input")
    if payload is None:
        payload = raw.get("arguments")
    if not isinstance(payload, dict):
        payload = {}

    event = raw.get("hook_event_name") or ""
    if not event:
        # Codex omits it on some events; the presence of a response is what
        # distinguishes a post-tool call from a pre-tool one.
        event = "PostToolUse" if "tool_response" in raw else "PreToolUse"

    return Event(
        vendor=vendor,
        event=event,
        tool=tool,
        raw_tool=raw_tool,
        payload=payload,
        session_id=raw.get("session_id") or "",
        cwd=raw.get("cwd") or "",
        raw=raw,
    )


def command_of(event):
    for key in ("command", "cmd"):
        value = event.input.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _patch_text(payload):
    for key in _PATCH_KEYS:
        value = payload.get(key)
        if isinstance(value, str) and "*** " in value:
            return value
    return None


def paths_of(event):
    found = []
    for key in _PATH_KEYS:
        value = event.input.get(key)
        if isinstance(value, str) and value:
            found.append(value)

    patch = _patch_text(event.input)
    if patch:
        found.extend(_PATCH_HEADER.findall(patch))

    for edit in event.input.get("edits") or []:
        if isinstance(edit, dict):
            for key in _PATH_KEYS:
                value = edit.get(key)
                if isinstance(value, str) and value:
                    found.append(value)
    return found


def text_fields(event):
    """(pointer, text) for every field a redacting hook may rewrite."""
    keys = _TEXT_FIELDS.get(event.tool, ())
    found = []
    for key in keys:
        value = event.input.get(key)
        if isinstance(value, str) and value:
            found.append((f"/{key}", value))

    for index, edit in enumerate(event.input.get("edits") or []):
        if not isinstance(edit, dict):
            continue
        for key in ("new_string", "content"):
            value = edit.get(key)
            if isinstance(value, str) and value:
                found.append((f"/edits/{index}/{key}", value))
    return found


def set_text(event, pointer, value):
    parts = [part for part in pointer.split("/") if part]
    target = event.input
    for part in parts[:-1]:
        target = target[int(part)] if part.isdigit() else target[part]
    last = parts[-1]
    if last.isdigit():
        target[int(last)] = value
    else:
        target[last] = value


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #

_ALLOWED_KEYS = {"hookEventName", "permissionDecision", "permissionDecisionReason",
                 "updatedInput", "additionalContext"}


def _emit(event_name, payload):
    unknown = set(payload) - _ALLOWED_KEYS
    if unknown:
        # The Codex schema is additionalProperties: false, so an extra key is a
        # protocol error rather than something the vendor ignores.
        raise HookIOError(f"not an allowed hook output key: {', '.join(sorted(unknown))}")
    body = {"hookSpecificOutput": {"hookEventName": event_name, **payload}}
    json.dump(body, sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()


def allow():
    sys.exit(0)


def deny(event, reason):
    """Block the call. Exit code 2 is the universal block on both vendors; the JSON
    is context for the model, not the decision."""
    print(f"ihar: {reason}", file=sys.stderr)
    _emit(event.event if hasattr(event, "event") else "PreToolUse",
          {"permissionDecision": "deny", "permissionDecisionReason": reason})
    sys.exit(2)


def update_input(event):
    _emit(event.event, {"updatedInput": event.input})
    sys.exit(0)


def context(event, text):
    _emit(event.event, {"additionalContext": text})
    sys.exit(0)
