#!/usr/bin/env bash
# Install and update (LLD 14.3).
#
# The network is stubbed through the IHAR_DOWNLOAD seam so the real verification,
# extraction and pinning logic runs against local fixtures. What is asserted is the
# part that matters: nothing needs privilege, a digest mismatch is refused, and a
# user's own file on PATH is never replaced.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
export IHAR_ROOT="$ROOT" PYTHONPATH="$ROOT/lib/python"
export IHAR_BIN_DIR="$IHAR_TEST_TMP/bin"
export IHAR_LOCKFILE="$IHAR_TEST_TMP/.ihar-lockfile.json"
export IHAR_NVM="$IHAR_TEST_TMP/nvm"

source "$ROOT/lib/core/logging.sh"
source "$ROOT/lib/core/init.sh"
source "$ROOT/lib/core/lock.sh"
source "$ROOT/lib/store/lockfile.sh"
source "$ROOT/lib/store/install.sh"

export IHAR_CLAUDE_BIN="$IHAR_NVM/npm-global/bin/claude"
export IHAR_CODEX_BIN="$IHAR_STORE/bin/codex"
export IHAR_CLAUDE_ACP_BIN="$IHAR_STORE/acp/bin/claude-agent-acp"
export IHAR_CODEX_ACP_BIN="$IHAR_STORE/acp/bin/codex-acp"

# --- a stub release, and a stub fetcher that serves it --------------------------------

RELEASE_DIR="$IHAR_TEST_TMP/releases"
mkdir -p "$RELEASE_DIR/payload"
printf '#!/bin/sh\necho stub codex\n' > "$RELEASE_DIR/payload/codex-x86_64-unknown-linux-musl"
tar -czf "$RELEASE_DIR/codex.tar.gz" -C "$RELEASE_DIR/payload" . 2>/dev/null
RELEASE_SHA="$(sha256sum "$RELEASE_DIR/codex.tar.gz" | cut -d' ' -f1)"

cat > "$IHAR_TEST_TMP/fetch" <<EOF
#!/usr/bin/env bash
# Serves the stub release for any URL; the test is about verification, not transport.
cp "$RELEASE_DIR/codex.tar.gz" "\$2"
EOF
chmod +x "$IHAR_TEST_TMP/fetch"
export IHAR_DOWNLOAD="$IHAR_TEST_TMP/fetch"

write_lock() {
  printf '{"schema":1,%s}\n' "$1" > "$IHAR_LOCKFILE"
}

# --- the store is built, and the tracked trees are pinned --------------------------------

cp "$ROOT/.ihar-lockfile.json" "$IHAR_LOCKFILE"
before_lock="$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"
ihar_install_store >/dev/null 2>&1
assert_exit "the store tree is created" 0 test -d "$IHAR_STORE/hooks/_shared"
assert_exit "manifests are copied in" 0 test -f "$IHAR_STORE/manifests/hooks.json"
assert_eq "the auth directory is owner-only" "700" "$(stat -c '%a' "$IHAR_STORE/auth")"

pinned="$(python3 -c "
import json,sys
print(len(json.load(open(sys.argv[1])).get('hooks', {})))" "$IHAR_LOCKFILE")"
assert_exit "every hook file is pinned, not a curated list" 0 test "$pinned" -ge 5
assert_eq "install never rewrites release lock" "$before_lock" \
  "$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"

# The store is copied, never linked: a link would put the agent's writable checkout
# back on the path a hook is loaded from.
assert_exit "the store is a copy, not a link into the checkout" 1 test -L "$IHAR_STORE/hooks"

# --- the command on PATH -------------------------------------------------------------------

ihar_install_command >/dev/null 2>&1
assert_exit "a symlink is created" 0 test -L "$IHAR_BIN_DIR/ihar"
assert_eq "and it points at this checkout" "$ROOT/ihar.sh" "$(readlink "$IHAR_BIN_DIR/ihar")"
assert_exit "installing twice is idempotent" 0 ihar_install_command

# A user with their own ihar on PATH has it for a reason.
rm -f "$IHAR_BIN_DIR/ihar"
printf '#!/bin/sh\necho mine\n' > "$IHAR_BIN_DIR/ihar"
out="$(ihar_install_command 2>&1)"
assert_contains "a stranger's file is left alone" "$out" "leaving it alone"
assert_exit "and it is still a regular file" 1 test -L "$IHAR_BIN_DIR/ihar"
assert_eq "with its contents intact" "#!/bin/sh" "$(head -1 "$IHAR_BIN_DIR/ihar")"
rm -f "$IHAR_BIN_DIR/ihar"

# --- nothing needs privilege -----------------------------------------------------------------
#
# A harness that asks for root to install is a harness people install as root, and
# everything it runs afterwards inherits that.

for path in "$IHAR_STORE" "$IHAR_STATE_ROOT" "$IHAR_BIN_DIR" "$IHAR_NVM"; do
  case "$path" in
    /usr/*|/etc/*|/opt/*|/var/*) FAIL=$((FAIL+1)); echo "FAIL: $path is outside the user's own directories" ;;
    *) PASS=$((PASS+1)); echo "PASS [$path is user-owned]" ;;
  esac
done
# Commands, not comments: the file says the word "sudo" while explaining why it
# never runs it, and a naive grep would count that as a violation.
assert_eq "no install step invokes sudo" "0" \
  "$(grep -cE '^[[:space:]]*[^#]*\bsudo[[:space:]]' "$ROOT/lib/store/install.sh")"

# --- a Codex release is verified before it is trusted -------------------------------------------

write_lock '"codex":{"version":"rust-v0.154.0","asset":"codex.tar.gz","sha256":"'"$RELEASE_SHA"'"}'
ihar_install_codex >/dev/null 2>&1
assert_exit "the release is extracted" 0 test -x "$IHAR_STORE/bin/codex"
assert_eq "and the version is stamped" "rust-v0.154.0" "$(cat "$IHAR_STORE/bin/.codex-version")"

rm -f "$IHAR_STORE/bin/codex" "$IHAR_STORE/bin/.codex-version"
write_lock '"codex":{"version":"rust-v0.154.0","asset":"codex.tar.gz","sha256":"'"$(printf '0%.0s' {1..64})"'"}'
assert_exit "a digest mismatch is fail-closed" 3 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/init.sh'
           source '$ROOT/lib/store/lockfile.sh'; source '$ROOT/lib/store/install.sh'
           IHAR_ROOT='$ROOT' IHAR_STORE='$IHAR_STORE' IHAR_LOCKFILE='$IHAR_LOCKFILE' \
           IHAR_DOWNLOAD='$IHAR_TEST_TMP/fetch' ihar_install_codex"
assert_exit "and nothing is left installed" 1 test -x "$IHAR_STORE/bin/codex"

out="$(bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/init.sh'
       source '$ROOT/lib/store/lockfile.sh'; source '$ROOT/lib/store/install.sh'
       IHAR_ROOT='$ROOT' IHAR_STORE='$IHAR_STORE' IHAR_LOCKFILE='$IHAR_LOCKFILE' \
       IHAR_DOWNLOAD='$IHAR_TEST_TMP/fetch' ihar_install_codex" 2>&1)"
assert_contains "the refusal shows both digests" "$out" "expected"

# --- install and update are one operation, decided by the pinned version -------------------------
#
# Install used to skip on the binary merely existing, so bumping the lockfile upgraded
# nothing and `ihar update` re-earned the conformance record with the old binary.

write_lock '"codex":{"version":"rust-v0.154.0","asset":"codex.tar.gz","sha256":"'"$RELEASE_SHA"'"}'
ihar_install_codex >/dev/null 2>&1
out="$(ihar_install_codex 2>&1)"
assert_contains "an unchanged lockfile makes the run a no-op" "$out" "already installed"

write_lock '"codex":{"version":"rust-v0.155.0","asset":"codex.tar.gz","sha256":"'"$RELEASE_SHA"'"}'
out="$(ihar_install_codex 2>&1)"
assert_contains "a bumped version reinstalls" "$out" "rust-v0.155.0 installed"
assert_eq "and restamps" "rust-v0.155.0" "$(cat "$IHAR_STORE/bin/.codex-version")"

# --- ACP adapters use exactly the lockfile versions ---------------------------------------------

cat > "$IHAR_TEST_TMP/npm" <<'EOF'
#!/usr/bin/env bash
set -eu
prefix=""
spec="${!#}"
while (( $# )); do
  if [[ "$1" == --prefix ]]; then prefix="$2"; shift 2; else shift; fi
done
mkdir -p "$prefix/bin"
case "$spec" in
  @agentclientprotocol/claude-agent-acp@*) name=claude-agent-acp ;;
  github:agentclientprotocol/codex-acp#*) name=codex-acp ;;
  *) exit 9 ;;
esac
printf '#!/bin/sh\n' > "$prefix/bin/$name"
chmod +x "$prefix/bin/$name"
printf '%s\n' "$spec" >> "$IHAR_FAKE_NPM_RECORD"
EOF
chmod +x "$IHAR_TEST_TMP/npm"
export IHAR_NPM_BIN="$IHAR_TEST_TMP/npm"
export IHAR_FAKE_NPM_RECORD="$IHAR_TEST_TMP/npm-record"

write_lock '"acp":{"claude-agent-acp":"0.79.0","codex-acp":"6ec22f3"}'
ihar_install_acp >/dev/null 2>&1
assert_exit "the Claude ACP adapter is installed" 0 test -x "$IHAR_CLAUDE_ACP_BIN"
assert_exit "the Codex ACP adapter is installed" 0 test -x "$IHAR_CODEX_ACP_BIN"
assert_contains "Claude ACP uses the exact pinned version" "$(cat "$IHAR_FAKE_NPM_RECORD")" \
  "@agentclientprotocol/claude-agent-acp@0.79.0"
assert_contains "Codex ACP uses the exact pinned revision" "$(cat "$IHAR_FAKE_NPM_RECORD")" \
  "github:agentclientprotocol/codex-acp#6ec22f3"
assert_eq "ACP versions are stamped" $'0.79.0\n6ec22f3' \
  "$(cat "$IHAR_STORE/acp/.versions")"

out="$(ihar_install_acp 2>&1)"
assert_contains "unchanged ACP pins make install a no-op" "$out" "already installed"

write_lock '"acp":{"claude-agent-acp":"0.80.0","codex-acp":"6ec22f3"}'
ihar_install_acp >/dev/null 2>&1
assert_contains "a bumped ACP version reinstalls" "$(cat "$IHAR_FAKE_NPM_RECORD")" \
  "@agentclientprotocol/claude-agent-acp@0.80.0"

# The Claude CLI follows the same rule, and it is the one that did not: assert the
# stamp is what decides, without a network or an npm registry.
CLAUDE_STAMP="$IHAR_NVM/npm-global/.claude-version"
mkdir -p "$(dirname "$IHAR_CLAUDE_BIN")" "$IHAR_NVM/bin" "$IHAR_NVM/npm-global"
printf '#!/bin/sh\necho stub claude\n' > "$IHAR_CLAUDE_BIN"; chmod +x "$IHAR_CLAUDE_BIN"
printf 'x\n' > "$IHAR_NVM/bin/node"; chmod +x "$IHAR_NVM/bin/node"
printf '2.0.0\n' > "$CLAUDE_STAMP"

write_lock '"node":{"version":"22.0.0"},"claude":{"version":"2.0.0"}'
out="$(ihar_install_claude 2>&1)"
assert_contains "a matching claude stamp is a no-op" "$out" "claude 2.0.0 already installed"

write_lock '"node":{"version":"22.0.0"},"claude":{"version":"2.1.0"}'
out="$(ihar_install_claude 2>&1)"
assert_eq "a bumped claude version does not report already installed" "0" \
  "$(grep -c 'already installed' <<<"$out")"

# --- the example configuration ---------------------------------------------------------------------

# Into the sandbox, never the checkout: the installer writes beside IHAR_ROOT, and a
# test that runs it against the real root rewrites a tracked file as a side effect.
# The exported PYTHONPATH still reaches the package.
EXAMPLE_ROOT="$IHAR_TEST_TMP/example-root"
mkdir -p "$EXAMPLE_ROOT"
IHAR_ROOT="$EXAMPLE_ROOT" ihar_install_example_config >/dev/null 2>&1
EXAMPLE="$EXAMPLE_ROOT/.ihar_config.example"
assert_exit "the example is written" 0 test -f "$EXAMPLE"
assert_contains "it says the file is parsed, not sourced" "$(cat "$EXAMPLE")" "never sourced"
assert_contains "it documents the profile key" "$(cat "$EXAMPLE")" "IHAR_PROFILE=standard"
assert_contains "and the masking floor rule" "$(cat "$EXAMPLE")" "never loosen it"
assert_eq "every line is commented out" "0" \
  "$(grep -cE '^[A-Z]' "$EXAMPLE")"

# Every key the parser accepts must appear in the example. Read from the parser's own
# array rather than scraped out of the file: a regular expression over the source
# would also catch internal names and would drift the moment either list moved.
source "$ROOT/lib/core/config.sh"
example_text="$(cat "$EXAMPLE")"
for key in "${_IHAR_CONFIG_KEYS[@]}"; do
  assert_contains "the example documents $key" "$example_text" "$key"
done

rm -f "$EXAMPLE"

# --- the validated receipt is the final publication ---------------------------------

write_lock '"node":{"version":"22.23.1"},"claude":{"version":"2.1.274"},
            "codex":{"version":"rust-v0.154.0","asset":"codex.tar.gz","sha256":"'"$RELEASE_SHA"'"}'
mkdir -p "$(dirname "$IHAR_CLAUDE_BIN")" "$(dirname "$IHAR_CODEX_BIN")"
printf '#!/bin/sh\necho claude\n' > "$IHAR_CLAUDE_BIN"
printf '#!/bin/sh\necho codex\n' > "$IHAR_CODEX_BIN"
chmod +x "$IHAR_CLAUDE_BIN" "$IHAR_CODEX_BIN"
printf '%s\n' '{"schema":1,"release_lock_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","installed_at":"2026-09-19T00:00:00Z","components":{}}' \
  > "$IHAR_STORE/install-receipt.json"

stub_install_steps() {
  ihar_install_store() { :; }
  ihar_install_command() { :; }
  ihar_install_example_config() { :; }
  ihar_install_python() { :; }
  ihar_install_codex() { :; }
  ihar_install_claude() { :; }
  ihar_install_conformance() { :; }
}

before_lock="$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"
before_receipt="$(sha256sum "$IHAR_STORE/install-receipt.json" | cut -d' ' -f1)"
assert_exit "a pre-publication failure aborts install" 37 bash -c "
  source '$ROOT/lib/core/logging.sh'
  source '$ROOT/lib/core/init.sh'
  source '$ROOT/lib/store/lockfile.sh'
  source '$ROOT/lib/store/install.sh'
  stub_install_steps() {
    ihar_install_store() { :; }; ihar_install_command() { :; }
    ihar_install_example_config() { :; }; ihar_install_python() { :; }
    ihar_install_codex() { :; }; ihar_install_claude() { :; }
    ihar_install_conformance() { :; }
  }
  stub_install_steps
  ihar_publish_install_receipt() { return 37; }
  IHAR_ROOT='$ROOT' IHAR_STORE='$IHAR_STORE' IHAR_LOCKFILE='$IHAR_LOCKFILE' \
  IHAR_CLAUDE_BIN='$IHAR_CLAUDE_BIN' IHAR_CODEX_BIN='$IHAR_CODEX_BIN' _ihar_install_all
"
assert_eq "install never rewrites release lock" "$before_lock" \
  "$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"
assert_eq "failed install preserves receipt" "$before_receipt" \
  "$(sha256sum "$IHAR_STORE/install-receipt.json" | cut -d' ' -f1)"
assert_exit "receipt temp is not leaked" 1 compgen -G "$IHAR_STORE/.install-receipt-*"
assert_exit "failed publication leaves Claude executable usable" 0 test -x "$IHAR_CLAUDE_BIN"
assert_exit "failed publication leaves Codex executable usable" 0 test -x "$IHAR_CODEX_BIN"

(
  stub_install_steps
  _ihar_install_all
) >/dev/null 2>&1

expected_lock_sha="$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"
expected_claude_sha="$(sha256sum "$IHAR_CLAUDE_BIN" | cut -d' ' -f1)"
expected_codex_sha="$(sha256sum "$IHAR_CODEX_BIN" | cut -d' ' -f1)"
receipt_values="$(python3 - "$IHAR_STORE/install-receipt.json" <<'PY'
import sys
from ihar.install_receipt import read_receipt

receipt = read_receipt(sys.argv[1])
print(receipt["release_lock_sha256"])
print(receipt["components"]["claude"]["version"])
print(receipt["components"]["claude"]["binary_sha256"])
print(receipt["components"]["codex"]["version"])
print(receipt["components"]["codex"]["binary_sha256"])
PY
)"
assert_eq "receipt records release and executable evidence" \
  "$expected_lock_sha
2.1.274
$expected_claude_sha
rust-v0.154.0
$expected_codex_sha" "$receipt_values"
assert_eq "receipt is owner-only" "600" "$(stat -c '%a' "$IHAR_STORE/install-receipt.json")"
assert_eq "successful install preserves release lock" "$before_lock" \
  "$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"
assert_exit "successful publication leaves no temp" 1 compgen -G "$IHAR_STORE/.install-receipt-*"

chmod -x "$IHAR_CODEX_BIN"
ihar_publish_install_receipt
receipt_vendors="$(python3 - "$IHAR_STORE/install-receipt.json" <<'PY'
import json
import sys

print(" ".join(sorted(json.load(open(sys.argv[1], encoding="utf-8"))["components"])))
PY
)"
assert_eq "receipt hashes only executables that exist" "claude" "$receipt_vendors"
chmod +x "$IHAR_CODEX_BIN"

finish
