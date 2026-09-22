#!/usr/bin/env bash
# The multi-session console broker's lifecycle (LLD 13.2).
#
# The broker is per user, not per project: one window lists every project state on the
# machine. Its record and token therefore live under $IHAR_STATE_ROOT/console/, beside
# the gateway's own per-user tree, and only one broker may own that surface at a time.
#
# The broker is replaced rather than reused when the installed release changes, for the
# reason 5.5 restarts the Codex daemon: a surface serving a window from code that is no
# longer installed applies a policy nobody chose.
#
# Failure class: fail-closed. A bind that is not loopback, a missing token, a second
# broker, or a lock ihar cannot take aborts (exit 2 or 3). A tab that a profile refuses
# is refused in that tab and never stops the window.

_ihar_console_dir() { printf '%s/console' "$IHAR_STATE_ROOT"; }
_ihar_console_record() { printf '%s/daemon.json' "$(_ihar_console_dir)"; }

# _ihar_console_field <json> <key> — one scalar from the broker record, or the empty
# string. Python because jq is not guaranteed installed and fails quietly when absent.
_ihar_console_field() {
  printf '%s' "$1" | ihar_python -c 'import json,sys
try:
    print(json.load(sys.stdin).get(sys.argv[1], "") or "")
except Exception:
    print("")' "$2"
}

_ihar_console_pid() {
  local record; record="$(_ihar_console_record)"
  [[ -f "$record" ]] || return 1
  local pid; pid="$(_ihar_console_field "$(cat "$record")" pid)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && printf '%s' "$pid"
}

# _ihar_console_release — the installed release digest, or the empty string in a
# checkout that has no receipt. Compared against the running broker's own record.
_ihar_console_release() {
  local receipt="$IHAR_STORE/install-receipt.json"
  [[ -f "$receipt" ]] || return 0
  _ihar_console_field "$(cat "$receipt")" release_digest
}

# ihar_console_stop — stop a running broker. Supervisors are deliberately left alone:
# they are detached, and their tabs reattach to the next broker.
# stdout: one line. Exit 0 whether or not one was running.
ihar_console_stop() {
  local pid; pid="$(_ihar_console_pid)" || { printf 'console      not running\n'; return 0; }
  kill -TERM "$pid" 2>/dev/null || true
  local waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < 50 )); do sleep 0.1; waited=$((waited+1)); done
  rm -f -- "$(_ihar_console_record)"
  printf 'console      stopped (pid %s)\n' "$pid"
}

# ihar_console_start — start the broker under the console lock and print its URL.
# stdout: the loopback URL carrying the one-time token parameter.
ihar_console_start() {
  local pid
  if pid="$(_ihar_console_pid)"; then
    local running installed
    running="$(_ihar_console_field "$(cat "$(_ihar_console_record)")" release_digest)"
    installed="$(_ihar_console_release)"
    if [[ -n "$installed" && "$running" != "$installed" ]]; then
      ihar_warn "the running console broker predates the installed release; restarting it"
      ihar_console_stop >/dev/null
    else
      printf 'console      already running (pid %s, port %s)\n' \
        "$pid" "$(_ihar_console_field "$(cat "$(_ihar_console_record)")" port)"
      printf 'the token is at %s/token; it is not reprinted\n' "$(_ihar_console_dir)"
      return 0
    fi
  fi

  local dir interpreter
  dir="$(_ihar_console_dir)"
  mkdir -p -- "$dir"
  chmod 700 "$dir"
  interpreter="$(ihar_python_bin)" || ihar_die 3 "no usable Python interpreter for the console"

  # Detached on purpose: the broker outlives the terminal that started it, and its own
  # supervisors outlive the broker. Its stderr is kept so a start that fails can say why.
  (
    PYTHONPATH="$IHAR_ROOT/lib/python${PYTHONPATH:+:$PYTHONPATH}" \
    IHAR_ROOT="$IHAR_ROOT" IHAR_STORE="$IHAR_STORE" IHAR_STATE_ROOT="$IHAR_STATE_ROOT" \
    IHAR_CONSOLE_PORT="${IHAR_CONSOLE_PORT:-0}" \
    IHAR_CONSOLE_MAX_SESSIONS="${IHAR_CONSOLE_MAX_SESSIONS:-8}" \
    setsid "$interpreter" -m ihar.console.broker >/dev/null 2>>"$dir/broker.err" &
  )
  chmod 600 "$dir/broker.err" 2>/dev/null || true

  local waited=0
  while [[ ! -f "$(_ihar_console_record)" ]] && (( waited < 100 )); do
    sleep 0.1; waited=$((waited+1))
  done
  [[ -f "$(_ihar_console_record)" ]] || ihar_die 3 "the console broker did not start
$(tail -3 "$dir/broker.err" 2>/dev/null)"

  local record port token
  record="$(cat "$(_ihar_console_record)")"
  port="$(_ihar_console_field "$record" port)"
  token="$(cat "$dir/token")"
  printf 'console      running\n'
  printf 'open         http://127.0.0.1:%s/?t=%s\n' "$port" "$token"
  printf 'note         loopback only; reach it from another machine through an SSH tunnel\n'
}

# ihar_console_status — read-only facts about the broker and its tabs.
ihar_console_status() {
  local pid record
  if ! pid="$(_ihar_console_pid)"; then
    printf 'console      not running\n'
    return 0
  fi
  record="$(cat "$(_ihar_console_record)")"
  printf 'console      running (pid %s)\n' "$pid"
  printf 'port         %s\n' "$(_ihar_console_field "$record" port)"
  printf 'max sessions %s\n' "$(_ihar_console_field "$record" max_sessions)"
  local tab sid vendor profile exit_code
  for tab in "$(_ihar_console_dir)"/s/*.json; do
    [[ -f "$tab" ]] || continue
    sid="$(_ihar_console_field "$(cat "$tab")" sid)"
    vendor="$(_ihar_console_field "$(cat "$tab")" vendor)"
    profile="$(_ihar_console_field "$(cat "$tab")" profile)"
    exit_code="$(_ihar_console_field "$(cat "$tab")" exit_code)"
    printf 'tab          %s %s profile %s %s\n' "$sid" "$vendor" "$profile" \
      "${exit_code:+exited $exit_code}"
  done
}

# ihar_cmd_console — `ihar console start|status|stop|restart` (LLD 13.2).
#
# Every mutating action takes the console lock with --required: two brokers on one
# surface would race on the token and on the session cap, and the lock guards both.
ihar_cmd_console() {
  local action="${IHAR_SUBCOMMAND:-status}"
  case "$action" in
    start|status|stop|restart) ;;
    *) ihar_die 2 "ihar console: expected start, status, stop or restart, got '$action'" ;;
  esac
  ihar_state_setup "$IHAR_PROJECT_ROOT" >/dev/null
  mkdir -p -- "$(_ihar_console_dir)"

  local lock; lock="$(_ihar_console_dir)/lock"
  case "$action" in
    status) ihar_console_status ;;
    start)  ihar_with_lock --required "$lock" 10 ihar_console_start ;;
    stop)   ihar_with_lock --required "$lock" 10 ihar_console_stop ;;
    restart)
      ihar_with_lock --required "$lock" 10 ihar_console_stop >/dev/null
      ihar_with_lock --required "$lock" 10 ihar_console_start
      ;;
  esac
}
