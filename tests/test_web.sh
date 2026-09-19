#!/usr/bin/env bash
# Native web surfaces: profile gating, vendor argv and Codex daemon sequence (LLD 13).
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

argv() {
  ihar --dry-run "$@" | python3 -c \
    'import json,sys; print(" ".join(json.load(sys.stdin)["argv"][1:]))'
}

# Removing either adapter's remote fragment must fail these assertions: the browser
# surface is the vendor bridge, not a second ihar execution backend.
assert_contains "Claude web uses native Remote Control" "$(argv claude --web)" \
  "--remote-control"
assert_contains "Claude web carries the requested session name" \
  "$(argv claude --web --name 'pair name')" "--remote-control pair name"

codex_web="$(ihar --dry-run codex --web)"
assert_contains "Codex web attaches the TUI to its runtime daemon" "$codex_web" \
  '"--remote"'
assert_contains "Codex web uses the runtime control socket" "$codex_web" \
  'unix://'

# The command form is intentionally the same launch path as the flag form.
web_command="$(ihar --dry-run web claude)"
assert_contains "web command selects Claude" "$web_command" '"vendor": "claude"'
assert_contains "web command uses native Remote Control" "$web_command" \
  '"--remote-control"'
assert_contains "web command accepts the native session name" \
  "$(ihar --dry-run web claude --name 'command name')" \
  '"--remote-control",'
assert_contains "web command carries the Remote Control name" \
  "$(ihar --dry-run web claude --name 'command name')" '"command name"'
assert_exit "web rejects an unknown vendor" 2 ihar --dry-run web gemini

# A profile allowlist is an enforcement boundary. Moving this check after store or
# gateway setup would turn a usage refusal into an unrelated runtime failure.
assert_exit "protected refuses Claude Remote Control" 2 \
  ihar --profile protected --dry-run claude --web
assert_contains "the refusal names the profile boundary" \
  "$(ihar --profile protected --dry-run claude --web)" \
  "profile 'protected' does not allow Claude web"
assert_exit "isolated refuses Codex web" 2 \
  ihar --profile isolated --dry-run codex --web

# Codex LAN remains the vendor app-server form. ihar does not hide the auth knobs or
# invent another listener: passthrough must stay byte-for-byte visible in argv.
lan="$(argv codex -- app-server --listen ws://127.0.0.1:4500 --ws-auth capability-token --ws-token-file /tmp/token)"
assert_contains "LAN uses app-server listen" "$lan" \
  "app-server --listen ws://127.0.0.1:4500"
assert_contains "LAN keeps websocket auth arguments" "$lan" \
  "--ws-auth capability-token --ws-token-file /tmp/token"

# Actual Codex web launch: start managed daemon, enable hosted remote control, print
# a pairing code, then attach the TUI over the daemon's Unix WebSocket endpoint.
FAKE="$IHAR_TEST_TMP/fake-codex"
LOG="$IHAR_TEST_TMP/codex.calls"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$IHAR_FAKE_LOG"
if [[ "${1:-}" == "--version" ]]; then
  printf 'codex-cli 0.154.0\n'
elif [[ "${1:-} ${2:-} ${3:-}" == "app-server daemon version" ]]; then
  printf '{"status":"absent"}\n'
  exit 1
elif [[ "${1:-} ${2:-} ${3:-}" == "app-server daemon start" ]]; then
  printf '{"status":"started","pid":%s,"socketPath":"%s/app-server-control/app-server-control.sock","managedCodexVersion":"0.154.0"}\n' "$$" "$CODEX_HOME"
elif [[ "${1:-} ${2:-} ${3:-}" == "app-server daemon enable-remote-control" ]]; then
  printf '{"status":"running"}\n'
elif [[ "${1:-} ${2:-}" == "remote-control pair" ]]; then
  printf 'PAIR-CODE\n'
fi
EOF
chmod +x "$FAKE"

actual="$(cd "$PROJECT" && IHAR_STORE="$IHAR_STORE" IHAR_STATE_ROOT="$IHAR_STATE_ROOT" \
  IHAR_CODEX_BIN="$FAKE" IHAR_FAKE_LOG="$LOG" "$ROOT/ihar.sh" codex --web 2>&1)"
calls="$(cat "$LOG")"
assert_contains "Codex web starts the managed daemon" "$calls" \
  "app-server daemon start"
assert_contains "Codex web enables remote control" "$calls" \
  "app-server daemon enable-remote-control"
assert_contains "Codex web creates a pairing code" "$calls" "remote-control pair"
assert_contains "the pairing code reaches the operator" "$actual" "PAIR-CODE"
assert_contains "the TUI attaches over the control socket" "$calls" \
  "--remote unix://"

record="$(find "$IHAR_STATE_ROOT" -path '*/daemons/codex.json' -print -quit)"
assert_exit "the managed daemon is recorded" 0 test -f "$record"
assert_eq "the record marks remote control enabled" "True" \
  "$(python3 -c "import json; print(json.load(open('$record'))['remote_control'])")"

# The daemon lock covers the whole remote setup, not just record writes. Replacing
# the worker with a critical-section probe makes overlap observable without mocking
# the lock itself; removing the wrapper lock creates the marker reliably.
OVERLAP="$IHAR_TEST_TMP/overlap"
GUARD="$IHAR_TEST_TMP/remote-guard"
remote_probe() {
  (
    source "$ROOT/lib/core/logging.sh"
    source "$ROOT/lib/core/lock.sh"
    source "$ROOT/lib/codex/daemon.sh"
    IHAR_STATE="$IHAR_TEST_TMP/lock-state"
    _ihar_codex_remote_start() {
      if ! mkdir "$GUARD" 2>/dev/null; then touch "$OVERLAP"; fi
      sleep 0.2
      rmdir "$GUARD" 2>/dev/null || true
    }
    ihar_codex_remote_start runtime deadbeef
  )
}
remote_probe & first=$!
remote_probe & second=$!
first_status=0; wait "$first" || first_status=$?
second_status=0; wait "$second" || second_status=$?
assert_eq "both serialized remote setup calls complete" "0 0" \
  "$first_status $second_status"
assert_exit "concurrent remote setup is serialized" 1 test -e "$OVERLAP"

finish
