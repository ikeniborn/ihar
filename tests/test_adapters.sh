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

# --- a real launch actually execs the agent ---------------------------------------------
#
# Regression, and the reason this fixture exists. Every other case here uses
# --dry-run, which returns before the exec; with the exec path untested, the
# launcher spent a whole slice unsetting IHAR_ARGV immediately before expanding it,
# so `exec "${IHAR_ARGV[@]}"` became a bare `exec` — a no-op that started no agent
# and exited 0. The harness reported success and did nothing.

FAKE="$IHAR_TEST_TMP/fake-codex"
cp "$ROOT/tests/fakes/record-exec.sh" "$FAKE"
chmod +x "$FAKE"
RECORD="$IHAR_TEST_TMP/record"

real() { # <args...>
  ( cd "$PROJECT" && IHAR_STORE="$IHAR_STORE" IHAR_STATE_ROOT="$IHAR_STATE_ROOT" \
      IHAR_CODEX_BIN="$FAKE" IHAR_FAKE_RECORD="$RECORD" \
      "$ROOT/ihar.sh" "$@" ) 2>&1
}

rm -f "$RECORD"
real codex -- mcp list >/dev/null
assert_exit "a launch reaches the agent binary" 0 test -f "$RECORD"
assert_contains "and hands it the passthrough" "$(cat "$RECORD" 2>/dev/null)" $'arg\tmcp'

rm -f "$RECORD"
real codex "fix the bug" >/dev/null
assert_contains "a positional prompt reaches the agent" "$(cat "$RECORD" 2>/dev/null)" $'arg\tfix the bug'

assert_exit "two prompts are a usage error" 2 real codex "one" "two"

# --- launcher state never reaches the agent's environment ---------------------------------
#
# The environment map used to sweep every IHAR_* variable and export it de-prefixed,
# so the parser's own state arrived as COMMAND, TRACE and FLAG_MODEL — names other
# tools in the agent's shell honour.

rm -f "$RECORD"
( cd "$PROJECT" && IHAR_STORE="$IHAR_STORE" IHAR_STATE_ROOT="$IHAR_STATE_ROOT" \
    IHAR_CODEX_BIN="$FAKE" IHAR_FAKE_RECORD="$RECORD" IHAR_TRACE="" \
    "$ROOT/ihar.sh" codex --model gpt ) >/dev/null 2>&1
child_env="$(grep '^env' "$RECORD" 2>/dev/null | cut -f2 | sort)"
for leaked in COMMAND TRACE FLAG_MODEL FLAG_DRY_RUN FLAG_JSON FLAG_FORK FLAG_WEB ARGV SUBCOMMAND; do
  assert_exit "the agent does not inherit $leaked" 1 \
    bash -c "grep -qx '$leaked' <<< '$child_env'"
done
assert_contains "but it does inherit its own vendor variables" "$child_env" "CODEX_HOME"

# --- flags the harness accepts but does not yet enforce -------------------------------------
#
# The usage text advertises them. Ignoring one silently would make the harness report
# success while doing the opposite of what was asked.

for flag in "--web"; do
  # shellcheck disable=SC2086
  assert_exit "$flag is refused rather than ignored" 2 ihar codex $flag
done
assert_contains "and the refusal names the slice" "$(ihar codex --web)" "slice S12 delivers it"
assert_exit "--fork without --resume is a usage error" 2 ihar codex --fork

# --approval and --mask-level were on that list until slice S7 delivered them. The
# masking flag now meets the floor rule instead: under `standard` there is no
# gateway, so any level above `off` is refused for a reason rather than as a stub.
assert_exit "--approval is accepted now that it is rendered" 0 ihar --dry-run codex --approval never
out="$(ihar codex --mask-level secrets)"
assert_contains "--mask-level is enforced rather than ignored" "$out" \
  "has no model egress gateway"

finish
