#!/usr/bin/env bash
# The MCP registry, its renderers and its input policy (LLD 7.1, 7.2, 7.3).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
export PYTHONPATH="$ROOT/lib/python"

REGISTRY="$IHAR_TEST_TMP/registry.json"
HOOK="$ROOT/hooks/security-pretool.py"

write_registry() { printf '%s\n' "$1" > "$REGISTRY"; }

# Notices go to stderr and the rendered body to stdout, so a test that cares which
# is which has to ask for one of them rather than merging both.
render() { # <vendor> <profile> — body and notices together
  python3 -m ihar.render.mcp "$1" "$2" "$REGISTRY" 2>&1
}
body() { # <vendor> <profile> — the rendered configuration alone
  python3 -m ihar.render.mcp "$1" "$2" "$REGISTRY" 2>/dev/null
}

BOTH='{"schema":1,"servers":[
  {"name":"remote","transport":"http","url":"https://wiki.example/mcp",
   "headers":{"Authorization":"Bearer ${WIKI_TOKEN}"},"env_names":["WIKI_TOKEN"],
   "scope":"user","profiles":["*"]},
  {"name":"local","transport":"stdio","command":"iwiki-mcp","args":["--quiet"],
   "env":{"DIR":"${IHAR_PROJECT_ROOT}"},"env_names":["KEY"],
   "scope":"project","profiles":["standard"]}]}'

export IHAR_PROJECT_ROOT="$IHAR_TEST_TMP/proj"

# --- the shipped registry validates and renders ---------------------------------------

assert_exit "the shipped registry validates" 0 python3 -c "
from ihar import jsonio
jsonio.read('mcp-registry', '$ROOT/manifests/mcp/registry.json')"

remote_codex="$(IHAR_IWIKI_REMOTE_URL=https://wiki.example/mcp \
  IWIKI_REMOTE_TOKEN=test-token REGISTRY="$ROOT/manifests/mcp/registry.json" \
  body codex standard)"
assert_contains "the shipped remote URL is concrete for Codex" "$remote_codex" \
  'url = "https://wiki.example/mcp"'
assert_contains "the shipped remote token is forwarded by name" "$remote_codex" \
  'bearer_token_env_var = "IWIKI_REMOTE_TOKEN"'
assert_eq "the shipped remote token value is absent" "0" \
  "$(grep -c 'test-token' <<<"$remote_codex")"

# --- each vendor gets its own spelling ---------------------------------------------------

write_registry "$BOTH"
claude_out="$(render claude standard)"
codex_out="$(render codex standard)"

assert_contains "claude gets an http entry" "$claude_out" '"type": "http"'
assert_contains "claude keeps the header" "$claude_out" '"Authorization"'
assert_contains "codex spells http as a url" "$codex_out" 'url = "https://wiki.example/mcp"'
assert_contains "codex forwards the token by variable name" "$codex_out" \
  'bearer_token_env_var = "WIKI_TOKEN"'

# A secret is forwarded by name and never written into a rendered file.
assert_eq "no token value appears in the claude render" "0" \
  "$(grep -c 'Bearer [A-Za-z0-9]' <<<"$claude_out")"
assert_contains "the stdio env is expanded by the renderer" "$codex_out" \
  "DIR = \"$IHAR_PROJECT_ROOT\""
assert_contains "and env_vars forwards the rest by name" "$codex_out" 'env_vars = ["KEY"]'

# --- the profile allowlist decides what is offered -----------------------------------------

assert_eq "a server not offered to a profile is absent from the render" "0" \
  "$(grep -c 'mcp_servers.local' <<<"$(body codex protected)")"
assert_contains "and the reason is reported" "$(render codex protected)" \
  "local: skipped, not offered to profile protected"

# --- requires_env skips rather than rendering something that cannot start --------------------

NEEDS='{"schema":1,"servers":[
  {"name":"remote","transport":"http","url":"${NOT_SET_ANYWHERE}",
   "requires_env":["NOT_SET_ANYWHERE"],"scope":"user","profiles":["*"]}]}'
write_registry "$NEEDS"
assert_contains "an unmet requires_env skips the server" "$(render claude standard)" \
  "remote: skipped, NOT_SET_ANYWHERE is not set"

# --- a reference Codex cannot expand is fail-closed --------------------------------------------
#
# Codex does not expand environment references in its configuration, so one that
# survived the render would reach the vendor as a literal and the server would fail
# to start with a message about a path that does not exist.

LEFTOVER='{"schema":1,"servers":[
  {"name":"local","transport":"stdio","command":"x",
   "env":{"HOME_DIR":"${SOMETHING_ELSE}"},"scope":"project","profiles":["*"]}]}'
write_registry "$LEFTOVER"
assert_exit "an unexpanded reference in a codex render is fail-closed" 3 \
  bash -c "PYTHONPATH='$ROOT/lib/python' python3 -m ihar.render.mcp codex standard '$REGISTRY'"
assert_contains "and it names the reference" \
  "$(render codex standard)" 'which Codex does not expand'
assert_exit "the same reference is fine for claude, which expands it" 0 \
  bash -c "PYTHONPATH='$ROOT/lib/python' python3 -m ihar.render.mcp claude standard '$REGISTRY'"

# --- a header Codex cannot express is a notice, not a failure ------------------------------------

EXTRA='{"schema":1,"servers":[
  {"name":"remote","transport":"http","url":"https://x.example",
   "headers":{"X-Tenant":"acme"},"scope":"user","profiles":["*"]}]}'
write_registry "$EXTRA"
assert_contains "a non-bearer header is reported as a capability gap" "$(render codex standard)" \
  "Codex expresses only a bearer token"
assert_exit "but the render still succeeds" 0 \
  bash -c "PYTHONPATH='$ROOT/lib/python' python3 -m ihar.render.mcp codex standard '$REGISTRY'"
assert_contains "and claude keeps the header" "$(render claude standard)" '"X-Tenant"'

# --- the input policy: MCP is a second egress channel ----------------------------------------------
#
# A registered server sends whatever it is given, wherever it points, and the model
# egress gateway never sees that traffic. This hook is the only content check on it.

mcp_call='{"hook_event_name":"PreToolUse","tool_name":"mcp__iwiki-remote__wiki_write_page",
  "tool_input":{"domain":"ihar","markdown":"the key is sk-ant-abcdefghijklmnopqrstuvwxyz0123",
  "nested":{"deeper":["ghp_aaaaaaaaaaaaaaaaaaaaaa"]}}}'

out="$(printf '%s' "$mcp_call" | python3 -I "$HOOK" --vendor claude 2>/dev/null)"
assert_contains "an MCP argument is rewritten" "$out" "updatedInput"
assert_contains "a secret nested in an object is masked" "$out" "REDACTED-anthropic-key"
assert_contains "and one nested in an array too" "$out" "REDACTED-github-token"
assert_eq "no secret survives anywhere in the tree" "0" \
  "$(grep -cE 'sk-ant-abcdefghij|ghp_aaaaaaaaaa' <<<"$out")"

clean_call='{"hook_event_name":"PreToolUse","tool_name":"mcp__iwiki-remote__wiki_read_page",
  "tool_input":{"domain":"ihar","slug":"overview"}}'
assert_eq "a clean MCP call is allowed unchanged" "0" \
  "$(printf '%s' "$clean_call" | python3 -I "$HOOK" --vendor claude >/dev/null 2>&1; echo $?)"

finish
