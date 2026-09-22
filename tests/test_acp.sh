#!/usr/bin/env bash
# Experimental ACP launcher: pinned adapter, runtime environment and profile gate (LLD 13).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox

PROJECT="$IHAR_TEST_TMP/proj"
mkdir -p "$PROJECT"
cp -R "$ROOT/hooks" "$ROOT/manifests" "$ROOT/skills" "$IHAR_STORE/"

CLAUDE_ACP="$IHAR_TEST_TMP/claude-agent-acp"
CODEX_ACP="$IHAR_TEST_TMP/codex-acp"
CLAUDE_BIN="$IHAR_TEST_TMP/claude"
CODEX_BIN="$IHAR_TEST_TMP/codex"
RECORD="$IHAR_TEST_TMP/acp-record"
IHAR_LOCKFILE="$IHAR_TEST_TMP/.ihar-lockfile.json"
printf '%s\n' '{"schema":1,"claude":{"version":"2.1.274"},"codex":{"version":"0.154.0","tarball":"https://example.invalid/codex.tgz","prefix":"package/vendor/x86_64-unknown-linux-musl","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"acp":{"claude-agent-acp":"0.79.0","codex-acp":"6ec22f3"}}' > "$IHAR_LOCKFILE"

for binary in "$CLAUDE_ACP" "$CODEX_ACP" "$CLAUDE_BIN" "$CODEX_BIN"; do
  cp "$ROOT/tests/fakes/record-exec.sh" "$binary"
  chmod +x "$binary"
done
mkdir -p "$IHAR_STORE/acp"
printf '0.79.0\n6ec22f3\n' > "$IHAR_STORE/acp/.versions"
printf 'claude-agent-acp\t%s\ncodex-acp\t%s\n' \
  "$(sha256sum "$CLAUDE_ACP" | cut -d' ' -f1)" \
  "$(sha256sum "$CODEX_ACP" | cut -d' ' -f1)" > "$IHAR_STORE/acp/.digests"

write_receipt() {
  PYTHONPATH="$ROOT/lib/python" python3 -m ihar.install_receipt build \
    "$IHAR_LOCKFILE" "$IHAR_STORE/install-receipt.json" "$CLAUDE_BIN" "$CODEX_BIN"
}
write_receipt

ihar() {
  local test_root="${IHAR_TEST_ROOT:-$ROOT}"
  ( cd "$PROJECT" && IHAR_ROOT="$test_root" \
      IHAR_STORE="$IHAR_STORE" IHAR_STATE_ROOT="$IHAR_STATE_ROOT" \
      IHAR_LOCKFILE="$IHAR_LOCKFILE" \
      IHAR_CLAUDE_BIN="$CLAUDE_BIN" IHAR_CODEX_BIN="$CODEX_BIN" \
      IHAR_CLAUDE_ACP_BIN="$CLAUDE_ACP" IHAR_CODEX_ACP_BIN="$CODEX_ACP" \
      IHAR_FAKE_RECORD="$RECORD" "$ROOT/ihar.sh" "$@" ) 2>&1
}

# Removing command parsing or accepting a third positional would make an ACP client
# start an unintended program instead of receiving a usage error.
assert_exit "ACP requires a known vendor" 2 ihar --dry-run acp gemini
assert_exit "ACP accepts exactly one vendor" 2 ihar --dry-run acp claude extra
assert_exit "ACP rejects adapter arguments" 2 ihar --dry-run acp claude -- extra

claude_dry="$(ihar --dry-run acp claude)"
codex_dry="$(ihar --dry-run acp codex)"
assert_contains "Claude ACP selects the pinned adapter" "$claude_dry" "$CLAUDE_ACP"
assert_contains "Codex ACP selects the pinned adapter" "$codex_dry" "$CODEX_ACP"

# The refusal is a profile decision and must happen before store verification. An
# empty store would otherwise turn this into exit 3 and hide the actionable ACP gap.
assert_exit "protected refuses ACP before store checks" 2 \
  ihar --profile protected --dry-run acp claude
refusal="$(ihar --profile protected --dry-run acp codex)"
assert_contains "ACP refusal names the profile" "$refusal" \
  "profile 'protected' refuses experimental ACP mode"
assert_contains "ACP refusal names the hook gap" "$refusal" "claude-agent-acp #144"
assert_contains "ACP refusal names the sandbox gap" "$refusal" "codex-acp #310/#477"
assert_exit "isolated refuses ACP" 2 ihar --profile isolated --dry-run acp codex

# Run the real exec boundary. These assertions fail if the adapter receives a native
# agent argv or if its vendor-specific runtime paths are not exported.
rm -f "$RECORD"
ihar acp claude >/dev/null
claude_record="$(cat "$RECORD")"
assert_contains "Claude ACP receives CLAUDE_CONFIG_DIR" "$claude_record" \
  $'env\tCLAUDE_CONFIG_DIR'
assert_contains "Claude ACP receives the pinned CLI path" "$claude_record" \
  $'env\tCLAUDE_CODE_EXECUTABLE'
assert_exit "Claude ACP receives no native CLI arguments" 1 \
  bash -c "grep -q \$'^arg\\t' '$RECORD'"

rm -f "$RECORD"
ihar acp codex >/dev/null
codex_record="$(cat "$RECORD")"
assert_contains "Codex ACP receives CODEX_HOME" "$codex_record" $'env\tCODEX_HOME'
assert_contains "Codex ACP receives the pinned CLI path" "$codex_record" $'env\tCODEX_PATH'
assert_exit "Codex ACP receives no native CLI arguments" 1 \
  bash -c "grep -q \$'^arg\\t' '$RECORD'"
assert_eq "ACP creates no native launch claims" "0" \
  "$(find "$IHAR_STATE_ROOT" -path '*/launches/*' -type f 2>/dev/null | wc -l)"
assert_eq "ACP starts no managed Codex daemon" "0" \
  "$(find "$IHAR_STATE_ROOT" -path '*/daemons/*' -type f 2>/dev/null | wc -l)"

# A non-standard test profile keeps ACP allowed while making receipt failure
# fail-closed. This isolates receipt ordering from the shipped protected/isolated
# ACP refusal without inventing receipt fields for the adapter itself.
ACP_TEST_ROOT="$IHAR_TEST_TMP/acp-root"
mkdir -p "$ACP_TEST_ROOT"
cp -R "$ROOT/manifests" "$ACP_TEST_ROOT/"
ln -s "$ROOT/lib" "$ACP_TEST_ROOT/lib"
ln -s "$ROOT/hooks" "$ACP_TEST_ROOT/hooks"
ln -s "$ROOT/skills" "$ACP_TEST_ROOT/skills"
cat > "$ACP_TEST_ROOT/manifests/profiles/receipt-acp.json" <<'JSON'
{
  "acp": "allow",
  "console": "allow",
  "env_passthrough": [],
  "gateway": "off",
  "guarantee": "Receipt-order test profile.",
  "handoff": {"system_prompt": false},
  "hooks": "best-effort",
  "masking_level": "off",
  "mcp": {"strict": false},
  "name": "receipt-acp",
  "netpolicy": null,
  "remote": [],
  "sandbox": "vendor-default",
  "schema": 1
}
JSON

printf '# tampered native CLI\n' >> "$CLAUDE_BIN"
rm -f "$RECORD"
tampered_status=0
tampered_out="$(IHAR_TEST_ROOT="$ACP_TEST_ROOT" ihar --profile receipt-acp acp claude)" \
  || tampered_status=$?
assert_eq "ACP rejects a tampered selected native executable" "3" "$tampered_status"
assert_contains "ACP tamper refusal names receipt verification" "$tampered_out" "install receipt"
assert_exit "ACP tamper refusal occurs before the adapter starts" 1 test -e "$RECORD"

cp "$ROOT/tests/fakes/record-exec.sh" "$CLAUDE_BIN"
chmod +x "$CLAUDE_BIN"
write_receipt
rm -f "$IHAR_STORE/install-receipt.json" "$RECORD"
missing_status=0
missing_out="$(IHAR_TEST_ROOT="$ACP_TEST_ROOT" ihar --profile receipt-acp acp codex)" \
  || missing_status=$?
assert_eq "ACP rejects a missing native install receipt" "3" "$missing_status"
assert_contains "ACP missing receipt refusal names receipt verification" \
  "$missing_out" "missing receipt"
assert_exit "ACP missing receipt refusal occurs before the adapter starts" 1 test -e "$RECORD"
write_receipt

printf '# replaced\n' >> "$CODEX_ACP"
assert_exit "a replaced ACP adapter is fail-closed" 3 ihar acp codex
assert_contains "ACP replacement names the repair" "$(ihar acp codex)" \
  "run 'ihar install --acp'"

check="$(ihar check)"
assert_contains "check reports the Claude ACP hook gap" "$check" "claude-agent-acp #144"
assert_contains "check reports the Codex ACP policy gap" "$check" "codex-acp #310/#477"

finish
