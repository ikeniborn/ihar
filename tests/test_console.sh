#!/usr/bin/env bash
# Console command lifecycle and its refusals (LLD 13.2, gate G6). Failure class: mixed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox

project="$IHAR_TEST_TMP/project"
mkdir -p "$project"

# The command is delivered rather than accepted and ignored.
out="$(cd "$project" && "$ROOT/ihar.sh" console 2>&1)"; status=$?
assert_eq "console status runs without a broker" 0 "$status"
assert_contains "console status says nothing runs" "$out" "not running"

out="$(cd "$project" && "$ROOT/ihar.sh" console frobnicate 2>&1 || true)"
assert_contains "an unknown console action is refused" "$out" \
  "expected start, status, stop or restart"

# The profile field gates the tab, and the shipped profiles carry it.
for name in standard protected; do
  assert_contains "profile $name allows the console" \
    "$(cat "$ROOT/manifests/profiles/$name.json")" '"console": "allow"'
done
assert_contains "the isolated profile refuses the console" \
  "$(cat "$ROOT/manifests/profiles/isolated.json")" '"console": "refuse"'

# G6: a bind that is not loopback aborts before any listener exists.
out="$(IHAR_ROOT="$ROOT" IHAR_STATE_ROOT="$IHAR_STATE_ROOT" \
       PYTHONPATH="$ROOT/lib/python" python3 -m ihar.console.broker --bind 0.0.0.0 2>&1)"; status=$?
assert_eq "a non-loopback bind is exit 2" 2 "$status"
assert_contains "the refusal names loopback" "$out" "loopback only"

# A real start prints a loopback URL carrying the token, and the record follows it.
out="$(cd "$project" && "$ROOT/ihar.sh" console start 2>&1)"; status=$?
assert_eq "console start succeeds" 0 "$status"
assert_contains "console start prints a loopback URL" "$out" "open         http://127.0.0.1:"
assert_contains "console start states the SSH boundary" "$out" "SSH tunnel"

record="$IHAR_STATE_ROOT/console/daemon.json"
assert_exit "the broker records itself" 0 test -f "$record"
assert_eq "the record is owner-only" 600 "$(stat -c '%a' "$record")"
assert_eq "the token is owner-only" 600 "$(stat -c '%a' "$IHAR_STATE_ROOT/console/token")"
assert_contains "the record keeps a digest, not the token" "$(cat "$record")" '"token_sha256"'
token="$(cat "$IHAR_STATE_ROOT/console/token")"
assert_exit "the token itself is absent from the record" 1 grep -qF "$token" "$record"

out="$(cd "$project" && "$ROOT/ihar.sh" console status 2>&1)"
assert_contains "console status reports the running broker" "$out" "running (pid"

# A second start is idempotent rather than a second surface.
out="$(cd "$project" && "$ROOT/ihar.sh" console start 2>&1)"
assert_contains "a second start does not open a second surface" "$out" "already running"

# `ihar check` reports the console truthfully, including the reach of its token.
out="$(cd "$project" && "$ROOT/ihar.sh" check 2>&1 || true)"
assert_contains "check reports the console state" "$out" "console      running"
assert_contains "check states the token reach" "$out" "one token starts launches in each"

out="$(cd "$project" && "$ROOT/ihar.sh" console stop 2>&1)"
assert_contains "console stop reports the pid it stopped" "$out" "stopped (pid"
assert_exit "stopping removes the record" 1 test -f "$record"

out="$(cd "$project" && "$ROOT/ihar.sh" check 2>&1 || true)"
assert_contains "check reports a stopped console" "$out" "console      stopped"

# Nothing in the console tree is terminal output: only records, the token and stderr.
mapfile -t stray < <(find "$IHAR_STATE_ROOT/console" -type f \
  ! -name '*.json' ! -name token ! -name lock ! -name broker.err 2>/dev/null)
assert_eq "no terminal output is written to disk" 0 "${#stray[@]}"

finish
