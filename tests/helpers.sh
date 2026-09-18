#!/usr/bin/env bash
# Dependency-free test helpers, lifted from icodex:tests/helpers.sh.
#
# Isolation is the caller's job and is mandatory: every test points IHAR_STORE and
# IHAR_STATE_ROOT at its own temporary directory, so a test never reads or destroys
# the real store, state root or vendor homes.
set -uo pipefail

PASS=0
FAIL=0

assert_eq() { # <desc> <expected> <actual>
  local desc="$1" exp="$2" act="$3"
  if [[ "$exp" == "$act" ]]; then
    echo "PASS [$desc]"; PASS=$((PASS+1))
  else
    echo "FAIL [$desc]: expected '$exp' got '$act'"; FAIL=$((FAIL+1))
  fi
}

assert_exit() { # <desc> <expected_code> <cmd...>
  local desc="$1" exp="$2"; shift 2
  local code=0
  "$@" >/dev/null 2>&1 || code=$?
  if [[ "$code" == "$exp" ]]; then
    echo "PASS [$desc]"; PASS=$((PASS+1))
  else
    echo "FAIL [$desc]: exit $code want $exp"; FAIL=$((FAIL+1))
  fi
}

assert_contains() { # <desc> <haystack> <needle>
  local desc="$1" hay="$2" need="$3"
  if grep -qF -- "$need" <<<"$hay"; then
    echo "PASS [$desc]"; PASS=$((PASS+1))
  else
    echo "FAIL [$desc]: '$need' not found"; FAIL=$((FAIL+1))
  fi
}

# ihar_sandbox <desc> — export IHAR_STORE and IHAR_STATE_ROOT into a fresh temporary
# directory and register its removal. Call once per test file, before anything reads
# either root.
ihar_sandbox() {
  IHAR_TEST_TMP="$(mktemp -d -t ihar-test-XXXXXX)"
  export IHAR_STORE="$IHAR_TEST_TMP/store"
  export IHAR_STATE_ROOT="$IHAR_TEST_TMP/state"
  mkdir -p "$IHAR_STORE" "$IHAR_STATE_ROOT"
  trap 'rm -rf "$IHAR_TEST_TMP"' EXIT
}

finish() {
  echo "---"
  echo "PASS=$PASS FAIL=$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
