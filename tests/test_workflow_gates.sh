#!/usr/bin/env bash
# The two workflow gates, reunified for both vendors (LLD 6.1, 6.3; plan task S3.3).
#
# These gates are fail-soft, so the interesting assertions are the two directions a
# fail-soft component gets wrong: that it still blocks when it should, and that it
# never blocks when it cannot decide.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox

CHAIN="$ROOT/hooks/chain-gate.py"
GWT="$ROOT/hooks/gwt-gate.py"

# The gates keep their ledgers under the runtime home, which is the vendor's own
# configuration directory. Pointing it at the sandbox keeps a test run from writing
# into a real one.
HOME_DIR="$IHAR_TEST_TMP/runtime"
mkdir -p "$HOME_DIR"
export CLAUDE_CONFIG_DIR="$HOME_DIR"

PROJECT="$IHAR_TEST_TMP/proj"
mkdir -p "$PROJECT/docs/superpowers/intents" \
         "$PROJECT/docs/superpowers/specs" \
         "$PROJECT/docs/superpowers/plans"

SESSION="11111111-2222-3333-4444-555555555555"

# run <hook> <vendor> <json> [args...] — the hook's exit code, run in the project.
run() {
  local hook="$1" vendor="$2" payload="$3"; shift 3
  ( cd "$PROJECT" && printf '%s' "$payload" \
      | python3 -I "$hook" "$@" --vendor "$vendor" >/dev/null 2>&1 )
  echo $?
}

# out <hook> <vendor> <json> [args...] — the hook's stdout and stderr together.
out() {
  local hook="$1" vendor="$2" payload="$3"; shift 3
  ( cd "$PROJECT" && printf '%s' "$payload" \
      | python3 -I "$hook" "$@" --vendor "$vendor" 2>&1 )
}

# body_hash <file> — the same pipeline check-chain uses, so a fixture can carry a
# hash the gate will accept.
body_hash() {
  awk 'BEGIN{fm=0} /^---$/{fm++; next} fm>=2{print}' "$1" | sha256sum | cut -c1-16
}

# intent <path> <phase-status> [finding-verdict] — an artifact whose review block the
# gate will read, with the body hash filled in afterwards so it is always current.
intent() {
  local path="$1" status="$2" verdict="${3:-}"
  cat > "$path" <<EOF
---
review:
  intent_hash: PLACEHOLDER
  phases:
    structure:
      status: $status
$( [[ -n "$verdict" ]] \
     && printf '  findings:\n    - id: F-001\n      severity: CRITICAL\n      verdict: %s' "$verdict" \
     || printf '  findings: []' )
---
# Intent

Body text.
EOF
  local hash; hash="$(body_hash "$path")"
  sed -i "s/PLACEHOLDER/$hash/" "$path"
}

# claim <path> — record this session as the artifact's owner, which is what makes the
# artifact gate it at all.
claim() {
  mkdir -p "$HOME_DIR/state"
  python3 - "$HOME_DIR/state/idd-sessions.json" "$1" "$SESSION" <<'PY'
import json, os, sys, time
ledger_path, path, session = sys.argv[1], sys.argv[2], sys.argv[3]
ledger = json.load(open(ledger_path)) if os.path.exists(ledger_path) else {}
ledger[os.path.abspath(path)] = {"session": session, "ts": int(time.time())}
json.dump(ledger, open(ledger_path, "w"))
PY
}

skill_call() {
  printf '{"hook_event_name":"PreToolUse","tool_name":"Skill","session_id":"%s","tool_input":{"skill":"%s"}}' \
    "$SESSION" "$1"
}

# --- the frontmatter parser is the standard library, not PyYAML ----------------------
#
# Both wrappers imported PyYAML lazily and fell open when it was missing. A hook runs
# under the system interpreter, so on an ordinary machine that import is absent and
# the gate would never gate anything.

assert_eq "the gate imports no third-party module" "0" \
  "$(grep -cE '^\s*import (yaml|ruamel)' "$CHAIN")"

parsed="$(python3 -c "
import importlib.util, json
spec = importlib.util.spec_from_file_location('cg', '$CHAIN')
cg = importlib.util.module_from_spec(spec); spec.loader.exec_module(cg)
doc = '''---
review:
  intent_hash: abc
  phases:
    structure:
      status: passed
  findings:
    - id: F-001
      severity: CRITICAL
      verdict: open
---
body'''
print(json.dumps(cg.frontmatter_from_lines(doc.splitlines()), sort_keys=True))")"
assert_contains "nested maps parse" "$parsed" '"status": "passed"'
assert_contains "and lists of maps parse" "$parsed" '"id": "F-001"'

# An empty sequence written on the line below its key. Reading it as a map raises, and
# a raise is a blocked transition, so this shape has to be understood rather than
# refused — the gate blocked a perfectly valid artifact until it was.
own_line="$(python3 -c "
import importlib.util, json
spec = importlib.util.spec_from_file_location('cg', '$CHAIN')
cg = importlib.util.module_from_spec(spec); spec.loader.exec_module(cg)
doc = '''---
review:
  findings:
    []
---
body'''
print(json.dumps(cg.frontmatter_from_lines(doc.splitlines()), sort_keys=True))")"
assert_eq "a value on its own line parses" '{"review": {"findings": []}}' "$own_line"

malformed="$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('cg', '$CHAIN')
cg = importlib.util.module_from_spec(spec); spec.loader.exec_module(cg)
try:
    cg.frontmatter_from_lines(['---', 'review', '---', 'body'])
    print('parsed')
except cg.Malformed:
    print('refused')")"
assert_eq "frontmatter that is not the shape check-chain writes is refused" "refused" "$malformed"

# --- the chain gate blocks an unvalidated transition ---------------------------------

INTENT="$PROJECT/docs/superpowers/intents/2026-09-18-topic-intent.md"

intent "$INTENT" in_progress
claim "$INTENT"
assert_eq "an unvalidated intent blocks brainstorming" "2" \
  "$(run "$CHAIN" claude "$(skill_call brainstorming)")"
assert_contains "and the refusal names the phase" \
  "$(out "$CHAIN" claude "$(skill_call brainstorming)")" "phase structure: in_progress"

intent "$INTENT" passed
assert_eq "a validated intent lets it through" "0" \
  "$(run "$CHAIN" claude "$(skill_call brainstorming)")"

intent "$INTENT" passed open
assert_eq "an open CRITICAL finding blocks again" "2" \
  "$(run "$CHAIN" claude "$(skill_call brainstorming)")"
assert_contains "and the refusal names the finding" \
  "$(out "$CHAIN" claude "$(skill_call brainstorming)")" "open CRITICAL: F-001"

intent "$INTENT" passed fixed
assert_eq "a closed finding does not block" "0" \
  "$(run "$CHAIN" claude "$(skill_call brainstorming)")"

# An edit after the check invalidates it: the hash in the frontmatter is of the body
# that was checked, not of the body that is there now.
printf '\nedited after the check.\n' >> "$INTENT"
assert_eq "a body edited after the check blocks" "2" \
  "$(run "$CHAIN" claude "$(skill_call brainstorming)")"
assert_contains "and says the hash is stale" \
  "$(out "$CHAIN" claude "$(skill_call brainstorming)")" "hash stale"

# --- malformed frontmatter blocks rather than passing --------------------------------
#
# This is the one place the gate is not permissive. Frontmatter nobody can read is not
# a passed check, and treating it as one walks an unvalidated artifact through.

printf -- '---\nreview\n---\nbody\n' > "$INTENT"
assert_eq "malformed frontmatter blocks the transition" "2" \
  "$(run "$CHAIN" claude "$(skill_call brainstorming)")"
assert_contains "and says so" \
  "$(out "$CHAIN" claude "$(skill_call brainstorming)")" "malformed frontmatter"

# --- ownership: an artifact gates only the session that claimed it --------------------

intent "$INTENT" in_progress
other='{"hook_event_name":"PreToolUse","tool_name":"Skill","session_id":"99999999-9999-9999-9999-999999999999","tool_input":{"skill":"brainstorming"}}'
assert_eq "another session is not gated by it" "0" "$(run "$CHAIN" claude "$other")"

no_session='{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"brainstorming"}}'
assert_eq "and neither is a call with no session id" "0" "$(run "$CHAIN" claude "$no_session")"

# --- the execute route, which the Codex implementation had lost ----------------------
#
# `execute` writes no plan, so the intent carries the result_check block. A gate that
# knows only about plans lets the final transition through unchecked.

rm -f "$PROJECT"/docs/superpowers/plans/*.md
cat > "$INTENT" <<'EOF'
---
result_check:
  intent_hash: PLACEHOLDER
  verdict: needs_work
---
# Intent

Body text.
EOF
sed -i "s/PLACEHOLDER/$(body_hash "$INTENT")/" "$INTENT"
assert_eq "a needs_work result blocks branch finishing" "2" \
  "$(run "$CHAIN" claude "$(skill_call finishing-a-development-branch)")"
assert_contains "and names the verdict" \
  "$(out "$CHAIN" claude "$(skill_call finishing-a-development-branch)")" \
  "result_check verdict: needs_work"

sed -i 's/verdict: needs_work/verdict: OK/' "$INTENT"
sed -i "s/intent_hash: .*/intent_hash: $(body_hash "$INTENT")/" "$INTENT"
assert_eq "an OK result lets it finish" "0" \
  "$(run "$CHAIN" claude "$(skill_call finishing-a-development-branch)")"

# --- Codex names a skill differently, and the gate has to see it ----------------------
#
# Codex exposes no Skill tool, so invoking a skill shows up as a Read of its SKILL.md
# or a Bash command that names it. Reading only the Skill tool left the gate blind on
# that vendor for every skill transition, `finishing-a-development-branch` included.

intent "$INTENT" in_progress
claim "$INTENT"
codex_read="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"session_id\":\"$SESSION\",\"tool_input\":{\"file_path\":\"/home/u/skills/brainstorming/SKILL.md\"}}"
assert_eq "a skill read as a file still gates" "2" "$(run "$CHAIN" codex "$codex_read")"

codex_bash="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"$SESSION\",\"tool_input\":{\"command\":\"echo skill: brainstorming\"}}"
assert_eq "and so does one named in a command" "2" "$(run "$CHAIN" codex "$codex_bash")"

unrelated_read="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"session_id\":\"$SESSION\",\"tool_input\":{\"file_path\":\"/home/u/notes.md\"}}"
assert_eq "an ordinary read is untouched" "0" "$(run "$CHAIN" codex "$unrelated_read")"

# --- the gate is fail-soft everywhere else -------------------------------------------

assert_eq "unreadable stdin does not block" "0" "$(run "$CHAIN" claude 'not json')"
assert_eq "an unknown skill does not block" "0" \
  "$(run "$CHAIN" claude "$(skill_call something-else)")"
assert_eq "a tool the gate knows nothing about does not block" "0" \
  "$(run "$CHAIN" claude '{"hook_event_name":"PreToolUse","tool_name":"WebFetch","tool_input":{}}')"

# --- the post role nudges and never blocks -------------------------------------------

intent "$INTENT" in_progress
nudge="{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Write\",\"session_id\":\"$SESSION\",\"tool_input\":{\"file_path\":\"$INTENT\"}}"
assert_eq "the nudge exits zero" "0" "$(run "$CHAIN" claude "$nudge" --post)"
assert_contains "and asks for the right stage" "$(out "$CHAIN" claude "$nudge" --post)" \
  "check-chain skill with argument intent"

intent "$INTENT" passed
assert_eq "a validated artifact is not nudged" "0" \
  "$(grep -c additionalContext <<<"$(out "$CHAIN" claude "$nudge" --post)")"

# An edit is not nudged: an artifact is edited many times while it is written, and a
# nudge per edit is noise rather than a reminder.
intent "$INTENT" in_progress
edit_nudge="${nudge/\"tool_name\":\"Write\"/\"tool_name\":\"Edit\"}"
assert_eq "an edit is not nudged" "0" \
  "$(grep -c additionalContext <<<"$(out "$CHAIN" claude "$edit_nudge" --post)")"

# --- the path reaches the hash pipeline as an argument --------------------------------
#
# iclaude pasted it into the `bash -c` string, so a quote in a filename ended the
# string and ran whatever followed it.

assert_eq "the artifact path is never interpolated into the shell string" "0" \
  "$(grep -c '% path' "$CHAIN")"
assert_contains "it is passed as an argument instead" "$(cat "$CHAIN")" '"$1"'

quoted="$PROJECT/docs/superpowers/intents/2026-09-18-od\"d-intent.md"
intent "$quoted" in_progress
claim "$quoted"
touch "$quoted"
assert_eq "an artifact whose name carries a quote is handled, not executed" "2" \
  "$(run "$CHAIN" claude "$(skill_call brainstorming)")"
rm -f "$quoted"

# --- the GWT gate --------------------------------------------------------------------

gwt_update() { # <domain> <scenario-id>
  printf '{"hook_event_name":"PreToolUse","tool_name":"mcp__iwiki-remote__wiki_update_page","session_id":"%s","tool_input":{"domain":"%s","slug":"s","new_body":"## S\\n\\n```iwiki-gwt\\nid = \\"%s\\"\\n```\\n"}}' \
    "$SESSION" "$1" "$2"
}

status_response() { # <mode>
  printf '{"hook_event_name":"PostToolUse","tool_name":"mcp__iwiki-remote__wiki_status","session_id":"%s","tool_input":{},"tool_response":{"transport":"streamable-http","binding_source":"session","specifications":{"domains":[{"domain":"ihar","mode":"%s"}]}}}' \
    "$SESSION" "$1"
}

context_response() { # <domain> <scenario-id>
  printf '{"hook_event_name":"PostToolUse","tool_name":"mcp__iwiki-remote__wiki_spec_context","session_id":"%s","tool_input":{"domain":"%s","scenario_id":"%s"},"tool_response":{"ok":true}}' \
    "$SESSION" "$1" "$2"
}

rm -f "$HOME_DIR/state/gwt-status.json" "$HOME_DIR/state/gwt-contexts.json"

# Without a recorded status the gate does not know the domain's mode, and a gate that
# does not know its own mode must not let a strict-mode mutation through.
assert_eq "an unknown mode blocks the update" "2" \
  "$(run "$GWT" claude "$(gwt_update ihar confirm-account-opening)")"
assert_contains "and asks for wiki_status" \
  "$(out "$GWT" claude "$(gwt_update ihar confirm-account-opening)")" "wiki_status"

assert_eq "a status response is recorded" "0" "$(run "$GWT" claude "$(status_response strict)" --post)"
assert_exit "into the runtime home" 0 test -f "$HOME_DIR/state/gwt-status.json"

# A first write in a domain with no context at all may be a create, so it is advised
# rather than refused.
advice="$(out "$GWT" claude "$(gwt_update ihar confirm-account-opening)")"
assert_eq "a domain with no context is advised, not refused" "0" \
  "$(run "$GWT" claude "$(gwt_update ihar confirm-account-opening)")"
assert_contains "and the advice names wiki_spec_context" "$advice" "wiki_spec_context"

# Once the session has read some context in that domain, a scenario whose context it
# has not read is a rewrite of something it never looked at.
assert_eq "a context read is recorded" "0" \
  "$(run "$GWT" claude "$(context_response ihar other-scenario)" --post)"
assert_eq "a scenario with no context of its own is refused" "2" \
  "$(run "$GWT" claude "$(gwt_update ihar confirm-account-opening)")"

assert_eq "reading its context opens the gate" "0" \
  "$(run "$GWT" claude "$(context_response ihar confirm-account-opening)" --post)"
assert_eq "and the update goes through" "0" \
  "$(run "$GWT" claude "$(gwt_update ihar confirm-account-opening)")"

# The post role on wiki_update_page consumes the evidence, so the next rewrite of the
# same scenario needs its context read again. Without this entry in the manifest the
# evidence would never be consumed and one read would license every later rewrite.
consume="$(printf '{"hook_event_name":"PostToolUse","tool_name":"mcp__iwiki-remote__wiki_update_page","session_id":"%s","tool_input":{"domain":"ihar","new_body":"```iwiki-gwt\\nid = \\"confirm-account-opening\\"\\n```\\n"},"tool_response":{"ok":true}}' "$SESSION")"
assert_eq "a successful mutation consumes its evidence" "0" "$(run "$GWT" claude "$consume" --post)"
assert_eq "so the next rewrite needs the context again" "2" \
  "$(run "$GWT" claude "$(gwt_update ihar confirm-account-opening)")"

# An errored response says nothing about the wiki's state, so recording it would
# record a guess.
failed="$(printf '{"hook_event_name":"PostToolUse","tool_name":"mcp__iwiki-remote__wiki_spec_context","session_id":"%s","tool_input":{"domain":"ihar","scenario_id":"confirm-account-opening"},"tool_response":{"isError":true}}' "$SESSION")"
assert_eq "an errored response is not recorded" "0" "$(run "$GWT" claude "$failed" --post)"
assert_eq "so the gate still refuses" "2" \
  "$(run "$GWT" claude "$(gwt_update ihar confirm-account-opening)")"

# The hosted fallback describes the token's own grants rather than the scope this
# session bound, so its mode is not this session's mode.
rm -f "$HOME_DIR/state/gwt-status.json"
defaulted="$(printf '{"hook_event_name":"PostToolUse","tool_name":"mcp__iwiki-remote__wiki_status","session_id":"%s","tool_input":{},"tool_response":{"transport":"streamable-http","binding_source":"token_default","specifications":{"domains":[{"domain":"ihar","mode":"strict"}]}}}' "$SESSION")"
assert_eq "a token_default status is not trusted" "0" "$(run "$GWT" claude "$defaulted" --post)"
assert_eq "so the mode stays unknown and the update is refused" "2" \
  "$(run "$GWT" claude "$(gwt_update ihar confirm-account-opening)")"

# `disabled` turns the projection off, so there is nothing to order.
assert_eq "a disabled domain is recorded" "0" "$(run "$GWT" claude "$(status_response disabled)" --post)"
assert_eq "and its updates are not gated" "0" \
  "$(run "$GWT" claude "$(gwt_update ihar confirm-account-opening)")"

# --- the GWT gate is fail-soft ---------------------------------------------------------

assert_eq "a page with no scenario fence is not gated" "0" \
  "$(run "$GWT" claude "$(printf '{"hook_event_name":"PreToolUse","tool_name":"wiki_update_page","session_id":"%s","tool_input":{"domain":"ihar","new_body":"plain markdown"}}' "$SESSION")")"
assert_eq "unreadable stdin does not block" "0" "$(run "$GWT" claude 'not json')"
assert_eq "an unrelated tool does not block" "0" \
  "$(run "$GWT" claude '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}')"

# --- both gates are rendered for both vendors ------------------------------------------

export PYTHONPATH="$ROOT/lib/python"
render() { python3 -m ihar.render.hooks "$1" standard "$ROOT/manifests/hooks.json" "$2"; }
claude_render="$(render claude CLAUDE_CONFIG_DIR)"
codex_render="$(render codex CODEX_HOME)"

for vendor_render in "$claude_render" "$codex_render"; do
  assert_contains "the chain gate is rendered" "$vendor_render" "chain-gate.py"
  assert_contains "the gwt gate is rendered" "$vendor_render" "gwt-gate.py"
  assert_contains "the post roles carry --post" "$vendor_render" '.py\" --post'
done

# The post entry the LLD's manifest listing omitted. Its tool set is wider than the
# pre entry's on purpose: the modes and the context reads it records arrive on
# wiki_status and wiki_spec_context, not on the update it later gates.
assert_contains "the gwt post role also sees wiki_status" "$claude_render" "wiki_status"
assert_contains "and wiki_spec_context" "$claude_render" "wiki_spec_context"

# Codex has no Skill tool, so the chain gate has to be given the tools a skill
# invocation actually shows up as there, or it never fires for one.
codex_pre="$(printf '%s' "$codex_render" | python3 -c "
import json, sys
render = json.load(sys.stdin)['hooks']
for group in render['PreToolUse']:
    if any('chain-gate' in hook['command'] for hook in group['hooks']):
        print(group['matcher'])")"
assert_contains "the codex chain gate sees reads" "$codex_pre" "Read"
assert_contains "and shell commands" "$codex_pre" "Bash"

finish
