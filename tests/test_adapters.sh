#!/usr/bin/env bash
# Argument parsing and both adapters (LLD 3.1, 3.2, 5.1 to 5.4).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox

PROJECT="$IHAR_TEST_TMP/proj"
mkdir -p "$PROJECT"

ihar() {
  ( cd "$PROJECT" && IHAR_STORE="$IHAR_STORE" IHAR_STATE_ROOT="$IHAR_STATE_ROOT" \
      "$ROOT/ihar.sh" "$@" ) 2>&1
}
argv() { ihar --dry-run "$@" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["argv"][1:]))'; }

# --- the passthrough separator differs per vendor ----------------------------------
#
# Measured, not assumed: `claude -- mcp list` dispatches the subcommand, while
# `codex -- mcp list` answers "unexpected argument 'list' found". Sending Codex a
# separator it rejects would break every vendor subcommand.

assert_contains "claude keeps the -- separator" "$(argv claude -- mcp list)" "-- mcp list"
assert_eq "codex takes the tokens unseparated" "mcp list" "$(argv codex -- mcp list)"
assert_exit "codex is handed no separator at all" 1 \
  bash -c "[[ ' $(argv codex -- mcp list) ' == *' -- '* ]]"

caps_claude="$(ihar --dry-run claude >/dev/null; bash -c "
  source '$ROOT/lib/adapters/claude.sh'; adapter_claude_capabilities")"
caps_codex="$(bash -c "source '$ROOT/lib/adapters/codex.sh'; adapter_codex_capabilities")"
assert_contains "claude reports the -- separator" "$caps_claude" '"passthrough_separator": "--"'
assert_contains "codex reports no separator" "$caps_codex" '"passthrough_separator": "none"'

for vendor in claude codex; do
  caps="$(bash -c "source '$ROOT/lib/adapters/$vendor.sh'; adapter_${vendor}_capabilities")"
  assert_exit "$vendor capabilities validate" 0 \
    bash -c "PYTHONPATH='$ROOT/lib/python' python3 -c '
import json, sys
from ihar import jsonio
jsonio.check(\"capabilities\", json.load(sys.stdin))' <<< '$caps'"
done

# --- launch flags reach the right vendor spelling ------------------------------------

assert_contains "claude takes --model" "$(argv claude --model opus)" "--model opus"
assert_contains "codex takes -m" "$(argv codex --model gpt)" "-m gpt"
assert_contains "claude takes --effort" "$(argv claude --effort high)" "--effort high"
assert_contains "codex maps effort onto a config override" "$(argv codex --effort high)" \
  'model_reasoning_effort="high"'
assert_contains "claude takes a session name" "$(argv claude --name 'my run')" "-n my run"

# ihar generates the Claude session id so the index knows it before the vendor
# starts. Codex has no equivalent, which is why its id is learned from a hook.
assert_contains "claude gets a generated session id" "$(argv claude)" "--session-id"
assert_exit "codex gets no session id" 1 \
  bash -c "[[ '$(argv codex)' == *--session-id* ]]"

assert_contains "claude resumes" "$(argv claude --resume abc)" "--resume abc"
assert_contains "claude forks a resumed session" "$(argv claude --resume abc --fork)" "--fork-session"
assert_contains "codex resumes" "$(argv codex --resume abc)" "resume abc"
assert_contains "codex forks with its own subcommand" "$(argv codex --resume abc --fork)" "fork abc"

# --- unknown flags are errors, never forwarded ---------------------------------------
#
# iclaude forwards any token it does not recognise, so a mistyped harness flag
# silently becomes a vendor argument and the setting asked for is not applied.

assert_exit "an unknown launch flag is a usage error" 2 ihar claude --nonesuch
out="$(ihar claude --nonesuch)"
assert_contains "and it says how to forward it deliberately" "$out" "use -- to forward it"

assert_exit "an unknown global flag is a usage error" 2 ihar --nonesuch claude
assert_exit "an unknown command is a usage error" 2 ihar nonesuch

# A global flag written after the command is a position mistake. Telling the user to
# forward it would send a harness flag to the vendor, which is the defect the parser
# exists to prevent.
out="$(ihar claude --dry-run)"
assert_contains "a misplaced global flag says where it belongs" "$out" "is a global flag and goes before the command"

assert_exit "a flag needing a value says so" 2 ihar claude --model
assert_exit "-- before a command is refused" 2 ihar -- claude

# --- the dry run never prints a value -------------------------------------------------
# It is pasted into issues and pull requests; a leaked token there would be a worse
# defect than whatever was being diagnosed.

export SECRET_TOKEN=hunter2
out="$(ihar --dry-run claude)"
assert_exit "no environment value appears in a dry run" 1 \
  bash -c "[[ '$out' == *hunter2* ]]"
unset SECRET_TOKEN

# --- vendor binaries are never taken from PATH ----------------------------------------

assert_contains "claude runs from the pinned node prefix" "$(ihar --dry-run claude)" "ihar-nvm/npm-global/bin/claude"
assert_contains "codex runs from the store" "$(ihar --dry-run codex)" "/store/bin/codex"

# --- a missing binary is a runtime error with a remedy ---------------------------------

assert_exit "launching without the binary installed fails" 1 ihar codex
assert_contains "and names the remedy" "$(ihar codex)" "run 'ihar install'"

finish
