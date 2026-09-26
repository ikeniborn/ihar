#!/usr/bin/env bash
# The hook renderer and the security hook (LLD 6.1, 6.2, 6.3).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
export PYTHONPATH="$ROOT/lib/python"

MANIFEST="$ROOT/manifests/hooks.json"
HOOK="$ROOT/hooks/security-pretool.py"

render() { python3 -m ihar.render.hooks "$1" "$2" "$MANIFEST" "$3"; }

# --- matchers are regular expressions, not globs ------------------------------------
#
# The vendors match them as patterns. A literal `*` would mean "zero or more of the
# preceding character" and the hook would fire for almost nothing.

codex_render="$(render codex protected CODEX_HOME)"
claude_render="$(render claude standard CLAUDE_CONFIG_DIR)"

assert_contains "an mcp glob becomes a regex" "$codex_render" "mcp__.*"
assert_contains "codex gets its own edit tool name" "$codex_render" "apply_patch"
assert_contains "claude gets its own edit tool names" "$claude_render" "MultiEdit"
assert_eq "claude is never told about apply_patch" "0" \
  "$(grep -c 'apply_patch' <<<"$claude_render")"

matcher="$(python3 -c '
import sys
from ihar.render.hooks import matcher_for
print(matcher_for(["mcp:iwiki*__wiki_update_page"], "codex"))')"
assert_eq "a middle glob becomes .*" "mcp__iwiki.*__wiki_update_page" "$matcher"
assert_exit "and the result matches a real tool name" 0 \
  bash -c "[[ 'mcp__iwiki-local__wiki_update_page' =~ ^$matcher\$ ]]"

# A logical set the vendor has no spelling for drops the entry rather than rendering
# a matcher that can never fire.
skill_codex="$(python3 -c '
from ihar.render.hooks import matcher_for
print(repr(matcher_for(["skill"], "codex")))')"
assert_eq "a tool codex lacks yields an empty matcher" "''" "$skill_codex"

# --- the rendered command --------------------------------------------------------------

assert_contains "hooks run isolated from user site customisation" "$codex_render" "python3 -I"
assert_contains "and are told which vendor they serve" "$codex_render" "--vendor codex"
# The path is quoted and the arguments follow it, so a script name containing a
# space cannot split into two tokens. The needle carries the JSON escaping.
assert_contains "arguments sit outside the quoted path" "$codex_render" '.py\" --vendor'

# --- the manifest linter still guards the concurrency hazard -----------------------------

assert_exit "a second input-rewriting hook on one event is refused" 7 python3 -c "
import sys
from ihar import jsonio
entry = {'id':'a','event':'PreToolUse','tools':['shell'],'script':'s.py','args':[],
         'timeout':10,'vendors':['codex'],'profiles':['*'],'rewrites_input':True}
try:
    jsonio.check('hook-manifest', {'schema':1,'entries':[entry, {**entry,'id':'b'}]})
except jsonio.SchemaError:
    sys.exit(7)
"

# --- the security hook decides, on both vendor input shapes --------------------------------

run_hook() { # <vendor> <json>
  printf '%s' "$2" | python3 -I "$HOOK" --vendor "$1" 2>&1
  return $?
}
hook_exit() { # <vendor> <json>
  printf '%s' "$2" | python3 -I "$HOOK" --vendor "$1" >/dev/null 2>&1
  echo $?
}

claude_bash='{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"s",
  "tool_input":{"command":"echo hello"}}'
codex_bash='{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"s",
  "input":{"cmd":"echo hello"}}'

assert_eq "a harmless command is allowed on claude" "0" "$(hook_exit claude "$claude_bash")"
assert_eq "a harmless command is allowed on codex" "0" "$(hook_exit codex "$codex_bash")"

CLAUDE_CONFIG_DIR="$IHAR_TEST_TMP/claude-runtime"
mkdir -p "$CLAUDE_CONFIG_DIR"
printf '{"hooks":"enforced","masking_level":"off","protected_paths":["%s"]}\n' \
  "$IHAR_STORE" > "$CLAUDE_CONFIG_DIR/ihar-policy.json"
export CLAUDE_CONFIG_DIR
claude_protected_shell="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"s\",\"tool_input\":{\"command\":\"printf x > $IHAR_STORE/from-shell\"}}"
assert_eq "shell text is not treated as a protected-path parser" "0" \
  "$(hook_exit claude "$claude_protected_shell")"
unset CLAUDE_CONFIG_DIR

# Reading a credential path is refused on both, through each vendor's own spelling.
claude_read='{"hook_event_name":"PreToolUse","tool_name":"Read",
  "tool_input":{"file_path":"/home/u/.ssh/id_ed25519"}}'
codex_patch='{"hook_event_name":"PreToolUse","tool_name":"apply_patch",
  "input":{"patch":"*** Update File: /home/u/.aws/credentials\n+secret"}}'

assert_eq "a credential path is denied on claude" "2" "$(hook_exit claude "$claude_read")"
assert_eq "a credential path inside a codex patch is denied" "2" "$(hook_exit codex "$codex_patch")"
assert_contains "and the denial says which path" "$(run_hook claude "$claude_read")" "id_ed25519"

# A template is not the real thing; refusing it teaches people to disable the hook.
claude_example='{"hook_event_name":"PreToolUse","tool_name":"Read",
  "tool_input":{"file_path":"/repo/.env.example"}}'
assert_eq "a template file is allowed" "0" "$(hook_exit claude "$claude_example")"

# --- redaction rewrites rather than refuses -------------------------------------------------

secret_write='{"hook_event_name":"PreToolUse","tool_name":"Write",
  "tool_input":{"file_path":"/repo/app.py","content":"key = \"sk-ant-abcdefghijklmnopqrstuvwxyz0123\""}}'
out="$(printf '%s' "$secret_write" | python3 -I "$HOOK" --vendor claude 2>/dev/null)"
assert_eq "a secret in content does not block the call" "0" "$(hook_exit claude "$secret_write")"
assert_contains "it is rewritten through updatedInput" "$out" "updatedInput"
assert_contains "the placeholder names the kind" "$out" "REDACTED-anthropic-key"
assert_eq "and the secret itself is gone" "0" "$(grep -c 'sk-ant-abcdefghijklmnopqrstuvwxyz0123' <<<"$out")"

codex_secret='{"hook_event_name":"PreToolUse","tool_name":"Bash",
  "tool_input":{"command":"printf sk-ant-abcdefghijklmnopqrstuvwxyz0123"}}'
out="$(printf '%s' "$codex_secret" | python3 -I "$HOOK" --vendor codex 2>/dev/null)"
assert_contains "a Codex rewrite carries its required allow decision" "$out" \
  '"permissionDecision": "allow"'
assert_contains "and carries the rewritten input" "$out" '"updatedInput"'
assert_contains "and keeps the masked command" "$out" "REDACTED-anthropic-key"

# The anchor an edit matches against is never rewritten: masking it would make the
# edit fail rather than make it safe.
edit_anchor='{"hook_event_name":"PreToolUse","tool_name":"Edit",
  "tool_input":{"file_path":"/repo/a.py","old_string":"token = \"ghp_aaaaaaaaaaaaaaaaaaaaaa\"",
  "new_string":"token = os.environ[\"T\"]"}}'
out="$(printf '%s' "$edit_anchor" | python3 -I "$HOOK" --vendor claude 2>/dev/null)"
assert_eq "an edit anchor is left alone" "0" "$(grep -c 'REDACTED' <<<"${out:-none}")"

# --- the hook fails closed ---------------------------------------------------------------

assert_eq "unparseable stdin is denied, not allowed" "2" "$(hook_exit claude 'not json')"
assert_eq "a hook rendered without --vendor refuses to guess" "2" \
  "$(printf '%s' "$claude_bash" | python3 -I "$HOOK" >/dev/null 2>&1; echo $?)"

# --- output keys the vendor schema does not allow -------------------------------------------

assert_exit "hookio refuses an undocumented output key" 1 python3 -c "
import sys
sys.path.insert(0, '$ROOT/hooks/_shared')
import hookio
try:
    hookio._emit('PreToolUse', {'surprise': 1})
except hookio.HookIOError:
    sys.exit(1)
sys.exit(0)
"

finish
