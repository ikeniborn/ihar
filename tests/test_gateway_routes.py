#!/usr/bin/env python3
"""Routing, masking and limits (LLD 8.3, 8.4, 8.6).

This is where R4 is either true or false, so the cases are written as the guarantee
reads: every string inspected, structural values scanned but not reshaped, anything
the masker cannot promise about refused.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "python"))
os.environ.setdefault("IHAR_ROOT", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from ihar.gateway import limits, log, routes    # noqa: E402
from ihar.mask import engine, shapes                    # noqa: E402
from ihar.mask.engine import Masker             # noqa: E402

SECRET = "sk-ant-abcdefghijklmnopqrstuvwxyz0123"
TOKEN = "ghp_aaaaaaaaaaaaaaaaaaaaaa"


def masker(level="standard"):
    # The regex engine is forced so the suite asserts the floor every machine has,
    # rather than whatever Presidio happens to be installed.
    return Masker(level=level, engine="regex")


# --------------------------------------------------------------------------- #
# Routing
# --------------------------------------------------------------------------- #

def test_model_routes_are_recognised():
    for method, path, upstream in (
        ("POST", "/v1/messages", routes.ANTHROPIC),
        ("POST", "/v1/messages/count_tokens", routes.ANTHROPIC),
        ("POST", "/v1/responses", routes.OPENAI),
        ("POST", "/backend-api/codex/responses", routes.CHATGPT),
    ):
        kind, found = routes.classify(method, path, {})
        assert kind == routes.MODEL, (path, kind)
        assert found == upstream, (path, found)


def test_an_unknown_route_is_not_transit():
    """The default is refuse. A routing table whose last rule relays anything else
    would carry a new vendor endpoint past the masker the day the vendor ships one."""
    for path in ("/v1/somethingnew", "/v2/messages", "/internal/whatever"):
        kind, _ = routes.classify("POST", path, {})
        assert kind == routes.UNKNOWN, (path, kind)


def test_local_and_transit():
    assert routes.classify("GET", "/api/ihar-probe", {})[0] == routes.LOCAL
    assert routes.classify("GET", "/v1/models", {})[0] == routes.TRANSIT
    assert routes.classify("GET", "/oauth/authorize", {})[0] == routes.TRANSIT
    # The ChatGPT remote-control relay rides on this; breaking it would take a web
    # surface down for a profile that never asked the gateway to touch it.
    assert routes.classify("GET", "/anything", {"Upgrade": "websocket"})[0] == routes.TRANSIT


def test_a_query_string_does_not_change_the_class():
    kind, _ = routes.classify("POST", "/v1/messages?beta=true", {})
    assert kind == routes.MODEL


# --------------------------------------------------------------------------- #
# The masking contract
# --------------------------------------------------------------------------- #

def test_every_string_is_inspected():
    body = {
        "model": "claude",
        "system": f"the key is {SECRET}",
        "messages": [{"role": "user", "content": [{"type": "text", "text": f"and {TOKEN}"}]}],
        "metadata": {"note": f"also {SECRET}"},
    }
    masked, kinds = shapes.transform(body, masker(), family="anthropic", enforced=True)
    flat = repr(masked)
    assert SECRET not in flat, flat
    assert TOKEN not in flat, flat
    assert kinds


def test_the_anthropic_system_field_is_masked():
    """It carries the project's own instructions, which routinely include personal
    data, so it is content rather than harness text."""
    body = {"system": "write to /home/alice and mail alice@example.com"}
    masked, _ = shapes.transform(body, masker(), family="anthropic", enforced=True)
    assert "alice@example.com" not in masked["system"], masked


def test_structural_values_keep_their_shape_but_lose_credentials():
    body = {
        "messages": [{"role": "user", "content": [
            {"type": "tool_use", "name": "Bash", "id": "toolu_1",
             "input": {"command": f"curl -H 'Authorization: {SECRET}' https://x/alice@example.com"}},
        ]}],
    }
    masked, _ = shapes.transform(body, masker(), family="anthropic", enforced=True)
    command = masked["messages"][0]["content"][0]["input"]["command"]
    assert SECRET not in command, command
    # The path and the address are load-bearing here: mangling them breaks the call
    # rather than protecting anything.
    assert "alice@example.com" in command, command
    assert masked["messages"][0]["content"][0]["name"] == "Bash"
    assert masked["messages"][0]["content"][0]["id"] == "toolu_1"


def test_harness_instructions_are_scanned_but_not_reshaped():
    body = {"instructions": "you are an agent; mail alice@example.com if asked",
            "input": [{"type": "input_text", "text": f"key {SECRET}"}]}
    masked, _ = shapes.transform(body, masker(), family="openai", enforced=True)
    assert "alice@example.com" in masked["instructions"]
    assert SECRET not in repr(masked)


def test_an_unknown_content_block_is_refused_under_an_enforced_profile():
    body = {"messages": [{"role": "user", "content": [
        {"type": "hologram", "data": "whatever"}]}]}
    _rejects(body, enforced=True, needle="unknown content block")
    # Under `standard` nothing is promised, so it relays.
    shapes.transform(body, masker(), family="anthropic", enforced=False)


def test_a_non_text_block_is_refused_under_an_enforced_profile():
    for kind in ("image", "document", "input_audio"):
        body = {"messages": [{"role": "user", "content": [
            {"type": kind, "source": {"data": "AAAA"}}]}]}
        _rejects(body, enforced=True, needle="cannot be masked")


def test_a_large_base64_value_is_refused():
    body = {"messages": [{"role": "user", "content": [
        {"type": "text", "text": "A" * 5000}]}]}
    _rejects(body, enforced=True, needle="base64")


def test_a_body_that_is_not_an_object_is_refused():
    _rejects([1, 2, 3], enforced=True, needle="not an object")


def test_an_engine_that_cannot_analyse_refuses_rather_than_degrading():
    """The silent fallback this replaces was the real defect (measured 2026-09-22).

    spaCy refuses text over 1,000,000 characters with ValueError E088, and the engine
    used to catch that and mask with regexes instead, while the package recorded
    `masked: true` at level `standard` and `ihar check` still reported `engine:
    presidio`. Nobody could see the weaker promise. Now the call raises and the caller
    decides; the gateway refuses.
    """
    class Refusing:
        def analyze(self, text, language):
            raise ValueError("[E088] Text of length 1000001 exceeds maximum of 1000000")

    instrument = engine.Masker("standard")
    instrument._analyzer = Refusing()
    instrument._engine = "presidio"
    try:
        instrument.mask("contact dev@example.invalid")
    except engine.MaskingUnavailable as reason:
        assert "E088" in str(reason), reason
        assert "presidio" in str(reason), reason
    else:
        raise AssertionError("a failed analysis was masked by something weaker in silence")


def test_the_engine_failure_reaches_the_gateway_as_a_refusal():
    class Refusing:
        def analyze(self, text, language):
            raise ValueError("[E088] too long")

    instrument = engine.Masker("standard")
    instrument._analyzer = Refusing()
    instrument._engine = "presidio"
    body = {"messages": [{"role": "user", "content": "anything at all"}]}
    try:
        shapes.transform(body, instrument, family="anthropic", enforced=True)
    except engine.MaskingUnavailable:
        return
    raise AssertionError("the body was transformed although the promised engine never ran")


def _rejects(body, *, enforced, needle):
    try:
        shapes.transform(body, masker(), family="anthropic", enforced=enforced)
    except shapes.Unsupported as reason:
        assert needle in str(reason), f"expected {needle!r} in {reason!r}"
        return
    raise AssertionError(f"the masker accepted a payload it cannot promise about: {body!r}")


def test_masking_off_changes_nothing():
    body = {"system": f"key {SECRET}"}
    masked, kinds = shapes.transform(body, masker("off"), family="anthropic", enforced=False)
    assert masked["system"] == body["system"]
    assert not kinds


def test_secrets_level_leaves_personal_data_alone():
    quiet = masker("secrets")
    text, _ = quiet.mask(f"alice@example.com and {SECRET}")
    assert "alice@example.com" in text
    assert SECRET not in text


# --------------------------------------------------------------------------- #
# Limits
# --------------------------------------------------------------------------- #

def test_limits_refuse_rather_than_truncate():
    for call, argument in (
        (limits.check_body_length, limits.MAX_BODY_BYTES + 1),
        (limits.check_depth, _deep(limits.MAX_JSON_DEPTH + 5)),
    ):
        try:
            call(argument)
        except limits.TooLarge:
            continue
        raise AssertionError(f"{call.__name__} accepted a payload over its limit")


def _deep(depth):
    value = "leaf"
    for _ in range(depth):
        value = {"next": value}
    return value


def test_header_limits():
    try:
        limits.check_headers({f"h{index}": "v" for index in range(limits.MAX_HEADER_COUNT + 5)})
    except limits.TooLarge:
        return
    raise AssertionError("too many headers were accepted")


# --------------------------------------------------------------------------- #
# The logging contract
# --------------------------------------------------------------------------- #

def test_the_log_drops_fields_outside_the_contract(capsys=None):
    """A caller that adds a field by mistake loses the field, not the request."""
    import io
    import contextlib
    buffer = io.StringIO()
    with contextlib.redirect_stderr(buffer):
        log.record(event="refuse", body=f"key {SECRET}", authorization="Bearer x",
                   reason="unknown route")
    written = buffer.getvalue()
    assert SECRET not in written, written
    assert "authorization" not in written.lower(), written
    assert "unknown route" in written, written


def test_the_log_strips_the_query_string():
    assert log.path_class("/v1/messages?token=secret123") == "/v1/messages"


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
    print(f"PASS={len(tests)} FAIL=0")
