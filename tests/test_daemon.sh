#!/usr/bin/env bash
# The managed Codex daemon: record, reconciliation and the operator command (LLD 5.5).
#
# The vendor's daemon subcommands are stubbed through a fake `codex` for every case
# that needs a controlled answer, because the interesting states — a foreign daemon, a
# version skew, a record pointing at a dead process — cannot be produced on demand
# from a real one. The live cases that a stub cannot prove run separately below and
# skip when the binary is absent.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
export PYTHONPATH="$ROOT/lib/python" IHAR_ROOT="$ROOT"

source "$ROOT/lib/core/logging.sh"
source "$ROOT/lib/core/init.sh"
source "$ROOT/lib/core/lock.sh"

STATE="$IHAR_TEST_TMP/state"
HOME_DIR="$IHAR_TEST_TMP/runtime/codex"
mkdir -p "$STATE/daemons" "$HOME_DIR/app-server-control"

# A fake `codex` whose daemon answers come from files the test writes. The shape is
# the real one, measured from 0.154.0.
FAKE="$IHAR_TEST_TMP/fake-codex"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  cat "$IHAR_FAKE_DIR/version"
  exit 0
fi
if [[ "${1:-}" == "app-server" && "${2:-}" == "daemon" ]]; then
  answer="$IHAR_FAKE_DIR/${3}.json"
  [[ -f "$answer" ]] || { echo "no stub for ${3}" >&2; exit 1; }
  cat "$answer"
  exit "$(cat "$IHAR_FAKE_DIR/${3}.exit" 2>/dev/null || echo 0)"
fi
exit 0
EOF
chmod +x "$FAKE"
export IHAR_FAKE_DIR="$IHAR_TEST_TMP/fake"
mkdir -p "$IHAR_FAKE_DIR"
printf 'codex-cli 0.154.0\n' > "$IHAR_FAKE_DIR/version"

daemon() { # <action> [config-hash]
  python3 -m ihar.codex.daemon "$1" --binary "$FAKE" --home "$HOME_DIR" \
    --state "$STATE" --config-hash "${2:-aabbccdd}" 2>&1
}
daemon_exit() {
  daemon "$@" >/dev/null 2>&1
  echo $?
}

stub() { # <action> <json>
  printf '%s\n' "$2" > "$IHAR_FAKE_DIR/$1.json"
}

RUNNING='{"status":"running","backend":"pid","pid":424242,"managedCodexPath":"/store/codex","managedCodexVersion":"0.154.0","socketPath":"'"$HOME_DIR"'/app-server-control/app-server-control.sock","cliVersion":"0.154.0","appServerVersion":"0.154.0"}'
ABSENT='{"status":"absent"}'

# --- no daemon is running ------------------------------------------------------------

stub version "$ABSENT"
assert_eq "no daemon means nothing to reconcile" "0" "$(daemon_exit reconcile)"
assert_contains "and it says so" "$(daemon reconcile)" '"action": "none"'

# A record left over from a daemon that is gone is not a claim on anything.
printf '{"schema":1,"pid":1,"socket":"s","binary_sha256":"%s","codex_version":"0.154.0","config_hash":"aabbccdd","started_at":"2026-09-19T07:00:00Z","remote_control":false}\n' \
  "$(printf '0%.0s' {1..64})" > "$STATE/daemons/codex.json"
daemon reconcile >/dev/null
assert_exit "a stale record is removed" 1 test -f "$STATE/daemons/codex.json"

# --- a running daemon ihar has no record of ------------------------------------------
#
# Stopping it would take down someone else's sessions; serving the launch from it
# would apply a configuration nobody chose. The launch aborts instead.

stub version "$RUNNING"
assert_eq "a foreign daemon is refused" "3" "$(daemon_exit reconcile)"
assert_contains "and the reason names it" "$(daemon reconcile)" "no record of"
leased_reconcile_status=0
leased_reconcile="$(python3 -m ihar.codex.daemon reconcile --binary "$FAKE" \
  --home "$HOME_DIR" --state "$STATE" --config-hash aabbccdd \
  --auth-store "$IHAR_STORE" 2>&1)" || leased_reconcile_status=$?
assert_eq "a running daemon without its auth owner is refused" "3" "$leased_reconcile_status"
assert_contains "the missing lease is named" "$leased_reconcile" "no verified Codex auth owner"

# --- a running daemon ihar started, matching -------------------------------------------

record() { # <config-hash> <pid> [binary-sha]
  python3 - "$STATE" "$1" "$2" "$FAKE" "${3:-}" <<'PY'
import hashlib, json, os, sys
state, config_hash, pid, binary, override = sys.argv[1:6]
digest = override or hashlib.sha256(open(binary, "rb").read()).hexdigest()
path = os.path.join(state, "daemons", "codex.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"schema": 1, "pid": int(pid), "socket": "s", "binary_sha256": digest,
           "codex_version": "0.154.0", "config_hash": config_hash,
           "started_at": "2026-09-19T07:00:00Z", "remote_control": False},
          open(path, "w"))
PY
}

record aabbccdd "$$"
assert_eq "a matching daemon is left alone" "0" "$(daemon_exit reconcile aabbccdd)"
assert_contains "and nothing happens" "$(daemon reconcile aabbccdd)" '"action": "none"'
assert_exit "the record survives" 0 test -f "$STATE/daemons/codex.json"

# --- a configuration change on a daemon ihar started ------------------------------------

stub stop '{"status":"stopped"}'
stub start "${RUNNING/\"status\":\"running\"/\"status\":\"started\"}"

record aabbccdd "$$"
out="$(daemon reconcile 99887766)"
assert_contains "a configuration change restarts it" "$out" '"action": "restarted"'
assert_contains "and the reason names both hashes" "$out" "aabbccdd"
assert_contains "and the hash this launch wants" "$out" "99887766"
assert_eq "the new record carries the new hash" "99887766" \
  "$(python3 -c "import json;print(json.load(open('$STATE/daemons/codex.json'))['config_hash'])")"

# --- a version skew ----------------------------------------------------------------------
#
# The daemon goes on running the binary it started from, so a CLI upgrade leaves the
# two disagreeing until something restarts it. This is the upstream class §5.5 names.

record 99887766 "$$"
printf 'codex-cli 0.155.0\n' > "$IHAR_FAKE_DIR/version"
out="$(daemon reconcile 99887766)"
assert_contains "a version skew restarts it" "$out" '"action": "restarted"'
assert_contains "and names both versions" "$out" "0.155.0"
printf 'codex-cli 0.154.0\n' > "$IHAR_FAKE_DIR/version"

# --- a record pointing at a dead process is not a claim ------------------------------------

record 99887766 999999
assert_eq "a record whose process is gone does not make the daemon ours" "3" \
  "$(daemon_exit reconcile 00112233)"

# --- the binary on disk changed under a running daemon -------------------------------------

record 99887766 "$$" "$(printf 'a%.0s' {1..64})"
out="$(daemon reconcile 99887766)"
assert_contains "a replaced binary restarts it" "$out" '"action": "restarted"'

# --- a restart that does not come back is a refusal, not a success --------------------------

record aabbccdd "$$"
stub start "$ABSENT"
assert_eq "a daemon that fails to restart refuses the launch" "3" \
  "$(daemon_exit reconcile 99887766)"
stub start "${RUNNING/\"status\":\"running\"/\"status\":\"started\"}"

# --- the record is a validated contract ----------------------------------------------------

printf '{"schema":1,"pid":"not an int"}\n' > "$STATE/daemons/codex.json"
stub version "$RUNNING"
assert_eq "a record that does not validate is not trusted" "3" "$(daemon_exit reconcile)"

# --- the standalone path the daemon insists on ---------------------------------------------
#
# `codex app-server daemon start` refuses unless a managed standalone install sits at
# $CODEX_HOME/packages/standalone/current/codex. ihar installs a release tarball into
# its own store, so without this link the daemon could never start at all.

source "$ROOT/lib/codex/daemon.sh"
RENDER="$IHAR_TEST_TMP/render"
mkdir -p "$RENDER"
IHAR_CODEX_BIN="$FAKE" ihar_render_standalone_link "$RENDER"
assert_exit "the standalone path is rendered as a link" 0 \
  test -L "$RENDER/packages/standalone/current/codex"
assert_eq "pointing at the store binary" "$FAKE" \
  "$(readlink "$RENDER/packages/standalone/current/codex")"

# It is rendered, not created in the published home, because a published runtime home
# is never written to again.
assert_contains "the renderer is called from the render step" \
  "$(cat "$ROOT/lib/render/hooks.sh")" "ihar_render_standalone_link"

# A missing binary is not an error here: install has not run yet, and the render must
# still produce a home.
RENDER2="$IHAR_TEST_TMP/render2"
mkdir -p "$RENDER2"
IHAR_CODEX_BIN="$IHAR_TEST_TMP/absent" ihar_render_standalone_link "$RENDER2"
assert_exit "an uninstalled binary renders no link" 1 test -e "$RENDER2/packages"

# --- reconciliation is taken under a required lock ------------------------------------------
#
# Two launches reconciling at once could both decide to restart, and the second would
# stop the daemon the first had just started and recorded.

calls="$(grep -o 'ihar_with_lock --[a-z-]*' "$ROOT/lib/codex/daemon.sh" | sort -u)"
assert_eq "the daemon lock is required, never best-effort" "ihar_with_lock --required" "$calls"

# --- the field reader replaces jq ------------------------------------------------------------
#
# jq is not a dependency ihar may take on a correctness path: it is not guaranteed
# installed and its absence is quiet.

assert_eq "a top-level field is read" "restarted" \
  "$(printf '{"action":"restarted"}' | python3 -m ihar.codex.field action)"
assert_eq "and one nested under status" "0.154.0" \
  "$(printf '{"status":{"managedCodexVersion":"0.154.0"}}' | python3 -m ihar.codex.field managedCodexVersion)"
assert_eq "an absent field is an error, not an empty string" "1" \
  "$(printf '{}' | python3 -m ihar.codex.field nope >/dev/null 2>&1; echo $?)"
assert_eq "and so is input that is not JSON" "1" \
  "$(printf 'not json' | python3 -m ihar.codex.field action >/dev/null 2>&1; echo $?)"

# Commands, not comments: the file says the word "jq" while explaining why it never
# runs it, and a naive grep would count that as a violation.
assert_eq "no shell module shells out to jq" "0" \
  "$(grep -cE '^[[:space:]]*[^#]*[^a-z_]jq[[:space:]]' "$ROOT/lib/codex/daemon.sh")"

# --- update: stop what is running, put back only what was --------------------------------------

ROOTS="$IHAR_TEST_TMP/roots"
mkdir -p "$ROOTS/aaaaaaaa/daemons" "$ROOTS/bbbbbbbb/daemons"
sweep() { python3 -m ihar.codex.daemon "$1" --binary "$FAKE" --state-root "$ROOTS" 2>&1; }

# One live daemon, one whose process is gone. Only the live one is worth putting back.
sock_of() { printf '%s/app-server-control/app-server-control.sock' "$1"; }
python3 - "$ROOTS" "$FAKE" "$$" "$HOME_DIR" <<'PY'
import hashlib, json, os, sys
roots, binary, pid, home = sys.argv[1:5]
digest = hashlib.sha256(open(binary, "rb").read()).hexdigest()
for entry, live in (("aaaaaaaa", True), ("bbbbbbbb", False)):
    record = {"schema": 1, "pid": int(pid) if live else 999999,
              "socket": os.path.join(home, "app-server-control", "app-server-control.sock"),
              "binary_sha256": digest, "codex_version": "0.154.0",
              "config_hash": "aabbccdd", "started_at": "2026-09-19T07:00:00Z",
              "remote_control": False}
    json.dump(record, open(os.path.join(roots, entry, "daemons", "codex.json"), "w"))
PY

out="$(sweep stop-all)"
assert_contains "the live daemon is stopped" "$out" "$HOME_DIR"
assert_eq "exactly one was stopped" "1" \
  "$(python3 -c "import json,sys;print(len(json.loads(sys.stdin.read())))" <<<"$out")"
assert_exit "its record is cleared" 1 test -f "$ROOTS/aaaaaaaa/daemons/codex.json"
assert_exit "and so is the dead one's" 1 test -f "$ROOTS/bbbbbbbb/daemons/codex.json"
assert_exit "a note of what to put back is left" 0 test -f "$ROOTS/daemons-pending.json"

out="$(sweep start-pending)"
assert_contains "and it is put back" "$out" "$HOME_DIR"
assert_exit "the note is removed once it is" 1 test -f "$ROOTS/daemons-pending.json"
assert_exit "with a fresh record" 0 test -f "$ROOTS/aaaaaaaa/daemons/codex.json"
assert_exit "and nothing invented for the dead one" 1 test -f "$ROOTS/bbbbbbbb/daemons/codex.json"

assert_eq "a second start-pending does nothing" "[]" "$(sweep start-pending)"

assert_contains "the update stops the daemons before replacing the binary" \
  "$(cat "$ROOT/lib/store/install.sh")" "ihar_codex_daemon_stop_all"
assert_contains "and starts them after" \
  "$(cat "$ROOT/lib/store/install.sh")" "ihar_codex_daemon_start_pending"

# --- ihar check remains complete and read-only without project state --------------------------
#
# The closed Task 5 result no longer carries daemon or state-root fields. `check`
# still must not create state merely to report the profile, receipt and guarantee.

PROJECT="$IHAR_TEST_TMP/check-project"
mkdir -p "$PROJECT"
check() {
  ( cd "$PROJECT" && IHAR_STORE="$IHAR_STORE" IHAR_STATE_ROOT="$IHAR_STATE_ROOT" \
      "$ROOT/ihar.sh" "$@" ) 2>&1
}

check_out="$(check check)"
assert_contains "check remains complete without project state" "$check_out" "profile      standard"
assert_contains "check still carries the profile guarantee" "$check_out" "guarantee"
assert_contains "check still carries receipt state" "$check_out" "receipt missing receipt"
assert_exit "check does not create project state" 1 \
  test -e "$IHAR_STATE_ROOT/$(printf '%s' "$PROJECT" | sha256sum | cut -c1-8)"

assert_eq "an unknown daemon action is a usage error" "2" \
  "$(check daemon nonesuch >/dev/null 2>&1; echo $?)"

# --- the websocket client, against a stub server ----------------------------------------------
#
# The control socket is a WebSocket endpoint over a Unix socket, measured on 0.154.0:
# a newline-delimited request gets no answer, and an RFC 6455 upgrade is answered with
# 101 Switching Protocols. The stub speaks the same handshake so the client's framing
# is exercised without a live daemon.

ws_out="$(python3 "$ROOT/tests/fakes/ws-appserver.py" "$IHAR_TEST_TMP/ws.sock" 2>&1)"
assert_contains "the client completes the upgrade" "$ws_out" "upgrade ok"
assert_contains "and gets its request answered" "$ws_out" "initialize ok"
assert_contains "a fragmented reply is reassembled" "$ws_out" "fragmented ok"
assert_contains "a ping is answered with a pong" "$ws_out" "ping ok"
assert_contains "and a dropped connection raises AppServerError, not a socket error" \
  "$ws_out" "close ok"
assert_eq "no bare socket exception leaks out" "0" "$(grep -c 'close leaked' <<<"$ws_out")"

# --- live: the vendor's own daemon --------------------------------------------------------------

# Resolved here rather than inherited, and the same way test_hook_trust.sh resolves
# it. Leaving it to an exported IHAR_CODEX_BIN made the run depend on the caller's
# environment, and that same export broke test_adapters.sh, which asserts the default
# store path.
LIVE="${IHAR_LIVE_CODEX:-/home/ikeniborn/Documents/Project/icodex/.codex-isolated/bin/codex}"
if [[ -x "$LIVE" ]]; then
  LIVE_HOME="$IHAR_TEST_TMP/live/codex"
  mkdir -p "$LIVE_HOME/packages/standalone/current"
  printf 'sandbox_mode = "read-only"\napproval_policy = "never"\n' > "$LIVE_HOME/config.toml"
  ln -sf "$LIVE" "$LIVE_HOME/packages/standalone/current/codex"

  # Unconditional, and armed before the daemon starts. A test that starts a real
  # daemon and then fails an assertion would otherwise leave it running against a
  # temporary directory the sandbox is about to delete — which is exactly what the
  # first run of this file did.
  stop_live() {
    python3 -m ihar.codex.daemon stop --binary "$LIVE" --home "$LIVE_HOME" \
      --state "$STATE" >/dev/null 2>&1 || true
  }
  trap stop_live EXIT

  live_out="$(python3 -m ihar.codex.daemon start --binary "$LIVE" --home "$LIVE_HOME" \
                --state "$STATE" --config-hash aabbccdd 2>&1)"
  if grep -qE '"status": ?"started"' <<<"$live_out"; then
    assert_contains "a live daemon reports its socket" "$live_out" "app-server-control.sock"
    assert_exit "and the socket exists" 0 \
      test -S "$LIVE_HOME/app-server-control/app-server-control.sock"
    assert_exit "the record is written" 0 test -f "$STATE/daemons/codex.json"

    # The measurement this slice was blocked on: the control socket speaks WebSocket.
    probe="$(python3 -c "
import sys
sys.path.insert(0, '$ROOT/lib/python')
from ihar.codex.appserver import DaemonClient, daemon_socket
with DaemonClient(daemon_socket('$LIVE_HOME')) as client:
    result = client.request('thread/list', {'cwd': '$IHAR_TEST_TMP', 'limit': 1,
                                            'sortKey': 'updated_at',
                                            'sortDirection': 'desc', 'archived': False})
print('data' in (result or {}))" 2>&1)"
    assert_eq "a live daemon answers over the websocket transport" "True" "$probe"

    stop_live
    assert_exit "stopping removes the record" 1 test -f "$STATE/daemons/codex.json"
  else
    echo "SKIP [live daemon]: it did not start: ${live_out:0:120}"
  fi
else
  echo "SKIP [live daemon]: no codex binary"
fi

finish
