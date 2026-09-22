#!/usr/bin/env python3
"""The ACP promotion gate: what it may conclude, and what it may not (plan task S13.4).

No network here. The tracker is injected, because a test that depends on GitHub answers
about GitHub rather than about the gate, and the gate's whole purpose is that a promotion
rests on evidence rather than on whoever ran it last.
"""

import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib" / "python"))

from ihar import acp_promotion, jsonio  # noqa: E402

PASS = FAIL = 0


def check(label, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
    else:
        FAIL += 1
        print(f"FAIL {label}")


def manifest(*conditions):
    return {"schema": 1, "conditions": list(conditions)}


ISSUE = {"id": "an-issue", "kind": "issue", "repo": "owner/repo", "issue": 1,
         "requirement": "the behaviour landed"}
PROBE = {"id": "a-probe", "kind": "probe", "vendor": "claude",
         "requirement": "the behaviour is observable"}


def by_id(report, identifier):
    return next(row for row in report["conditions"] if row["id"] == identifier)


def main():
    global PASS, FAIL

    # The shipped manifest is the contract it claims to be.
    shipped = jsonio.read("acp-promotion", str(ROOT / "manifests" / "acp-promotion.json"))
    check("the shipped manifest validates", shipped["schema"] == 1)
    check("the shipped manifest names both halves of the condition",
          {row["kind"] for row in shipped["conditions"]} == {"issue", "probe"})
    check("every condition the plan names is a row",
          {row["id"] for row in shipped["conditions"]} >=
          {"claude-hooks-issue", "codex-config-issue", "codex-roots-issue"})

    # An open issue fails; a closed one passes; an unreachable tracker is neither.
    open_report = acp_promotion.measure(
        manifest(ISSUE), fetch=lambda repo, number: {"state": "open", "title": "still broken"})
    check("an open issue fails", by_id(open_report, "an-issue")["state"] == "failed")
    check("an open issue is not promotable", open_report["promotable"] is False)
    check("the failure quotes the tracker", "still broken" in by_id(open_report, "an-issue")["detail"])

    closed_report = acp_promotion.measure(
        manifest(ISSUE), fetch=lambda repo, number: {"state": "closed", "title": "fixed",
                                                     "closed_at": "2026-09-01T00:00:00Z"})
    check("a closed issue passes", by_id(closed_report, "an-issue")["state"] == "passed")
    check("a closed issue alone is promotable when it is the only condition",
          closed_report["promotable"] is True)

    def explode(repo, number):
        raise OSError("no route to host")

    offline = acp_promotion.measure(manifest(ISSUE), fetch=explode)
    check("an unreachable tracker is unmeasured, not passed",
          by_id(offline, "an-issue")["state"] == "unmeasured")
    check("an unmeasured condition is never promotable", offline["promotable"] is False)

    # A probe that has never been measured against a real adapter cannot pass.
    unimplemented = dict(PROBE, unimplemented="nobody has run this yet")
    report = acp_promotion.measure(manifest(unimplemented),
                                   fetch=lambda *_: {"state": "closed", "title": ""})
    check("an unimplemented probe is unmeasured",
          by_id(report, "a-probe")["state"] == "unmeasured")
    check("an unimplemented probe blocks promotion", report["promotable"] is False)

    # A probe whose adapter or credentials are absent says which, and stays unmeasured.
    environment = dict(os.environ)
    with tempfile.TemporaryDirectory() as raw:
        store = Path(raw) / "store"
        (store / "auth" / "claude").mkdir(parents=True)
        os.environ.pop("IHAR_CLAUDE_ACP_BIN", None)
        os.environ["IHAR_STORE"] = str(store)
        report = acp_promotion.measure(manifest(PROBE), fetch=lambda *_: {"state": "closed"})
        check("a missing adapter is named", "not installed" in by_id(report, "a-probe")["detail"])

        adapter = store / "claude-agent-acp"
        adapter.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        os.environ["IHAR_CLAUDE_ACP_BIN"] = str(adapter)
        report = acp_promotion.measure(manifest(PROBE), fetch=lambda *_: {"state": "closed"})
        check("empty credentials are named", "no credentials" in by_id(report, "a-probe")["detail"])

        (store / "auth" / "claude" / "token.json").write_text("{}", encoding="utf-8")
        report = acp_promotion.measure(manifest(PROBE), fetch=lambda *_: {"state": "closed"})
        check("an unwired probe is unmeasured rather than assumed",
              by_id(report, "a-probe")["state"] == "unmeasured")

        # The wired probe observes the shipped hook: a record appearing is the evidence.
        state = Path(raw) / "state"
        (state / "status").mkdir(parents=True)
        project = Path(raw) / "project"
        project.mkdir()

        writing = project / "ihar-writes.sh"
        writing.write_text(
            "#!/usr/bin/env bash\n"
            f'printf "%s" "{{}}" > "{state}/status/claude-observed.json"\n'
            f'exec python3 "{ROOT}/tests/fakes/acp-agent.py"\n', encoding="utf-8")
        writing.chmod(0o755)
        outcome = acp_promotion.probe_claude_hooks(str(project), str(state), str(writing),
                                                   timeout=20)
        check(f"a firing hook is observed ({outcome['detail']})", outcome["state"] == "passed")

        silent = project / "ihar-silent.sh"
        silent.write_text("#!/usr/bin/env bash\n"
                          f'exec python3 "{ROOT}/tests/fakes/acp-agent.py"\n', encoding="utf-8")
        silent.chmod(0o755)
        outcome = acp_promotion.probe_claude_hooks(str(project), str(state), str(silent),
                                                   timeout=8)
        check(f"a silent adapter fails rather than passing ({outcome['state']})",
              outcome["state"] == "failed")
        check("the failure names the upstream issue", "#144" in outcome["detail"])

        missing = acp_promotion.probe_claude_hooks(str(project), str(state),
                                                   str(project / "absent"), timeout=5)
        check("an adapter that cannot start is unmeasured, not failed",
              missing["state"] == "unmeasured")

        # The record is a contract, so a later reader knows when and on what it was taken.
        record = Path(raw) / "record.json"
        jsonio.write("acp-promotion-result", str(record), open_report)
        check("the result validates against its contract", record.is_file())
        check("the record keeps the verdict",
              json.loads(record.read_text(encoding="utf-8"))["promotable"] is False)

    os.environ.clear()
    os.environ.update(environment)
    print(f"PASS={PASS} FAIL={FAIL}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
