#!/usr/bin/env bash
# Pins and their verification (LLD 14.1, 14.2). The severity of a mismatch is the
# profile's decision, which is why the profile is resolved before this runs.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
source "$ROOT/lib/core/logging.sh"
source "$ROOT/lib/core/init.sh"
IHAR_ROOT="$ROOT"; export IHAR_ROOT
source "$ROOT/lib/store/lockfile.sh"

# Every subshell below needs init.sh too: without it ihar_python is undefined, and
# the point of these checks is that an unavailable verifier is fail-closed rather
# than silently clean.
LOAD="source '$ROOT/lib/core/logging.sh'
      source '$ROOT/lib/core/init.sh'
      source '$ROOT/lib/store/lockfile.sh'"

export IHAR_LOCKFILE="$IHAR_TEST_TMP/.ihar-lockfile.json"
SHA_A="$(printf 'a%.0s' {1..64})"
SHA_B="$(printf 'b%.0s' {1..64})"

write_lock() { # <json>
  printf '%s\n' "$1" > "$IHAR_LOCKFILE"
}

mkdir -p "$IHAR_STORE/hooks"
printf 'pretend hook\n' > "$IHAR_STORE/hooks/security-pretool.py"
REAL_HOOK_SHA="$(sha256sum "$IHAR_STORE/hooks/security-pretool.py" | cut -c1-64)"

# --- reading -----------------------------------------------------------------------

write_lock "{\"schema\":1,\"installedAt\":\"2026-09-18T10:00:00Z\",
             \"claude\":{\"version\":\"2.1.274\",\"binarySha256\":\"$SHA_A\"}}"
assert_eq "a pinned value is read" "2.1.274" "$(ihar_lockfile_get claude.version)"
assert_eq "an absent path reads empty" "" "$(ihar_lockfile_get codex.version)"

# Schema 1 shipped an optional transparent-gateway pin. S11 drops that feature, but
# update must still be able to read an installed lockfile before replacing it.
write_lock '{"schema":1,"installedAt":"2026-09-18T10:00:00Z","mitmproxy":{"version":"12.1.1"}}'
assert_exit "a legacy mitmproxy pin remains readable for migration" 0 \
  bash -c "$LOAD
           IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
           ihar_lockfile_get mitmproxy.version >/dev/null"

# An invalid lockfile must not read as an empty one: a caller would take the silence
# for "nothing is pinned" and skip every check. Reading one aborts fail-closed.
write_lock '{"schema":1,"installedAt":"not-a-timestamp"}'
assert_exit "an invalid lockfile is fail-closed, not silently empty" 3 \
  bash -c "$LOAD
           IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
           ihar_lockfile_get claude.version"

# --- hook integrity is fail-closed in every profile ---------------------------------

write_lock "{\"schema\":1,\"installedAt\":\"2026-09-18T10:00:00Z\",
             \"hooks\":{\"hooks/security-pretool.py\":\"$REAL_HOOK_SHA\"}}"
assert_exit "a matching hook digest passes" 0 \
  bash -c "$LOAD
           IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
           ihar_store_verify_hooks false"

write_lock "{\"schema\":1,\"installedAt\":\"2026-09-18T10:00:00Z\",
             \"hooks\":{\"hooks/security-pretool.py\":\"$SHA_B\"}}"
for profile in standard protected; do
  assert_exit "a changed hook is fail-closed under $profile" 3 \
    bash -c "$LOAD
             IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
             IHAR_PROFILE=$profile ihar_store_verify_hooks false"
done

# A pinned hook that is missing is not a hook that passed.
write_lock "{\"schema\":1,\"installedAt\":\"2026-09-18T10:00:00Z\",
             \"hooks\":{\"hooks/absent.py\":\"$SHA_A\"}}"
assert_exit "a pinned hook that is absent is fail-closed" 3 \
  bash -c "$LOAD
           IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
           ihar_store_verify_hooks false"

# --- a binary mismatch takes its severity from the profile ---------------------------

mkdir -p "$(dirname "$IHAR_TEST_TMP/bin/claude")"
mkdir -p "$IHAR_TEST_TMP/bin"
printf 'pretend binary\n' > "$IHAR_TEST_TMP/bin/claude"
write_lock "{\"schema\":1,\"installedAt\":\"2026-09-18T10:00:00Z\",
             \"claude\":{\"version\":\"2.1.274\",\"binarySha256\":\"$SHA_B\"}}"

assert_exit "a changed binary only warns under standard" 0 \
  bash -c "$LOAD
           IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
           IHAR_CLAUDE_BIN='$IHAR_TEST_TMP/bin/claude' IHAR_CODEX_BIN=/nowhere \
           ihar_store_verify_binaries false"

assert_exit "a changed binary is fail-closed elsewhere" 3 \
  bash -c "$LOAD
           IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
           IHAR_PROFILE=protected IHAR_CLAUDE_BIN='$IHAR_TEST_TMP/bin/claude' \
           IHAR_CODEX_BIN=/nowhere ihar_store_verify_binaries true"

# --- an absent lockfile is not a neutral state under an enforced profile --------------

rm -f "$IHAR_LOCKFILE"
assert_exit "no lockfile is tolerated under standard" 0 \
  bash -c "$LOAD
           IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
           IHAR_PROFILE=standard ihar_store_verify"

assert_exit "no lockfile is fail-closed under an enforced profile" 3 \
  bash -c "$LOAD
           IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
           IHAR_PROFILE=protected ihar_store_verify"

finish
