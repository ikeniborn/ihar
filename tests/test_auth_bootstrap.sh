#!/usr/bin/env bash
# The authentication carve-out and the two refusals it must not widen (LLD 14.2).
#
# A machine with no vendor credentials could not become one with credentials: the launch
# refused for pin drift, the fix was `ihar install`, that could not activate without
# conformance, and conformance needs an authenticated vendor. The carve-out breaks that
# circle for authentication subcommands only, and these cases are what keeps it narrow.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox

source "$ROOT/lib/cli/commands.sh"

IHAR_PASSTHROUGH=(); IHAR_ARGS=(); IHAR_FLAG_RESUME=""; IHAR_FLAG_FORK=false
IHAR_FLAG_WEB=false; IHAR_ACP_MODE=false

# The spellings both vendors actually use, measured from their help output.
for word in login logout auth setup-token; do
  IHAR_PASSTHROUGH=("$word")
  assert_exit "'$word' is an authentication command" 0 ihar_launch_is_authentication
done

# Everything else is an ordinary launch and keeps the gate.
IHAR_PASSTHROUGH=()
assert_exit "a bare session is not authentication" 1 ihar_launch_is_authentication
for word in mcp resume exec agents; do
  IHAR_PASSTHROUGH=("$word")
  assert_exit "'$word' is not authentication" 1 ihar_launch_is_authentication
done

# A login spelling cannot be used to smuggle a session past the gate.
IHAR_PASSTHROUGH=(login); IHAR_ARGS=(--some-argument)
assert_exit "a login with other positional arguments is refused the carve-out" 1 \
  ihar_launch_is_authentication
IHAR_ARGS=()

IHAR_FLAG_RESUME="0199f3a1-7c2e-7a41-9b0d-3f9a1cbd2e41"
assert_exit "a resume never counts as authentication" 1 ihar_launch_is_authentication
IHAR_FLAG_RESUME=""

IHAR_FLAG_FORK=true
assert_exit "a fork never counts as authentication" 1 ihar_launch_is_authentication
IHAR_FLAG_FORK=false

IHAR_FLAG_WEB=true
assert_exit "a web launch never counts as authentication" 1 ihar_launch_is_authentication
IHAR_FLAG_WEB=false

IHAR_ACP_MODE=true
assert_exit "an ACP launch never counts as authentication" 1 ihar_launch_is_authentication
IHAR_ACP_MODE=false

# A pin that the store does not carry is reported as missing, not as changed: the two
# are different problems, and the user fixes them differently.
lock="$IHAR_TEST_TMP/lock.json"
printf '%s' '{"schema":1,"hooks":{"hooks/absent.py":"0000000000000000000000000000000000000000000000000000000000000000"}}' > "$lock"
out="$(PYTHONPATH="$ROOT/lib/python" python3 -m ihar.lockfile --verify-map hooks "$lock" "$IHAR_TEST_TMP" 2>&1)"
assert_contains "an absent pinned file is reported as missing" "$out" "missing "

mkdir -p "$IHAR_TEST_TMP/hooks"
printf 'not the pinned bytes\n' > "$IHAR_TEST_TMP/hooks/absent.py"
out="$(PYTHONPATH="$ROOT/lib/python" python3 -m ihar.lockfile --verify-map hooks "$lock" "$IHAR_TEST_TMP" 2>&1)"
assert_contains "a rewritten pinned file is reported as changed" "$out" "changed "

finish
