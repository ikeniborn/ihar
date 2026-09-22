#!/usr/bin/env bash
# Native web surfaces: profile gating, vendor argv and Codex daemon sequence (LLD 13).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox

PROJECT="$IHAR_TEST_TMP/proj"
mkdir -p "$PROJECT"
cp -R "$ROOT/hooks" "$ROOT/manifests" "$ROOT/skills" "$IHAR_STORE/"

ihar() {
  ( cd "$PROJECT" && IHAR_STORE="$IHAR_STORE" IHAR_STATE_ROOT="$IHAR_STATE_ROOT" \
      "$ROOT/ihar.sh" "$@" ) 2>&1
}

argv() {
  ihar --dry-run "$@" | sed -n '/^{/,$p' | python3 -c \
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

# Actual Codex web launch: prove a real managed daemon PID/socket, then refuse
# credential-capable remote setup until its write topology is independently proven.
FAKE="$IHAR_TEST_TMP/fake-codex"
LOG="$IHAR_TEST_TMP/codex.calls"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env python3
import json, os, signal, socket, subprocess, sys, time
home = os.environ["CODEX_HOME"]
path = home + "/app-server-control/app-server-control.sock"
pidfile = home + "/fake-daemon.pid"
with open(os.environ["IHAR_FAKE_LOG"], "a", encoding="utf-8") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["--version"]:
    print("codex-cli 0.154.0")
elif sys.argv[1:] == ["app-server", "daemon", "start"]:
    child = subprocess.Popen([sys.executable, __file__, "serve"], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
    for _ in range(100):
        if os.path.exists(path):
            break
        time.sleep(.01)
    print(json.dumps({"status": "started", "pid": child.pid, "socketPath": path,
                      "managedCodexVersion": "0.154.0"}))
elif sys.argv[1:] == ["app-server", "daemon", "stop"]:
    os.killpg(int(open(pidfile, encoding="utf-8").read()), signal.SIGTERM)
    print(json.dumps({"status": "stopped"}))
elif sys.argv[1:] == ["app-server", "daemon", "version"]:
    if os.path.exists(path):
        print(json.dumps({"status": "running", "pid": int(open(pidfile).read()),
                          "socketPath": path, "managedCodexVersion": "0.154.0"}))
    else:
        print(json.dumps({"status": "absent"}))
        sys.exit(1)
elif sys.argv[1:] == ["serve"]:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(path)
    listener.listen()
    with open(pidfile, "w", encoding="utf-8") as output:
        output.write(str(os.getpid()))
    def shutdown(*_):
        listener.close()
        os.unlink(path)
        sys.exit(0)
    signal.signal(signal.SIGTERM, shutdown)
    while True:
        time.sleep(1)
EOF
chmod +x "$FAKE"

actual_status=0
actual="$(cd "$PROJECT" && IHAR_STORE="$IHAR_STORE" IHAR_STATE_ROOT="$IHAR_STATE_ROOT" \
  IHAR_CODEX_BIN="$FAKE" IHAR_FAKE_LOG="$LOG" "$ROOT/ihar.sh" codex --web 2>&1)" || actual_status=$?
calls="$(cat "$LOG")"
assert_contains "Codex web starts the managed daemon" "$calls" \
  "app-server daemon start"
assert_eq "unproved Codex web attachment fails closed" "3" "$actual_status"
assert_contains "web refusal names credential-write proof" "$actual" "credential-write topology"
assert_eq "web does not start another credential writer" "0" \
  "$(grep -Ec 'enable-remote-control|remote-control pair|--remote unix://' "$LOG")"

record="$(find "$IHAR_STATE_ROOT" -path '*/daemons/codex.json' -print -quit)"
assert_exit "the managed daemon is recorded" 0 test -f "$record"
assert_eq "the record does not claim remote control" "False" \
  "$(python3 -c "import json; print(json.load(open('$record'))['remote_control'])")"
daemon_home="$(python3 -c "import json; print(json.load(open('$record'))['socket'].rsplit('/app-server-control/', 1)[0])")"
daemon_pid="$(python3 -c "import json; print(json.load(open('$record'))['pid'])")"
assert_exit "fake daemon PID remains live" 0 kill -0 "$daemon_pid"
assert_exit "fake daemon socket remains live" 0 test -S "$daemon_home/app-server-control/app-server-control.sock"
stop_status=0
stop_out="$(PYTHONPATH="$ROOT/lib/python" python3 -m ihar.codex.daemon stop --binary "$FAKE" --home "$daemon_home" \
  --state "$(dirname "$(dirname "$record")")" --auth-store "$IHAR_STORE" 2>&1)" || stop_status=$?
assert_eq "web fixture stop is accepted" "0" "$stop_status"
[[ "$stop_status" == 0 ]] || printf '%s\n' "$stop_out"
for _ in {1..100}; do
  [[ ! -e "$IHAR_STORE/auth/codex/.owner.json" ]] && break
  sleep 0.05
done
assert_exit "web fixture daemon stops through owner" 1 test -e "$IHAR_STORE/auth/codex/.owner.json"

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
