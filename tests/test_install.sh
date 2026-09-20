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

# --- install stages one generation and rolls every failure back ----------------------

write_lock '"node":{"version":"22.23.1"},"claude":{"version":"2.1.274"},
            "codex":{"version":"rust-v0.154.0","asset":"codex.tar.gz","sha256":"'"$RELEASE_SHA"'"}'
OLD_RECEIPT='{"schema":1,"release_lock_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","installed_at":"2026-09-19T00:00:00Z","components":{}}'

reset_active_generation() {
  mkdir -p "$IHAR_STORE/hooks" "$(dirname "$IHAR_CODEX_BIN")" "$(dirname "$IHAR_CLAUDE_BIN")"
  printf 'old hook\n' > "$IHAR_STORE/hooks/security-pretool.py"
  printf '#!/bin/sh\necho old claude\n' > "$IHAR_CLAUDE_BIN"
  printf '#!/bin/sh\necho old codex\n' > "$IHAR_CODEX_BIN"
  chmod +x "$IHAR_CLAUDE_BIN" "$IHAR_CODEX_BIN"
  printf '%s\n' "$OLD_RECEIPT" > "$IHAR_STORE/install-receipt.json"
}

generation_fingerprint() {
  {
    find "$IHAR_STORE/hooks" -type f -print0 | sort -z | xargs -0 sha256sum
    for path in "$IHAR_CLAUDE_BIN" "$IHAR_CODEX_BIN" \
                "$IHAR_STORE/install-receipt.json"; do
      sha256sum "$path" | cut -d' ' -f1
    done
  } | sha256sum | cut -d' ' -f1
}

run_install_scenario() ( # <success|paths|ownership|conformance|receipt|activation|rollback> [install|update]
  local scenario="$1" operation="${2:-install}"
  export IHAR_ACTIVE_TEST_STORE="$IHAR_STORE"
  ihar_install_command() { :; }
  ihar_install_example_config() { :; }
  ihar_install_store() {
    mkdir -p "$IHAR_STORE/hooks"
    printf 'new hook\n' > "$IHAR_STORE/hooks/security-pretool.py"
  }
  ihar_install_python() { :; }
  ihar_install_codex() {
    mkdir -p "$(dirname "$IHAR_CODEX_BIN")"
    printf '#!/bin/sh\necho new codex\n' > "$IHAR_CODEX_BIN"
    chmod +x "$IHAR_CODEX_BIN"
  }
  ihar_install_claude() {
    mkdir -p "$(dirname "$IHAR_CLAUDE_BIN")"
    printf '#!/bin/sh\necho new claude\n' > "$IHAR_CLAUDE_BIN"
    chmod +x "$IHAR_CLAUDE_BIN"
  }
  ihar_install_conformance() {
    [[ "$scenario" != conformance ]] || return 36
    grep -q 'new hook' "$IHAR_STORE/hooks/security-pretool.py" || return 40
    grep -q 'new claude' "$IHAR_CLAUDE_BIN" || return 40
    grep -q 'new codex' "$IHAR_CODEX_BIN" || return 40
    if [[ "$scenario" == paths ]]; then
      [[ "${1:-}" == "$IHAR_ACTIVE_TEST_STORE" ]] || return 41
      [[ "$IHAR_STORE" == */.ihar-store-stage-* ]] || return 42
      [[ "$IHAR_CLAUDE_BIN" == */.ihar-nvm-stage-*/npm-global/bin/claude ]] || return 42
      [[ "$IHAR_CODEX_BIN" == */.ihar-store-stage-*/bin/codex ]] || return 42
    fi
    if [[ "$scenario" == ownership ]]; then
      if [[ -e "$IHAR_STORE/auth/claude/concurrent" ||
            -e "$IHAR_STORE/plugins/claude/concurrent" ||
            -e "$IHAR_STORE/vendor-data/concurrent" ]]; then
        printf 'copied\n' > "$IHAR_TEST_TMP/ownership-stage-observation"
      else
        printf 'clean\n' > "$IHAR_TEST_TMP/ownership-stage-observation"
      fi
      printf 'concurrent auth\n' > "$IHAR_ACTIVE_TEST_STORE/auth/claude/concurrent"
      printf 'concurrent plugin\n' > "$IHAR_ACTIVE_TEST_STORE/plugins/claude/concurrent"
      printf 'concurrent vendor data\n' > "$IHAR_ACTIVE_TEST_STORE/vendor-data/concurrent"
    fi
  }
  ihar_publish_install_receipt() {
    [[ "$scenario" != receipt ]] || return 37
    ihar_python ihar.install_receipt build "$IHAR_LOCKFILE" \
      "$IHAR_STORE/install-receipt.json" "$IHAR_CLAUDE_BIN" "$IHAR_CODEX_BIN"
  }
  ihar_install_move() {
    if [[ ( "$scenario" == activation || "$scenario" == rollback ) &&
          "$1" == */.ihar-store-stage-*/install-receipt.json &&
          "$2" == "$IHAR_ACTIVE_TEST_STORE/install-receipt.json" ]]; then
      return 39
    fi
    if [[ "$scenario" == rollback && "$1" == */.ihar-install-backup-*/install-receipt.json &&
          "$2" == "$IHAR_ACTIVE_TEST_STORE/install-receipt.json" ]]; then
      return 41
    fi
    command mv "$@"
  }
  if [[ "$operation" == update ]]; then
    ihar_codex_daemon_stop_all() { :; }
    ihar_codex_daemon_start_pending() { :; }
    _ihar_update_all
  else
    _ihar_install_all
  fi
)

before_lock="$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"
for scenario in conformance receipt activation; do
  reset_active_generation
  before_generation="$(generation_fingerprint)"
  case "$scenario" in
    conformance) expected_status=36 ;;
    receipt) expected_status=37 ;;
    activation) expected_status=39 ;;
  esac
  assert_exit "$scenario failure aborts install" "$expected_status" \
    run_install_scenario "$scenario"
  assert_eq "$scenario failure preserves exact active generation and receipt" \
    "$before_generation" "$(generation_fingerprint)"
  assert_exit "$scenario failure leaves Claude executable usable" 0 "$IHAR_CLAUDE_BIN"
  assert_exit "$scenario failure leaves Codex executable usable" 0 "$IHAR_CODEX_BIN"
done

reset_active_generation
assert_exit "conformance loads staged hooks and binaries while protecting active store" 0 \
  run_install_scenario paths

reset_active_generation
before_generation="$(generation_fingerprint)"
assert_exit "receipt failure aborts update" 37 run_install_scenario receipt update
assert_eq "receipt failure preserves exact active generation across update" \
  "$before_generation" "$(generation_fingerprint)"
assert_eq "failed installs never rewrite release lock" "$before_lock" \
  "$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"
assert_exit "failed installs leak no store stage" 1 \
  compgen -G "$(dirname "$IHAR_STORE")/.ihar-store-stage-*"
assert_exit "failed installs leak no NVM stage" 1 \
  compgen -G "$(dirname "$IHAR_NVM")/.ihar-nvm-stage-*"
assert_exit "failed installs leak no activation backup" 1 \
  compgen -G "$(dirname "$IHAR_STORE")/.ihar-install-backup-*"

reset_active_generation
mkdir -p "$IHAR_STORE/auth/claude" "$IHAR_STORE/plugins/claude" "$IHAR_STORE/vendor-data"
printf 'initial auth\n' > "$IHAR_STORE/auth/claude/concurrent"
printf 'initial plugin\n' > "$IHAR_STORE/plugins/claude/concurrent"
printf 'initial vendor data\n' > "$IHAR_STORE/vendor-data/concurrent"
printf 'stable lock\n' > "$IHAR_STORE/.ihar-store.lock"
lock_inode="$(stat -c '%i' "$IHAR_STORE/.ihar-store.lock")"
assert_exit "transaction stages only installer-owned store paths" 0 \
  run_install_scenario ownership
assert_eq "mutable store paths are not copied into the generation stage" "clean" \
  "$(cat "$IHAR_TEST_TMP/ownership-stage-observation")"
assert_eq "concurrent auth writes survive activation" "concurrent auth" \
  "$(cat "$IHAR_STORE/auth/claude/concurrent")"
assert_eq "concurrent plugin writes survive activation" "concurrent plugin" \
  "$(cat "$IHAR_STORE/plugins/claude/concurrent")"
assert_eq "concurrent vendor data writes survive activation" "concurrent vendor data" \
  "$(cat "$IHAR_STORE/vendor-data/concurrent")"
assert_eq "stable lock inode survives activation" "$lock_inode" \
  "$(stat -c '%i' "$IHAR_STORE/.ihar-store.lock")"

reset_active_generation
rollback_output="$(run_install_scenario rollback 2>&1)"
rollback_status=$?
assert_eq "incomplete rollback reports recovery failure" 3 "$rollback_status"
recovery_backup="$(compgen -G "$(dirname "$IHAR_STORE")/.ihar-install-backup-*" | head -1)"
assert_exit "incomplete rollback retains recovery backup" 0 test -n "$recovery_backup"
assert_contains "incomplete rollback reports retained backup path" "$rollback_output" \
  ".ihar-install-backup-"
assert_exit "incomplete rollback retains prior receipt for recovery" 0 \
  test -f "$recovery_backup/install-receipt.json"
assert_contains "retained recovery receipt has prior bytes" \
  "$(cat "$recovery_backup/install-receipt.json")" '"release_lock_sha256":"aaaaaaaa'
assert_contains "rollback continues restoring hooks after one restore failure" \
  "$(cat "$IHAR_STORE/hooks/security-pretool.py")" "old hook"
assert_contains "rollback continues restoring Claude after one restore failure" \
  "$(cat "$IHAR_CLAUDE_BIN")" "old claude"
assert_contains "rollback continues restoring Codex after one restore failure" \
  "$(cat "$IHAR_CODEX_BIN")" "old codex"

reset_active_generation
run_install_scenario success >/dev/null 2>&1
assert_contains "successful install activates staged hook bytes" \
  "$(cat "$IHAR_STORE/hooks/security-pretool.py")" "new hook"
assert_contains "successful install activates staged Claude bytes" \
  "$(cat "$IHAR_CLAUDE_BIN")" "new claude"
assert_contains "successful install activates staged Codex bytes" \
  "$(cat "$IHAR_CODEX_BIN")" "new codex"

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
