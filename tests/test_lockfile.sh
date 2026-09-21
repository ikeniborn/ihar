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

write_lock '{"schema":1,"claude":{"version":"2.1.274"}}'
assert_eq "a pinned value is read" "2.1.274" "$(ihar_lockfile_get claude.version)"
assert_eq "an absent path reads empty" "" "$(ihar_lockfile_get codex.version)"

# Schema 1 shipped an optional transparent-gateway pin. S11 drops that feature, but
# update must still be able to read an installed lockfile before replacing it.
write_lock '{"schema":1,"mitmproxy":{"version":"12.1.1"}}'
assert_exit "a legacy mitmproxy pin remains readable for migration" 0 \
  bash -c "$LOAD
           IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
           ihar_lockfile_get mitmproxy.version >/dev/null"

# An invalid lockfile must not read as an empty one: a caller would take the silence
# for "nothing is pinned" and skip every check. Reading one aborts fail-closed.
write_lock '{"schema":1,"hooks":{"hooks/security-pretool.py":"short"}}'
assert_exit "an invalid lockfile is fail-closed, not silently empty" 3 \
  bash -c "$LOAD
           IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
           ihar_lockfile_get claude.version"

# --- hook integrity is fail-closed in every profile ---------------------------------

write_lock "{\"schema\":1,
             \"hooks\":{\"hooks/security-pretool.py\":\"$REAL_HOOK_SHA\"}}"
assert_exit "a matching hook digest passes" 0 \
  bash -c "$LOAD
           IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
           ihar_store_verify_hooks false"

write_lock "{\"schema\":1,
             \"hooks\":{\"hooks/security-pretool.py\":\"$SHA_B\"}}"
for profile in standard protected; do
  assert_exit "a changed hook is fail-closed under $profile" 3 \
    bash -c "$LOAD
             IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
             IHAR_PROFILE=$profile ihar_store_verify_hooks false"
done

# A pinned hook that is missing is not a hook that passed.
write_lock "{\"schema\":1,
             \"hooks\":{\"hooks/absent.py\":\"$SHA_A\"}}"
assert_exit "a pinned hook that is absent is fail-closed" 3 \
  bash -c "$LOAD
           IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
           ihar_store_verify_hooks false"

# --- release input has no mutation commands ------------------------------------------

write_lock '{"schema":1,"claude":{"version":"2.1.274"}}'
before="$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"
assert_exit "a release value cannot be changed through the lockfile CLI" 2 \
  env PYTHONPATH="$ROOT/lib/python" python3 -m ihar.lockfile \
  --set claude.version 9.9.9 "$IHAR_LOCKFILE"
assert_exit "a store tree cannot be pinned during installation" 2 \
  env PYTHONPATH="$ROOT/lib/python" python3 -m ihar.lockfile \
  --pin-tree hooks "$IHAR_LOCKFILE" "$IHAR_STORE"
assert_eq "rejected mutation commands preserve the release lock" "$before" \
  "$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"

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

# --- native launches consume machine-local receipt evidence ---------------------------

FAKE_CLAUDE="$IHAR_TEST_TMP/claude"
cat > "$FAKE_CLAUDE" <<'SH'
#!/usr/bin/env bash
printf 'claude fake\n'
SH
chmod +x "$FAKE_CLAUDE"

write_lock '{"schema":1,"claude":{"version":"2.1.274"},"hooks":{},"managedHooks":{}}'

write_receipt() {
  local binary_sha lock_sha
  binary_sha="$(sha256sum "$FAKE_CLAUDE" | cut -d' ' -f1)"
  lock_sha="$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"
  printf '{"schema":1,"release_lock_sha256":"%s","installed_at":"2026-09-20T00:00:00Z","components":{"claude":{"version":"2.1.274","binary_sha256":"%s"}}}\n' \
    "$lock_sha" "$binary_sha" > "$IHAR_STORE/install-receipt.json"
}

write_receipt
assert_eq "matching executable bytes are verified by the receipt" "verified" \
  "$(IHAR_CLAUDE_BIN="$FAKE_CLAUDE" ihar_receipt_binary_status claude "$FAKE_CLAUDE")"

printf 'tampered\n' >> "$FAKE_CLAUDE"
assert_eq "changed executable bytes mismatch the receipt" "mismatched" \
  "$(IHAR_CLAUDE_BIN="$FAKE_CLAUDE" ihar_receipt_binary_status claude "$FAKE_CLAUDE")"

standard_status=0
standard_out="$(bash -c "$LOAD
  IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
  IHAR_PROFILE=standard IHAR_VENDOR=claude IHAR_CLAUDE_BIN='$FAKE_CLAUDE' \
  ihar_store_verify_binaries false" 2>&1)" || standard_status=$?
assert_eq "standard continues after an executable mismatch" "0" "$standard_status"
assert_contains "standard warns about receipt mismatch" "$standard_out" "install receipt"

assert_exit "protected rejects an executable mismatch" 3 \
  bash -c "$LOAD
    IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
    IHAR_PROFILE=protected IHAR_VENDOR=claude IHAR_CLAUDE_BIN='$FAKE_CLAUDE' \
    ihar_store_verify_binaries true"
assert_exit "isolated rejects an executable mismatch" 3 \
  bash -c "$LOAD
    IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
    IHAR_PROFILE=isolated IHAR_VENDOR=claude IHAR_CLAUDE_BIN='$FAKE_CLAUDE' \
    ihar_store_verify_binaries true"

rm -f "$IHAR_STORE/install-receipt.json"
assert_eq "an absent receipt has one public status" "missing receipt" \
  "$(ihar_receipt_binary_status claude "$FAKE_CLAUDE")"
assert_eq "an absent receipt wins over an absent executable" "missing receipt" \
  "$(ihar_receipt_binary_status claude "$IHAR_TEST_TMP/absent-claude")"
assert_exit "protected rejects an absent receipt" 3 \
  bash -c "$LOAD
    IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
    IHAR_PROFILE=protected IHAR_VENDOR=claude IHAR_CLAUDE_BIN='$FAKE_CLAUDE' \
    ihar_store_verify_binaries true"
assert_exit "isolated rejects an absent receipt" 3 \
  bash -c "$LOAD
    IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
    IHAR_PROFILE=isolated IHAR_VENDOR=claude IHAR_CLAUDE_BIN='$FAKE_CLAUDE' \
    ihar_store_verify_binaries true"

printf 'not json\n' > "$IHAR_STORE/install-receipt.json"
assert_eq "a malformed receipt has one public status" "missing receipt" \
  "$(ihar_receipt_binary_status claude "$FAKE_CLAUDE")"
assert_exit "protected rejects a malformed receipt" 3 \
  bash -c "$LOAD
    IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
    IHAR_PROFILE=protected IHAR_VENDOR=claude IHAR_CLAUDE_BIN='$FAKE_CLAUDE' \
    ihar_store_verify_binaries true"
assert_exit "isolated rejects a malformed receipt" 3 \
  bash -c "$LOAD
    IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
    IHAR_PROFILE=isolated IHAR_VENDOR=claude IHAR_CLAUDE_BIN='$FAKE_CLAUDE' \
    ihar_store_verify_binaries true"

as_receipt_reader() {
  if (( EUID != 0 )); then
    "$@"
  elif command -v setpriv >/dev/null 2>&1; then
    setpriv --reuid=65534 --regid=65534 --clear-groups "$@"
  elif command -v runuser >/dev/null 2>&1; then
    runuser -u nobody -- "$@"
  else
    return 125
  fi
}

write_receipt
chmod 755 "$IHAR_TEST_TMP" "$IHAR_STORE"
chmod 644 "$IHAR_LOCKFILE"
chmod 000 "$IHAR_STORE/install-receipt.json"
assert_eq "an unreadable receipt has one public status" "missing receipt" \
  "$(as_receipt_reader bash -c "$LOAD
    IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
    ihar_receipt_binary_status claude '$FAKE_CLAUDE'")"
for profile in protected isolated; do
  assert_exit "$profile rejects an unreadable receipt" 3 \
    as_receipt_reader bash -c "$LOAD
      IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
      IHAR_PROFILE='$profile' IHAR_VENDOR=claude IHAR_CLAUDE_BIN='$FAKE_CLAUDE' \
      ihar_store_verify_binaries true"
done
chmod 600 "$IHAR_STORE/install-receipt.json"

rm -f "$IHAR_LOCKFILE" "$IHAR_STORE/install-receipt.json"
no_lock_out="$(bash -c "$LOAD
  IHAR_ROOT='$ROOT' IHAR_LOCKFILE='$IHAR_LOCKFILE' IHAR_STORE='$IHAR_STORE' \
  IHAR_PROFILE=standard IHAR_VENDOR=claude IHAR_CLAUDE_BIN='$FAKE_CLAUDE' \
  ihar_store_verify" 2>&1)"
assert_contains "standard still checks receipt evidence without a release lock" \
  "$no_lock_out" "missing receipt"

finish
