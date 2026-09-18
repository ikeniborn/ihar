#!/usr/bin/env bash
# The two lock modes (LLD 4.3). The point of the split is that a security mutation
# must never proceed unlocked, while the session index may.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
source "$ROOT/lib/core/logging.sh"
source "$ROOT/lib/core/lock.sh"

LOCK="$IHAR_TEST_TMP/test.lock"

# --- the happy path runs the command and returns its status ---------------------

assert_eq "required lock runs the command" "ran" \
  "$(ihar_with_lock --required "$LOCK" 5 echo ran)"
assert_eq "best-effort lock runs the command" "ran" \
  "$(ihar_with_lock --best-effort "$LOCK" 5 echo ran)"

assert_exit "the command's exit status is propagated" 3 \
  ihar_with_lock --required "$LOCK" 5 bash -c 'exit 3'

# --- stderr survives taking a lock ------------------------------------------------
#
# Regression. `exec {fd}>"$lockfile" 2>/dev/null` applies the stderr redirection to
# the shell itself, permanently, so every diagnostic after the first lock vanished —
# including the abort message of a fail-closed check. The symptom was a launch that
# exited non-zero and printed nothing at all.

after_lock="$(bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/lock.sh'
                       ihar_with_lock --required '$LOCK' 5 true
                       ihar_warn 'still audible'" 2>&1 >/dev/null)"
assert_contains "a warning after a lock still reaches stderr" "$after_lock" "still audible"

after_die="$(bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/lock.sh'
                      ihar_with_lock --required '$LOCK' 5 true
                      ihar_die 3 'fail-closed message'" 2>&1 >/dev/null)"
assert_contains "a fail-closed abort after a lock is not silent" "$after_die" "fail-closed message"

# --- a mode is mandatory --------------------------------------------------------

assert_exit "a missing mode is a usage error" 2 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/lock.sh';
           ihar_with_lock '$LOCK' 5 true"

# --- without flock the two modes diverge, which is the whole point ---------------

no_flock() { # <mode>
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/lock.sh';
           IHAR_FLOCK_BIN=definitely-not-installed ihar_with_lock '$1' '$LOCK' 1 echo ran" \
    2>/dev/null
}

assert_exit "required lock without flock is fail-closed" 3 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/lock.sh';
           IHAR_FLOCK_BIN=definitely-not-installed ihar_with_lock --required '$LOCK' 1 true"
assert_eq "best-effort lock without flock still runs" "ran" "$(no_flock --best-effort)"

# --- a held lock: required aborts on timeout, best-effort proceeds ----------------

holder_start() {
  ( flock -x 9; sleep 5 ) 9>"$LOCK" &
  HOLDER=$!
  sleep 0.3
}
holder_stop() { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; }

if command -v flock >/dev/null 2>&1; then
  holder_start
  assert_exit "required lock times out fail-closed" 3 \
    bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/lock.sh';
             ihar_with_lock --required '$LOCK' 1 true"
  out="$(bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/lock.sh';
                  ihar_with_lock --best-effort '$LOCK' 1 echo ran" 2>/dev/null)"
  assert_eq "best-effort lock proceeds after a timeout" "ran" "$out"
  holder_stop
else
  echo "SKIP [contended lock cases]: flock is not installed"
fi

# --- every security call site asks for --required --------------------------------
# A new caller that forgets the mode would be a silent downgrade, so the call sites
# are asserted rather than trusted.

for module in state/runtime.sh; do
  calls="$(grep -o 'ihar_with_lock --[a-z-]*' "$ROOT/lib/$module" | sort -u)"
  assert_eq "lib/$module locks are required" "ihar_with_lock --required" "$calls"
done

finish
