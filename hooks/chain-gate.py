#!/usr/bin/env python3
"""IDD to SDD chain gate: one PreToolUse gate and one PostToolUse nudge, both vendors.

Reunified from iclaude's `chain-gate.py` and icodex's, neither of which was a superset
of the other (LLD 6.1, plan task S3.3):

  from iclaude  the `result_intent` stage, which is the whole of the `execute` route:
                that route writes no plan, so the intent is the artifact the result
                check reconciles against, and a gate that knows only about plans lets
                the final transition through unchecked. GATE_MAP therefore holds a
                list of rules per skill, tried in order.
  from icodex   malformed frontmatter blocks instead of passing; `phases` and
                `findings` are type-checked before they are trusted; a skill is
                recognised through Read and Bash, because Codex exposes no Skill tool;
                `apply_patch` bodies are read for the chain link; and the artifact path
                is passed to the hash pipeline as an argument rather than pasted into
                the shell string, which is the only one of these that was a defect
                rather than a gap.

Two events, selected by `--post` or by `hook_event_name`:

  PreToolUse   block (exit 2) a chain transition whose upstream artifact has not
               passed validation.
  PostToolUse  after an unvalidated intent, spec or plan is written, suggest the
               check-chain skill through additionalContext. Never blocks.

The gate never validates. Validation is the check-chain skill; this reads the verdict
it left in the artifact's frontmatter.

Ownership: an artifact gates only the session that created or claimed it, recorded in
a ledger under the runtime home. A session that did not create an artifact is not
gated by it; no session id or no ledger means no gate.

Failure class: fail-soft. Any internal exception exits 0, because a bug in a workflow
gate must never stop a real tool call. This is the opposite of security-pretool.py.
"""

from __future__ import annotations

import fnmatch
import glob
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "_shared"))

import hookio  # noqa: E402
import policy  # noqa: E402

DOCS_ROOT = "docs/superpowers"
PLANS_DIR = os.path.join(DOCS_ROOT, "plans")

BLOCK_ON = {"CRITICAL"}
IMPL_GATE_FRESH_SECONDS = 7200   # only a plan edited in the last two hours gates code
LEDGER_MAX_AGE_SECONDS = 7 * 24 * 3600

ARTIFACT_DIRS = ("intents", "specs", "plans")
CLAIM_SKILLS = {"executing-plans", "subagent-driven-development"}

SKILL_PATH_RE = re.compile(r"(?:^|/)skills/([^/\s\"']+)/SKILL\.md(?:$|[\s\"'])")
SKILL_TOKEN_RE = re.compile(r"\bskill\s*[:=]\s*[\"']?(?:[\w-]+:)?([\w-]+)")

# One rule per stage: where the artifact lives, which frontmatter block carries the
# verdict, which key in it holds the body hash, and the remediation to print.
STAGE_RULES = {
    "intent": {"dir": "intents", "glob": "*-intent.md", "block": "review",
               "hash_key": "intent_hash", "stage": "intent"},
    "spec": {"dir": "specs", "glob": "*-design.md", "block": "review",
             "hash_key": "spec_hash", "stage": "spec"},
    "plan": {"dir": "plans", "glob": "*.md", "block": "review",
             "hash_key": "plan_hash", "stage": "plan"},
    "result": {"dir": "plans", "glob": "*.md", "block": "result_check",
               "hash_key": "plan_hash", "stage": "result"},
    # The `execute` route writes no plan, so the intent is the result artifact.
    "result_intent": {"dir": "intents", "glob": "*-intent.md", "block": "result_check",
                      "hash_key": "intent_hash", "stage": "result"},
}

# Skill to the rules that gate it, tried in order. The first rule that resolves a
# session-owned candidate is the one that decides.
GATE_MAP = {
    "brainstorming": [STAGE_RULES["intent"]],
    "writing-plans": [STAGE_RULES["spec"]],
    "executing-plans": [STAGE_RULES["plan"]],
    "subagent-driven-development": [STAGE_RULES["plan"]],
    "finishing-a-development-branch": [STAGE_RULES["result"], STAGE_RULES["result_intent"]],
}

SPEC_RULE = STAGE_RULES["spec"]
PLAN_RULE = STAGE_RULES["plan"]

# `result` is absent on purpose: it needs a git diff and runs at branch finish, which
# the PreToolUse gate already covers.
NUDGE_RULES = [STAGE_RULES["intent"], STAGE_RULES["spec"], STAGE_RULES["plan"]]


# --------------------------------------------------------------------------- #
# Frontmatter, in the standard library
# --------------------------------------------------------------------------- #
#
# Both wrappers imported PyYAML lazily and fell open when it was missing. A hook here
# runs under the system interpreter with the standard library only, because it must
# work when the venv is broken (CLAUDE.md, Structure) — so that import would be absent
# on an ordinary machine and the gate would never gate anything at all.
#
# What is parsed is the subset check-chain writes: nested maps, lists of maps, plain
# scalars, flow sequences and block scalars. Anything outside it raises, and the caller
# treats a raise the way icodex did: as a blocked transition, not as permission.
#
# One deliberate divergence from PyYAML: a bare date stays a string. The gate compares
# such values for equality or not at all, so a date object would buy nothing and would
# make the parser's output depend on a type the rest of this file never handles.


class Malformed(ValueError):
    """The frontmatter is not the shape check-chain writes."""


def _scalar(text):
    text = text.strip()
    if not text:
        return None
    if len(text) >= 2 and text[0] in "\"'" and text[-1] == text[0]:
        return text[1:-1]
    # A flow sequence. Nothing the gate reads is written this way, but leaving one as
    # the literal string "[a, b]" would be a wrong value rather than a refused one.
    if len(text) >= 2 and text[0] == "[" and text[-1] == "]":
        inner = text[1:-1].strip()
        return [_scalar(part) for part in inner.split(",")] if inner else []
    lowered = text.lower()
    if lowered in ("null", "~"):
        return None
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    for cast in (int, float):
        try:
            return cast(text)
        except ValueError:
            pass
    return text


def _significant(lines):
    """(indent, content) for every line that carries data."""
    out = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        out.append((len(line) - len(line.lstrip(" ")), stripped))
    return out


def _block_scalar(rows, index, indent):
    """A `|` or `>` block: every deeper line, joined."""
    parts = []
    while index < len(rows) and rows[index][0] > indent:
        parts.append(rows[index][1])
        index += 1
    return "\n".join(parts), index


def _parse(rows, index, indent):
    """The value at `indent` starting at `index`, and the row after it."""
    if index >= len(rows):
        return None, index
    content = rows[index][1]
    if content.startswith("- "):
        return _parse_list(rows, index, indent)
    if ":" not in content:
        # A value on its own line, which is how an empty sequence is often written:
        #   findings:
        #     []
        # Reading it as a map would raise, and a raise here is a blocked transition —
        # so this shape has to be understood rather than refused.
        return _scalar(content), index + 1
    return _parse_map(rows, index, indent)


def _parse_list(rows, index, indent):
    items = []
    while index < len(rows) and rows[index][0] == indent and rows[index][1].startswith("- "):
        head = rows[index][1][2:].strip()
        if ":" in head and not head.startswith(("\"", "'")):
            # A list of maps: the first key sits on the dash line, the rest below it.
            synthetic = [(indent + 2, head)] + rows[index + 1:]
            value, consumed = _parse_map(synthetic, 0, indent + 2)
            index = index + 1 + (consumed - 1)
            items.append(value)
            continue
        items.append(_scalar(head))
        index += 1
    return items, index


def _parse_map(rows, index, indent):
    result = {}
    while index < len(rows) and rows[index][0] == indent:
        content = rows[index][1]
        if content.startswith("- "):
            break
        if ":" not in content:
            raise Malformed(f"not a key: {content!r}")
        key, _, rest = content.partition(":")
        key = key.strip()
        rest = rest.strip()
        index += 1
        if rest in ("|", ">", "|-", ">-"):
            result[key], index = _block_scalar(rows, index, indent)
            continue
        if rest:
            result[key] = _scalar(rest)
            continue
        if index < len(rows) and rows[index][0] > indent:
            result[key], index = _parse(rows, index, rows[index][0])
        elif index < len(rows) and rows[index][0] == indent and rows[index][1].startswith("- "):
            result[key], index = _parse_list(rows, index, indent)
        else:
            result[key] = None
    return result, index


def frontmatter_from_lines(lines):
    """The document's frontmatter mapping, or {} when it has none."""
    if not lines or lines[0].strip() != "---":
        return {}
    body = []
    closed = False
    for line in lines[1:]:
        if line.strip() == "---":
            closed = True
            break
        body.append(line)
    if not closed:
        return {}
    rows = _significant(body)
    if not rows:
        return {}
    value, _ = _parse(rows, 0, rows[0][0])
    if not isinstance(value, dict):
        raise Malformed("frontmatter is not a mapping")
    return value


def read_frontmatter(path):
    with open(path, "r", encoding="utf-8") as handle:
        return frontmatter_from_lines(handle.read().splitlines())


# --------------------------------------------------------------------------- #
# Ownership ledger
# --------------------------------------------------------------------------- #


def ledger_path(event):
    home = policy._runtime_home(event)
    return os.path.join(home, "state", "idd-sessions.json") if home else None


def load_ledger(event):
    path = ledger_path(event)
    if not path or not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    now = time.time()
    kept = {}
    for key, value in data.items():
        if not isinstance(value, dict) or not os.path.exists(key):
            continue
        if now - value.get("ts", 0) > LEDGER_MAX_AGE_SECONDS:
            continue
        kept[key] = value
    return kept


def record_owner(path, event):
    target = ledger_path(event)
    session = event.session_id
    if not target or not session:
        return
    ledger = load_ledger(event)
    ledger[os.path.abspath(path)] = {"session": session, "ts": int(time.time())}
    try:
        os.makedirs(os.path.dirname(target), exist_ok=True)
        staging = f"{target}.{os.getpid()}.tmp"
        with open(staging, "w", encoding="utf-8") as handle:
            json.dump(ledger, handle)
        os.replace(staging, target)
    except OSError:
        pass


def owns(path, session, ledger):
    if not session:
        return False
    entry = ledger.get(os.path.abspath(path))
    return isinstance(entry, dict) and entry.get("session") == session


def _under(path, root):
    resolved = os.path.abspath(path)
    base = os.path.abspath(root)
    return resolved == base or resolved.startswith(base + os.sep)


def _is_artifact(path):
    return any(_under(path, os.path.join(DOCS_ROOT, name)) for name in ARTIFACT_DIRS)


def record_ownership(event):
    if event.tool in ("Write", "Edit"):
        for path in hookio.paths_of(event):
            if _is_artifact(path):
                record_owner(path, event)
        return
    if skill_of(event) in CLAIM_SKILLS:
        plan = newest_plan()
        if plan:
            record_owner(plan, event)


# --------------------------------------------------------------------------- #
# Which skill is being invoked
# --------------------------------------------------------------------------- #


def normalize_skill(name):
    return name.rsplit(":", 1)[-1].strip()


def skill_from_path(path):
    match = SKILL_PATH_RE.search(path.replace("\\", "/"))
    return normalize_skill(match.group(1)) if match else ""


def skill_from_text(text):
    if not isinstance(text, str):
        return ""
    match = SKILL_PATH_RE.search(text.replace("\\", "/"))
    if match:
        return normalize_skill(match.group(1))
    match = SKILL_TOKEN_RE.search(text)
    return normalize_skill(match.group(1)) if match else ""


def skill_of(event):
    """The skill this call invokes, by whichever route the vendor offers.

    Claude has a Skill tool and names it outright. Codex has none, so invoking a skill
    shows up as a Read of its SKILL.md or a Bash command that names it; reading only
    the Skill tool would leave the gate blind on that vendor.
    """
    if event.tool == "Skill":
        name = event.input.get("skill")
        return normalize_skill(name) if isinstance(name, str) else ""
    if event.tool == "Read":
        for path in hookio.paths_of(event):
            found = skill_from_path(path)
            if found:
                return found
        return ""
    if event.tool == "Bash":
        return skill_from_text(hookio.command_of(event) or "")
    return ""


# --------------------------------------------------------------------------- #
# Candidate resolution and the verdict
# --------------------------------------------------------------------------- #


def resolve_candidate(rule, event):
    matches = glob.glob(os.path.join(DOCS_ROOT, rule["dir"], rule["glob"]))
    if not matches:
        return None
    ledger = load_ledger(event)
    owned = [match for match in matches if owns(match, event.session_id, ledger)]
    if not owned:
        return None
    return max(owned, key=os.path.getmtime)


def newest_plan():
    matches = glob.glob(os.path.join(DOCS_ROOT, PLAN_RULE["dir"], PLAN_RULE["glob"]))
    return max(matches, key=os.path.getmtime) if matches else None


def body_hash(path):
    """The artifact's body hash, exactly as check-chain computes it.

    The pipeline is the skill's own, run rather than reimplemented, because the value
    has to agree byte for byte with what check-chain wrote into the frontmatter. The
    path is an argument, never interpolated into the shell string: a quote in a
    filename would otherwise end the string and run whatever followed it.
    """
    pipeline = (
        "set -o pipefail; "
        "awk 'BEGIN{fm=0} /^---$/{fm++; next} fm>=2{print}' "
        '"$1" | sha256sum | cut -c1-16'
    )
    completed = subprocess.run(
        ["bash", "-c", pipeline, "--", path],
        capture_output=True, text=True, check=True,
    )
    return completed.stdout.strip()


def gate_reason(path, rule):
    """None when the gate is open for `path`, otherwise why it is shut."""
    try:
        frontmatter = read_frontmatter(path)
    except Malformed:
        # Not fail-open: frontmatter nobody can read is not a passed check, and
        # treating it as one is how an unvalidated artifact walks through the gate.
        return "malformed frontmatter"

    block = frontmatter.get(rule["block"])
    if not isinstance(block, dict):
        return f"no {rule['block']}: block"

    if block.get(rule["hash_key"]) != body_hash(path):
        return "hash stale (edited after the last check)"

    if rule["block"] == "result_check":
        verdict = block.get("verdict")
        return None if verdict == "OK" else f"result_check verdict: {verdict}"

    phases = block.get("phases")
    if not isinstance(phases, dict):
        return "malformed phases"
    findings = block.get("findings") or []
    if not isinstance(findings, list):
        return "malformed findings"

    for name, phase in phases.items():
        status = phase.get("status") if isinstance(phase, dict) else None
        if status != "passed":
            return f"phase {name}: {status}"

    open_critical = [
        finding.get("id", "?")
        for finding in findings
        if isinstance(finding, dict)
        and finding.get("severity") in BLOCK_ON
        and finding.get("verdict") == "open"
    ]
    if open_critical:
        return "open CRITICAL: " + ", ".join(open_critical)
    return None


def validated(path, rule):
    return gate_reason(path, rule) is None


def fresh(path, seconds):
    return time.time() - os.path.getmtime(path) <= seconds


# --------------------------------------------------------------------------- #
# Decisions
# --------------------------------------------------------------------------- #


def block(event, candidate, reason, stage):
    hookio.deny(event, (
        f"chain gate: {candidate} has not passed validation ({reason}). "
        f"Run the check-chain skill with argument {stage} on it, resolve the CRITICAL "
        f"findings, then retry."
    ))


def resolve_spec_from_chain(content):
    try:
        data = frontmatter_from_lines((content or "").splitlines())
    except Malformed:
        return None
    chain = data.get("chain")
    spec = chain.get("spec") if isinstance(chain, dict) else None
    return spec if spec and os.path.exists(spec) else None


def patch_added_body(patch, target):
    """The new-file body of an `*** Add File:` block, with the leading `+` removed."""
    if not patch:
        return ""
    wanted = target.replace("\\", "/") if target else None
    capturing = False
    out = []
    for line in patch.splitlines():
        if line.startswith("*** Add File: "):
            path = line[len("*** Add File: "):].strip().replace("\\", "/")
            capturing = wanted is None or path == wanted
            if capturing:
                out = []
            continue
        if line.startswith("*** "):
            if capturing:
                break
            continue
        if capturing and line.startswith("+"):
            out.append(line[1:])
    return "\n".join(out)


def written_body(event, path):
    """The body this call would write: an apply_patch addition, or plain content."""
    for key in ("patch", "input", "content", "text"):
        value = event.input.get(key)
        if not isinstance(value, str) or not value:
            continue
        if "*** " in value:
            body = patch_added_body(value, path)
            if body:
                return body
        return value
    return ""


def handle_write(event):
    paths = hookio.paths_of(event)
    if not paths:
        hookio.allow()

    for path in paths:
        if _under(path, PLANS_DIR) and path.endswith(".md"):
            # Writing a plan is the spec-to-plan transition, so the spec must have
            # passed. The plan's own chain block names it; failing that, the newest
            # spec this session owns.
            spec = resolve_spec_from_chain(written_body(event, path)) \
                or resolve_candidate(SPEC_RULE, event)
            if spec is not None:
                reason = gate_reason(spec, SPEC_RULE)
                if reason is not None:
                    block(event, spec, reason, SPEC_RULE["stage"])
            continue

        if not _under(path, DOCS_ROOT):
            # Writing code is the plan-to-implementation transition. Only a plan
            # edited recently gates it: an old one is a finished piece of work, not
            # the thing this change is executing.
            plan = resolve_candidate(PLAN_RULE, event)
            if plan is None or not fresh(plan, IMPL_GATE_FRESH_SECONDS):
                continue
            reason = gate_reason(plan, PLAN_RULE)
            if reason is not None:
                block(event, plan, reason, PLAN_RULE["stage"])

    hookio.allow()


def handle_skill(event):
    for rule in GATE_MAP.get(skill_of(event)) or []:
        candidate = resolve_candidate(rule, event)
        if candidate is None:
            continue
        reason = gate_reason(candidate, rule)
        if reason is None:
            hookio.allow()
        block(event, candidate, reason, rule["stage"])
    hookio.allow()


def rule_for(path):
    resolved = os.path.abspath(path)
    for rule in NUDGE_RULES:
        root = os.path.abspath(os.path.join(DOCS_ROOT, rule["dir"]))
        if _under(resolved, root) and fnmatch.fnmatch(os.path.basename(resolved), rule["glob"]):
            return rule
    return None


def handle_nudge(event):
    # Edits are not nudged: an artifact is edited many times while it is being
    # written, and a nudge per edit is noise rather than a reminder.
    if event.raw_tool not in ("Write", "apply_patch"):
        hookio.allow()
    for path in hookio.paths_of(event):
        rule = rule_for(path)
        if rule is None or not os.path.exists(path):
            continue
        if validated(path, rule):
            continue
        hookio.context(event, (
            f"The chain artifact {path} was just written and has not passed "
            f"validation. Run the check-chain skill with argument {rule['stage']} on "
            f"it, so the gate is open before the next chain transition."
        ))
    hookio.allow()


def main():
    post = "--post" in sys.argv[1:]
    try:
        event = hookio.read_event()
    except Exception:
        # Unreadable input is not something a workflow gate may block on.
        return 0

    try:
        if post or event.event == "PostToolUse":
            handle_nudge(event)
        record_ownership(event)
        if event.tool in ("Skill", "Read", "Bash"):
            handle_skill(event)
        elif event.tool in ("Write", "Edit"):
            handle_write(event)
    except SystemExit:
        raise
    except Exception as error:
        print(f"ihar: chain-gate: {error}; continuing (fail-soft)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
