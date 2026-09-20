#!/usr/bin/env python3
"""Unit tests for the contract validator.

Run standalone or under pytest. Isolated by construction: every filesystem test
writes into its own temporary directory.
"""

import json
import os
import stat
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "python"))

from ihar import install_receipt, jsonio  # noqa: E402

PROFILE = {
    "schema": 1,
    "name": "x",
    "guarantee": "g",
    "hooks": "best-effort",
    "gateway": "off",
    "masking_level": "off",
    "sandbox": "vendor-default",
    "netpolicy": None,
    "remote": [],
    "mcp": {"strict": False},
    "acp": "allow",
    "env_passthrough": [],
    "handoff": {"system_prompt": False},
}

LOCKFILE = {
    "schema": 1,
    "node": {"version": "22.23.1"},
    "claude": {"version": "2.1.274"},
}

RECEIPT = {
    "schema": 1,
    "release_lock_sha256": "a" * 64,
    "installed_at": "2026-09-20T00:00:00Z",
    "components": {
        "claude": {"version": "2.1.274", "binary_sha256": "b" * 64},
    },
}

STATE_MANIFEST = {
    "schema": 1,
    "entries": [
        {"vendor": "codex", "path": "state_5.sqlite", "kind": "sqlite-family"},
    ],
}

CHECK_RESULT = {
    "schema": 1,
    "profile": {"name": "protected", "guarantee": "masked model egress"},
    "masking": {"level": "standard", "floor": "standard", "engine": "regex", "dropped_env": ["TOKEN"]},
    "gateway": {"mode": "explicit", "network_policy": "protected", "instances": ["abc port 1234"]},
    "vendors": {
        "claude": {"receipt": "valid", "hooks": [{"id": "security-pretool", "trust": "configured"}], "conformance": "proven", "capabilities": ["fork", "remote-control"]},
        "codex": {"receipt": "missing", "hooks": [{"id": "security-pretool", "trust": "recorded"}], "conformance": "unproven", "capabilities": ["archive", "fork"]},
    },
    "assets": [{"requirement": "optional", "presence": "missing", "source": "commands", "target": "commands"}],
    "mcp": {"strict": True, "notes": {"claude": ["missing TOKEN"], "codex": []}},
    "known_gaps": ["claude-agent-acp #144"],
}


def rejects(kind, doc, needle=None, **kwargs):
    try:
        jsonio.check(kind, doc, **kwargs)
    except jsonio.SchemaError as error:
        if needle is not None:
            assert needle in str(error), f"expected {needle!r} in {error!r}"
        return str(error)
    raise AssertionError(f"{kind} accepted a document it should reject: {doc!r}")


def test_unknown_kind_names_the_registered_ones():
    message = rejects_kind()
    assert "profile" in message and "session" in message


def rejects_kind():
    try:
        jsonio.check("nonesuch", {})
    except jsonio.SchemaError as error:
        return str(error)
    raise AssertionError("an unknown kind was accepted")


def test_types_are_checked_and_bool_is_not_an_integer():
    rejects("profile", {**PROFILE, "schema": True}, "expected integer, got boolean")
    rejects("profile", {**PROFILE, "name": 1}, "expected string")
    rejects("profile", {**PROFILE, "remote": "codex"}, "expected array")


def test_unknown_key_is_an_error_not_a_warning():
    rejects("profile", {**PROFILE, "surprise": 1}, "unknown key")


def test_missing_key_is_reported_by_name():
    incomplete = {key: value for key, value in PROFILE.items() if key != "acp"}
    rejects("profile", incomplete, "missing required key 'acp'")


def test_nested_shapes_are_validated():
    rejects("profile", {**PROFILE, "mcp": {"strict": "yes"}}, "mcp.strict")
    rejects("profile", {**PROFILE, "remote": ["gemini"]}, "remote[0]")


def test_patterns_are_anchored():
    rejects("profile", {**PROFILE, "name": "Not-A-Slug"})
    rejects("profile", {**PROFILE, "env_passthrough": ["lower"]})


def test_session_partial_relaxes_only_the_named_keys():
    partial = {"schema": 1, "ihar_id": "0" * 8 + "-0000-0000-0000-" + "0" * 12,
               "vendor": "codex", "source": "hook"}
    jsonio.check("session", partial, partial=True)
    rejects("session", {key: value for key, value in partial.items() if key != "ihar_id"},
            "missing required key 'ihar_id'", partial=True)
    # A partial document still has its present fields type-checked.
    rejects("session", {**partial, "vendor": "gemini"}, partial=True)
    # And a kind without a partial form refuses one outright.
    rejects("profile", PROFILE, "has no partial form", partial=True)


def test_semantic_rules_run_on_the_partial_shape_too():
    """The partial record is the one a SessionStart hook appends, so it is exactly
    the shape the session rules must police (LLD 10.3)."""
    same = "0" * 8 + "-0000-0000-0000-" + "0" * 12
    partial = {"schema": 1, "ihar_id": same, "vendor": "codex", "source": "hook",
               "parent_ihar_id": same}
    rejects("session", partial, "points at itself", partial=True)


def test_free_form_maps_validate_keys_and_values():
    record = {
        "schema": 1, "vendor": "codex", "version": "0.154.0",
        "binary_sha256": "a" * 64, "manifest_digest": "b" * 64,
        "created_at": "2026-09-18T10:00:00Z",
        "cases": {"deny": {"status": "passed"}},
    }
    jsonio.check("conformance", record)
    rejects("conformance", {**record, "cases": {"deny": {"status": "maybe"}}}, "cases.deny.status")
    rejects("conformance", {**record, "cases": {}}, "no cases recorded")


def test_timestamps_must_be_iso_utc():
    record = {
        "schema": 1, "pid": 1, "socket": "/tmp/s", "binary_sha256": "a" * 64,
        "codex_version": "0.154.0", "config_hash": "abcd1234",
        "started_at": "1758186000", "remote_control": False,
    }
    rejects("daemon-record", record, "started_at")


def test_write_is_atomic_and_validated_first():
    with tempfile.TemporaryDirectory() as tmp:
        target = os.path.join(tmp, "profile.json")

        rejects_write(target)
        assert not os.path.exists(target), "an invalid document left a file behind"
        assert not [name for name in os.listdir(tmp) if name.startswith(".ihar-")], \
            "a temporary file was left behind"

        jsonio.write("profile", target, PROFILE)
        assert json.load(open(target)) == PROFILE
        assert stat.S_IMODE(os.stat(target).st_mode) == 0o600


def rejects_write(target):
    try:
        jsonio.write("profile", target, {**PROFILE, "gateway": "sideways"})
    except jsonio.SchemaError:
        return
    raise AssertionError("write accepted an invalid document")


def test_read_prefixes_the_path():
    with tempfile.TemporaryDirectory() as tmp:
        target = os.path.join(tmp, "broken.json")
        with open(target, "w", encoding="utf-8") as handle:
            handle.write("{not json")
        message = None
        try:
            jsonio.read("profile", target)
        except jsonio.SchemaError as error:
            message = str(error)
        assert message and target in message and "not valid JSON" in message


def test_merge_managed_replaces_managed_keys_and_keeps_the_rest():
    base = {"model": "opus", "hooks": {"old": True}, "statusLine": {"a": 1}}
    managed = {"hooks": {"new": True}}
    merged = jsonio.merge_managed(base, managed, ["hooks", "statusLine"])
    assert merged == {"model": "opus", "hooks": {"new": True}}, merged


def test_merge_managed_refuses_to_drop_a_rendered_key():
    """A render that emits a key the caller's list lags behind would otherwise write
    settings without it, leaving enforcement absent rather than failing closed."""
    try:
        jsonio.merge_managed({"a": 1}, {"hooks": {}, "newKey": 2}, ["hooks"])
    except jsonio.SchemaError as error:
        assert "newKey" in str(error)
        return
    raise AssertionError("merge_managed dropped a rendered key")


def test_integrity_pins_are_length_checked():
    record = {
        "schema": 1, "pid": 1, "socket": "/tmp/s", "binary_sha256": "ab",
        "codex_version": "0.154.0", "config_hash": "abcd1234",
        "started_at": "2026-09-18T10:00:00Z", "remote_control": False,
    }
    rejects("daemon-record", record, "binary_sha256")
    record["binary_sha256"] = "a" * 64
    jsonio.check("daemon-record", record)
    rejects("daemon-record", {**record, "config_hash": "abc"}, "config_hash")


def test_release_lockfile_rejects_machine_local_evidence():
    jsonio.check("lockfile", LOCKFILE)
    rejects("lockfile", {**LOCKFILE, "installedAt": "2026-09-20T00:00:00Z"}, "installedAt")
    rejects(
        "lockfile",
        {**LOCKFILE, "claude": {"version": "2.1.274", "binarySha256": "b" * 64}},
        "binarySha256",
    )


def test_install_receipt_has_a_closed_component_shape():
    jsonio.check("install-receipt", RECEIPT)
    rejects("install-receipt", {key: value for key, value in RECEIPT.items() if key != "installed_at"})
    rejects("install-receipt", {**RECEIPT, "extra": True}, "unknown key")
    rejects(
        "install-receipt",
        {**RECEIPT, "components": {"gemini": RECEIPT["components"]["claude"]}},
        "gemini",
    )
    rejects(
        "install-receipt",
        {**RECEIPT, "components": {"claude": {**RECEIPT["components"]["claude"], "extra": 1}}},
        "unknown key",
    )


def test_install_receipt_requires_complete_sha256_digests():
    rejects("install-receipt", {**RECEIPT, "release_lock_sha256": "ab"}, "release_lock_sha256")
    rejects(
        "install-receipt",
        {**RECEIPT, "components": {"claude": {"version": "2.1.274", "binary_sha256": "cd"}}},
        "binary_sha256",
    )


def test_invalid_install_receipt_preserves_previous_file():
    with tempfile.TemporaryDirectory() as tmp:
        target = os.path.join(tmp, "install-receipt.json")
        with open(target, "w", encoding="utf-8") as handle:
            handle.write("previous\n")
        try:
            install_receipt.write_receipt(target, {**RECEIPT, "release_lock_sha256": "short"})
        except jsonio.SchemaError:
            pass
        else:
            raise AssertionError("write_receipt accepted invalid evidence")
        assert open(target, encoding="utf-8").read() == "previous\n"
        assert not [name for name in os.listdir(tmp) if name.startswith(".install-receipt-")]


def test_state_manifest_accepts_only_safe_relative_paths_and_supported_kinds():
    jsonio.check("state-manifest", STATE_MANIFEST)
    for path in ("", "/absolute", "../escape", "nested/../escape", "nested//empty", "trailing/"):
        rejects("state-manifest", {
            **STATE_MANIFEST,
            "entries": [{"vendor": "codex", "path": path, "kind": "file"}],
        }, "path")
    rejects("state-manifest", {
        **STATE_MANIFEST,
        "entries": [{"vendor": "codex", "path": "state", "kind": "socket"}],
    }, "kind")


def test_state_manifest_rejects_duplicate_vendor_path_keys():
    entry = STATE_MANIFEST["entries"][0]
    duplicate = {**entry, "kind": "file"}
    rejects("state-manifest", {**STATE_MANIFEST, "entries": [entry, duplicate]}, "duplicate")


def test_check_result_is_closed_and_covers_both_vendors():
    jsonio.check("check-result", CHECK_RESULT)
    rejects("check-result", {**CHECK_RESULT, "extra": True}, "unknown key")
    missing_codex = {**CHECK_RESULT, "vendors": {"claude": CHECK_RESULT["vendors"]["claude"]}}
    rejects("check-result", missing_codex, "codex")


def test_check_result_text_and_json_render_the_same_facts():
    from ihar import check_result

    rendered = check_result.render_text(CHECK_RESULT)
    encoded = check_result.render_json(CHECK_RESULT)
    jsonio.check("check-result", json.loads(encoded))
    for value in (
        "protected", "masked model egress", "standard", "explicit", "valid", "missing",
        "commands", "security-pretool", "recorded", "missing TOKEN", "claude-agent-acp #144",
    ):
        assert value in rendered, value
        assert value in encoded, value


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
    print(f"PASS={len(tests)} FAIL=0")
