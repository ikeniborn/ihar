#!/usr/bin/env python3
"""Ordering gate for explicit iwiki Given-When-Then scenarios, both vendors.

Carried from icodex's `gwt-gate.py` (LLD 6.1, plan task S3.3). icodex had the only
implementation, so reunifying it means making it vendor-neutral rather than merging
two: the state moves from `$CODEX_HOME` to the runtime home, which is the same
directory under either vendor, and the tool name is read from the event rather than
from a Codex-shaped payload.

Three roles, selected by the event and the tool:

  PostToolUse  wiki_status        record each domain's effective specification mode
               wiki_spec_context  record that this scenario's context was read
               wiki_update_page   consume the evidence a successful mutation used
  PreToolUse   wiki_update_page   refuse an update that rewrites a scenario whose
                                  context was never read

The mode is taken only from a response the transport makes trustworthy: stdio, or
streamable-http whose `binding_source` is `session`. A substituted primary is not
trusted at all, because the answer then describes a scope nobody selected.

The hook never calls MCP and never writes wiki content. It reads what the session
already saw.

Failure class: fail-soft. State it cannot read or write is skipped with a warning; a
missing context is a refusal, which is the gate working rather than failing.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "_shared"))

import hookio  # noqa: E402
import policy  # noqa: E402

CONTEXT_MAX_AGE_SECONDS = 2 * 60 * 60
STATUS_MAX_AGE_SECONDS = 30 * 60
VALID_MODES = {"disabled", "optional", "strict"}

FENCE_RE = re.compile(r"```iwiki-gwt[ \t]*\n(.*?)```", re.DOTALL)
ID_RE = re.compile(r'^\s*id\s*=\s*"([^"\n]+)"\s*(?:#.*)?$', re.MULTILINE)


def _tool_suffix(name):
    """The bare tool name. Both vendors may send it qualified or plain, and icodex
    matches the bare form alongside the qualified one."""
    return name.rsplit("__", 1)[-1] if isinstance(name, str) else ""


def _state_dir():
    home = policy._runtime_home()
    return os.path.join(home, "state") if home else None


def _path(name):
    directory = _state_dir()
    return os.path.join(directory, name) if directory else None


# --------------------------------------------------------------------------- #
# Reading the vendor's response
# --------------------------------------------------------------------------- #


def _validated(payload):
    """The payload, or None when it reports an error. An errored response says
    nothing about the wiki's state, so recording it would record a guess."""
    if not isinstance(payload, dict):
        return None
    if payload.get("isError") is True or "error" in payload:
        return None
    return payload


def _response_payload(event):
    response = _validated(event.raw.get("tool_response"))
    if response is None:
        return None
    content = response.get("content")
    if content is None:
        return response
    if not isinstance(content, list):
        return None
    candidate = None
    for item in content:
        if not isinstance(item, dict) or item.get("type") != "text":
            continue
        try:
            payload = json.loads(item.get("text", ""))
        except (TypeError, ValueError):
            continue
        if isinstance(payload, dict):
            payload = _validated(payload)
            if payload is None:
                return None
            if candidate is None:
                candidate = payload
    return candidate


# --------------------------------------------------------------------------- #
# State, one file per concern, both under the runtime home
# --------------------------------------------------------------------------- #


def _read(name, prune):
    path = _path(name)
    if not path or not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as stream:
            data = json.load(stream)
    except (OSError, ValueError):
        return {}
    return prune(data) if isinstance(data, dict) else {}


def _write(name, state):
    path = _path(name)
    if not path:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    staging = f"{path}.{os.getpid()}.tmp"
    with open(staging, "w", encoding="utf-8") as stream:
        json.dump(state, stream, sort_keys=True)
    os.replace(staging, path)


def _prune_status(data):
    cutoff = time.time() - STATUS_MAX_AGE_SECONDS
    clean = {}
    for session, domains in data.items():
        if not isinstance(session, str) or not isinstance(domains, dict):
            continue
        kept = {}
        for domain, entry in domains.items():
            if not isinstance(domain, str) or not isinstance(entry, dict):
                continue
            mode, stamp = entry.get("mode"), entry.get("timestamp")
            if mode in VALID_MODES and isinstance(stamp, (int, float)) and stamp >= cutoff:
                kept[domain] = {"mode": mode, "timestamp": stamp}
        if kept:
            clean[session] = kept
    return clean


def _prune_contexts(data):
    cutoff = time.time() - CONTEXT_MAX_AGE_SECONDS
    clean = {}
    for session, entries in data.items():
        if not isinstance(entries, dict):
            continue
        kept = {
            key: stamp for key, stamp in entries.items()
            if isinstance(key, str) and isinstance(stamp, (int, float)) and stamp >= cutoff
        }
        if kept:
            clean[session] = kept
    return clean


def _load_status():
    return _read("gwt-status.json", _prune_status)


def _load_contexts():
    return _read("gwt-contexts.json", _prune_contexts)


class _locked:
    """Exclusive access to one state file while it is read, changed and written.

    Two hook processes of one session can run concurrently, and the update is
    read-modify-write: without the lock one of them writes a state computed before the
    other's change and that change is simply gone.
    """

    def __init__(self, name):
        self.path = _path(name)
        self.stream = None

    def __enter__(self):
        if not self.path:
            return False
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.stream = open(self.path, "a+", encoding="utf-8")
        fcntl.flock(self.stream, fcntl.LOCK_EX)
        return True

    def __exit__(self, *_):
        if self.stream is not None:
            self.stream.close()
        return False


def _key(domain, scenario_id):
    return f"{domain}\0{scenario_id}"


def _scenario_ids(payload):
    body = payload.get("new_body")
    if not isinstance(body, str):
        return []
    return [match.group(1) for fence in FENCE_RE.findall(body) for match in ID_RE.finditer(fence)]


# --------------------------------------------------------------------------- #
# The three post roles
# --------------------------------------------------------------------------- #


def record_status(event):
    payload = _response_payload(event)
    session = event.session_id
    if not session:
        return
    domains = {}
    if isinstance(payload, dict):
        transport = payload.get("transport")
        # Only a transport that proves the scope was chosen here. Under the hosted
        # fallback the answer describes the token's own grants, which is a different
        # scope from the one this session bound.
        trusted = transport == "stdio" or (
            transport == "streamable-http" and payload.get("binding_source") == "session"
        )
        if trusted and payload.get("primary_substituted") is not True:
            specifications = payload.get("specifications")
            rows = specifications.get("domains") if isinstance(specifications, dict) else None
            if isinstance(rows, list):
                stamp = int(time.time())
                for row in rows:
                    if not isinstance(row, dict):
                        continue
                    domain, mode = row.get("domain"), row.get("mode")
                    if isinstance(domain, str) and domain and mode in VALID_MODES:
                        domains[domain] = {"mode": mode, "timestamp": stamp}
    with _locked("gwt-status.json") as held:
        if not held:
            return
        state = _load_status()
        state.pop(session, None)
        if domains:
            state[session] = domains
        _write("gwt-status.json", state)


def record_context(event):
    if _response_payload(event) is None:
        return
    session = event.session_id
    domain = event.input.get("domain")
    scenario_id = event.input.get("scenario_id")
    if not all(isinstance(value, str) and value for value in (session, domain, scenario_id)):
        return
    with _locked("gwt-contexts.json") as held:
        if not held:
            return
        state = _load_contexts()
        state.setdefault(session, {})[_key(domain, scenario_id)] = int(time.time())
        _write("gwt-contexts.json", state)


def consume_context(event):
    if _response_payload(event) is None:
        return
    session = event.session_id
    domain = event.input.get("domain")
    scenario_ids = _scenario_ids(event.input)
    if not session or not domain or not scenario_ids:
        return
    with _locked("gwt-contexts.json") as held:
        if not held:
            return
        state = _load_contexts()
        entries = state.get(session, {})
        for scenario_id in scenario_ids:
            entries.pop(_key(domain, scenario_id), None)
        if entries:
            state[session] = entries
        else:
            state.pop(session, None)
        _write("gwt-contexts.json", state)


# --------------------------------------------------------------------------- #
# The pre role
# --------------------------------------------------------------------------- #


def check_context(event):
    scenario_ids = _scenario_ids(event.input)
    if not scenario_ids:
        hookio.allow()
    domain = event.input.get("domain")
    session = event.session_id

    entry = _load_status().get(session or "", {}).get(domain if isinstance(domain, str) else "")
    mode = entry.get("mode") if isinstance(entry, dict) else None
    if mode is None:
        hookio.deny(event, (
            f"GWT gate: call wiki_bind and wiki_status for domain {domain!r} before "
            f"mutating an iwiki-gwt scenario."
        ))
    if mode == "disabled":
        hookio.allow()

    entries = _load_contexts().get(session, {}) if session else {}
    if not any(key.startswith(f"{domain}\0") for key in entries):
        # No context at all for this domain: the scenarios may be new, and a create
        # path needs no prior read. Say so rather than refuse a legitimate first write.
        hookio.context(event, (
            f"GWT update carries scenario ID(s) {', '.join(scenario_ids)} in domain "
            f"{domain!r} and the hook cannot tell whether they already exist. Call "
            f"wiki_spec_context before mutating an existing scenario; an ordinary "
            f"create path needs none."
        ))

    missing = [sid for sid in scenario_ids if _key(domain, sid) not in entries]
    if missing:
        hookio.deny(event, (
            f"GWT gate: call wiki_spec_context for domain {domain!r} and scenario "
            f"ID(s) {', '.join(missing)} before updating the existing scenario."
        ))
    hookio.allow()


POST_ROLES = {
    "wiki_status": record_status,
    "wiki_spec_context": record_context,
    "wiki_update_page": consume_context,
}


def main():
    post = "--post" in sys.argv[1:]
    try:
        event = hookio.read_event()
    except Exception:
        return 0

    tool = _tool_suffix(event.raw_tool)
    try:
        if post or event.event == "PostToolUse":
            role = POST_ROLES.get(tool)
            if role is not None:
                role(event)
        elif tool == "wiki_update_page":
            check_context(event)
    except SystemExit:
        raise
    except Exception as error:
        print(f"ihar: gwt-gate: {error}; continuing (fail-soft)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
