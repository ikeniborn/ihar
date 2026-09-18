#!/usr/bin/env python3
"""The one security decision on PreToolUse (LLD 6.1, 6.3).

Failure class: fail-closed. Any exception ends in a denial, because a security hook
that crashed has not decided anything and letting the call through would be a
decision nobody made.

One hook, not three. Codex runs the matching command hooks of a single event
concurrently, so two hooks that both return `updatedInput` race and one rewrite is
silently lost. Path checking, secret detection, redaction and MCP input policy
therefore happen here, in this order, and exactly one of allow, deny or update is
emitted.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "_shared"))

import hookio      # noqa: E402
import patterns    # noqa: E402
import policy      # noqa: E402


def _under(path: str, directory: str) -> bool:
    try:
        return os.path.commonpath([os.path.abspath(path), directory]) == directory
    except ValueError:
        return False


def decide(event, active):
    # 1. Writing into the trusted store, the state root or a runtime home. Pinning a
    #    hook by digest is checked at launch; without this an agent could rewrite the
    #    hook between two calls and the next one would run its version.
    protected = policy.protected_paths(active)
    if protected and event.tool in ("Edit", "Write"):
        for path in hookio.paths_of(event):
            for directory in protected:
                if _under(path, directory):
                    hookio.deny(event, f"{path} is inside {directory}, which agents may not write")

    # 2. Reading or writing a credential path.
    for path in hookio.paths_of(event):
        reason = patterns.is_sensitive_path(path)
        if reason:
            hookio.deny(event, reason)

    command = hookio.command_of(event)
    if command:
        for token in _path_tokens(command):
            reason = patterns.is_sensitive_path(token)
            if reason:
                hookio.deny(event, f"the command touches {reason}")

    # 3. Redaction. A secret in an argument is rewritten rather than refused: the
    #    call is usually legitimate and the value is not.
    level = policy.masking_level(active)
    if level == "off":
        hookio.allow()

    # 3a. MCP is a second egress channel, not a tool call that stays on this machine:
    #     a registered server sends whatever it is given, wherever it points. The
    #     model egress gateway never sees that traffic, so this is the only content
    #     check on it (LLD 7.3).
    if event.raw_tool.startswith("mcp__"):
        masked, kinds = _redact_tree(event.input)
        if kinds:
            event.input.clear()
            event.input.update(masked)
            print(f"ihar: masked {', '.join(sorted(set(kinds)))} in an MCP call",
                  file=sys.stderr)
            hookio.update_input(event)
        hookio.allow()

    rewrote = False
    kinds: list[str] = []
    for pointer, text in hookio.text_fields(event):
        masked, found = patterns.redact(text)
        if found:
            hookio.set_text(event, pointer, masked)
            kinds.extend(found)
            rewrote = True

    if rewrote:
        print(f"ihar: masked {', '.join(sorted(set(kinds)))}", file=sys.stderr)
        hookio.update_input(event)

    hookio.allow()


def _redact_tree(value, kinds=None):
    """Mask every string anywhere in an MCP argument tree.

    An MCP tool's arguments have no schema this hook knows, so there is no field list
    to work from the way there is for a shell command or a file write. Every string
    is therefore scanned: under-scanning here would leave the one egress channel the
    gateway cannot see unchecked.
    """
    kinds = [] if kinds is None else kinds
    if isinstance(value, str):
        masked, found = patterns.redact(value)
        kinds.extend(found)
        return masked, kinds
    if isinstance(value, list):
        out = []
        for item in value:
            masked, kinds = _redact_tree(item, kinds)
            out.append(masked)
        return out, kinds
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            masked, kinds = _redact_tree(item, kinds)
            out[key] = masked
        return out, kinds
    return value, kinds


def _path_tokens(command: str):
    """Path-like tokens of a shell command, split the way a shell would."""
    import shlex
    try:
        tokens = shlex.split(command)
    except ValueError:
        # An unbalanced quote means the command cannot be parsed. Scanning the raw
        # text would produce nonsense, so the whole string is offered as one token
        # and the path patterns decide.
        tokens = [command]
    for token in tokens:
        if token.startswith(("/", "~/", "./", "../")) or ".env" in token or "/." in token:
            yield token


def main():
    try:
        event = hookio.read_event()
    except hookio.HookIOError as error:
        # There is no event object yet, so the denial is emitted by hand.
        print(f"ihar: {error}", file=sys.stderr)
        sys.exit(2)

    try:
        active = policy.load(event)
        decide(event, active)
    except SystemExit:
        raise
    except Exception as error:                      # noqa: BLE001
        hookio.deny(event, f"the security hook failed and cannot allow the call: {error}")


if __name__ == "__main__":
    main()
