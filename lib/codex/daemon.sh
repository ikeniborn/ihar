#!/usr/bin/env bash
# The managed Codex app-server daemon (LLD 5.5).
#
# Codex does not isolate per-client environment: every client of a daemon sees the
# environment it inherited at start. A daemon started under `standard` will therefore
# serve a `protected` launch without complaint, applying a configuration nobody chose.
# Reconciliation is what stops that, and it runs before the launch rather than after.
#
# Failure class: fail-closed. A mismatch ihar cannot resolve aborts the launch (exit 3).

# ihar_render_standalone_link <render-dir> — the path `daemon start` insists on.
#
# `codex app-server daemon start` refuses outright unless a managed standalone install
# exists at `$CODEX_HOME/packages/standalone/current/codex`, which is the layout the
# official Codex installer produces:
#
#   Error: managed standalone Codex install not found at <home>/packages/standalone/current/codex
#
# ihar installs a release tarball into its own store instead, so without this the
# daemon could never start at all. Measured on 0.154.0: a symlink at that path is
# accepted, and `daemon start` then reports the store binary as its managedCodexPath.
#
# The link is rendered rather than created in the published home, because the runtime
# home is never written to after publication (LLD 4.2).
ihar_render_standalone_link() {
  # Two statements. `local a="$1" b="$a/x"` declares every name before it performs the
  # assignments, so the second right-hand side reads the enclosing scope and `set -u`
  # aborts — which is how this arrived as "render: unbound variable".
  local render="$1"
  local target="$render/packages/standalone/current"
  [[ -x "$IHAR_CODEX_BIN" ]] || return 0
  mkdir -p "$target" || ihar_die 3 "cannot create $target"
  ln -sfn "$IHAR_CODEX_BIN" "$target/codex" \
    || ihar_die 3 "cannot link the standalone Codex path into the runtime home"
}

# ihar_codex_daemon_reconcile <runtime> <config-hash> — step 8 of the lifecycle.
#
# Under a required lock: two launches reconciling at once could both decide to
# restart, and the second would stop the daemon the first had just started and
# recorded, leaving its record pointing at a dead process.
ihar_codex_daemon_reconcile() {
  local runtime="$1" hash="$2"
  [[ "${IHAR_VENDOR:-}" == codex || -z "${IHAR_VENDOR:-}" ]] || return 0
  [[ -x "$IHAR_CODEX_BIN" ]] || return 0

  # No daemon has ever run here and none is listening: the common case, and worth
  # answering without taking a lock or starting a process.
  [[ -S "$runtime/app-server-control/app-server-control.sock" ]] || return 0

  ihar_with_lock --required "$IHAR_STATE/.ihar-daemon.lock" 60 \
    _ihar_codex_daemon_reconcile "$runtime" "$hash"
}

_ihar_codex_daemon_reconcile() {
  local runtime="$1" hash="$2" out status=0
  out="$(ihar_python ihar.codex.daemon reconcile \
          --binary "$IHAR_CODEX_BIN" --home "$runtime" \
          --state "$IHAR_STATE" --config-hash "$hash" \
          --auth-store "$IHAR_STORE" 2>&1)" || status=$?

  case "$status" in
    0)
      local action
      action="$(_ihar_daemon_field "$out" action)"
      if [[ "$action" == restarted ]]; then
        ihar_info "the Codex daemon was restarted: $(_ihar_daemon_field "$out" reason)"
      fi
      return 0
      ;;
    3)
      ihar_die 3 "a Codex app-server daemon is running under $runtime that ihar did not start, and it does not match this launch:
$(_ihar_daemon_field "$out" reason)
stop it yourself, or run 'ihar daemon stop' if it is in fact ours"
      ;;
    *)
      # The reconciler itself failed. That is not evidence the daemon is fine, and a
      # launch served by an unexamined daemon is the case this step exists to prevent.
      ihar_die 3 "cannot reconcile the Codex daemon: ${out:-no output}"
      ;;
  esac
}

# _ihar_daemon_field <json> <key> — one string field, without a jq dependency.
_ihar_daemon_field() {
  printf '%s' "$1" | ihar_python ihar.codex.field "$2" 2>/dev/null || printf 'unknown\n'
}

# ihar_codex_daemon_stop_all — take down every daemon ihar recorded, before the
# binary they are running is replaced (LLD 5.5, plan task S6.4).
#
# A daemon whose owner cannot be verified blocks replacement of its binary.
ihar_codex_daemon_stop_all() {
  [[ -x "$IHAR_CODEX_BIN" ]] || return 0
  [[ -d "$IHAR_STATE_ROOT" ]] || return 0
  local out
  out="$(ihar_python ihar.codex.daemon stop-all --binary "$IHAR_CODEX_BIN" \
          --state-root "$IHAR_STATE_ROOT" --auth-store "$IHAR_STORE" 2>&1)" \
    || ihar_die 3 "could not stop the managed Codex daemons: ${out:-no output}"
  [[ "$out" == "[]" ]] || ihar_info "stopped the managed Codex daemons for the update"
}

# ihar_codex_daemon_start_pending — put back exactly what stop_all took down.
ihar_codex_daemon_start_pending() {
  [[ -x "$IHAR_CODEX_BIN" ]] || return 0
  [[ -d "$IHAR_STATE_ROOT" ]] || return 0
  local out
  out="$(ihar_python ihar.codex.daemon start-pending --binary "$IHAR_CODEX_BIN" \
          --state-root "$IHAR_STATE_ROOT" --auth-store "$IHAR_STORE" 2>&1)" \
    || ihar_die 3 "could not restart the managed Codex daemons: ${out:-no output}"
  [[ "$out" == "[]" ]] || ihar_info "restarted the managed Codex daemons"
}

# ihar_codex_remote_start <runtime> <config-hash> — prepare the native hosted bridge.
ihar_codex_remote_start() {
  ihar_with_lock --required "$IHAR_STATE/.ihar-daemon.lock" 60 \
    _ihar_codex_remote_start "$1" "$2"
}

_ihar_codex_remote_start() {
  local runtime="$1" hash="$2" out
  if [[ -S "$runtime/app-server-control/app-server-control.sock" ]]; then
    out="$(ihar_python ihar.codex.daemon reconcile --binary "$IHAR_CODEX_BIN" \
      --home "$runtime" --state "$IHAR_STATE" --config-hash "$hash" \
      --auth-store "$IHAR_STORE" 2>&1)" \
      || ihar_die 3 "cannot reconcile the Codex Remote Control daemon: ${out:-no output}"
  else
    out="$(ihar_python ihar.codex.daemon start --binary "$IHAR_CODEX_BIN" \
      --home "$runtime" --state "$IHAR_STATE" --config-hash "$hash" \
      --auth-store "$IHAR_STORE" 2>&1)" \
      || ihar_die 3 "cannot start the Codex app-server daemon: ${out:-no output}"
  fi

  CODEX_HOME="$runtime" ihar_python ihar.codex.auth_owner run \
    "$IHAR_STORE" "$runtime" "$hash" attached -- \
    "$IHAR_CODEX_BIN" app-server daemon enable-remote-control \
    >/dev/null || ihar_die 3 "cannot enable Codex Remote Control"
  CODEX_HOME="$runtime" ihar_python ihar.codex.auth_owner run \
    "$IHAR_STORE" "$runtime" "$hash" attached -- \
    "$IHAR_CODEX_BIN" remote-control pair \
    || ihar_die 3 "cannot create a Codex Remote Control pairing code"
  ihar_python ihar.codex.daemon mark-remote --binary "$IHAR_CODEX_BIN" \
    --home "$runtime" --state "$IHAR_STATE" --config-hash "$hash" \
    --auth-store "$IHAR_STORE" >/dev/null \
    || ihar_die 3 "cannot record the Codex Remote Control daemon"
}

# ihar_check_daemon — one line for `ihar check`, truthful when there is no daemon.
#
# Reported even when absent, because "no daemon" and "a daemon nobody examined" are
# different states and a report that showed nothing for both would hide the second.
ihar_check_daemon() {
  local home socket
  home="$(_ihar_daemon_home 2>/dev/null || true)"
  if [[ -z "$home" ]]; then
    printf 'daemon       none; no Codex runtime home in this project yet\n'
    return 0
  fi
  socket="$home/app-server-control/app-server-control.sock"
  if [[ ! -S "$socket" ]]; then
    printf 'daemon       not running (%s)\n' "$home"
    return 0
  fi
  local claim="unrecorded, so a mismatch would refuse the launch"
  [[ -f "$(_ihar_project_state)/daemons/codex.json" ]] && claim="started by ihar"
  printf 'daemon       running, %s\n' "$claim"
  printf '             %s\n' "$socket"
}

# ihar_cmd_daemon — `ihar daemon status|stop|restart` (LLD 5.5).
#
# Operating on the runtime home of the profile in force, because that is the home a
# daemon serves: there is one daemon per CODEX_HOME, and two profiles are two homes.
ihar_cmd_daemon() {
  local action="${IHAR_SUBCOMMAND:-status}"
  case "$action" in
    status|stop|restart) ;;
    *) ihar_die 2 "ihar daemon: expected status, stop or restart, got '$action'" ;;
  esac

  ihar_profile_resolve "$IHAR_FLAG_PROFILE"
  ihar_state_setup "$IHAR_PROJECT_ROOT" >/dev/null
  [[ -x "$IHAR_CODEX_BIN" ]] || ihar_die 1 "the codex binary is not installed at $IHAR_CODEX_BIN
run 'ihar install'"

  local home
  home="$(_ihar_daemon_home)"
  if [[ -z "$home" ]]; then
    printf 'daemon       no runtime home for profile %s yet; launch codex once\n' "$IHAR_PROFILE"
    return 0
  fi

  local out status=0
  out="$(ihar_python ihar.codex.daemon "$action" \
          --binary "$IHAR_CODEX_BIN" --home "$home" --state "$IHAR_STATE" \
          --auth-store "$IHAR_STORE" 2>&1)" || status=$?

  if [[ "$IHAR_FLAG_JSON" == true ]]; then
    printf '%s\n' "$out"
    return "$status"
  fi

  printf 'home         %s\n' "$home"
  printf 'daemon       %s\n' "$(_ihar_daemon_field "$out" status)"
  printf 'socket       %s\n' "$(_ihar_daemon_field "$out" socketPath)"
  printf 'version      %s\n' "$(_ihar_daemon_field "$out" managedCodexVersion)"
  return "$status"
}

# _ihar_project_state — this project's state directory, derived rather than created.
#
# `ihar check` reports without mutating anything, so it never calls ihar_state_setup
# and IHAR_STATE is unset there. Reading it unguarded aborted the whole report under
# `set -u`, and every line after the daemon's vanished with it.
_ihar_project_state() {
  if [[ -n "${IHAR_STATE:-}" ]]; then
    printf '%s\n' "$IHAR_STATE"
    return 0
  fi
  [[ -n "${IHAR_STATE_ROOT:-}" && -n "${IHAR_PROJECT_ROOT:-}" ]] || return 0
  printf '%s/%s\n' "$IHAR_STATE_ROOT" "$(ihar_home_id "$IHAR_PROJECT_ROOT")"
}

# _ihar_daemon_home — the newest Codex runtime home under this project's state.
#
# Newest rather than the one this profile would render: rendering here would need the
# gateway to be up, and asking for a daemon's status is not a reason to start one.
_ihar_daemon_home() {
  local state home newest=""
  state="$(_ihar_project_state)"
  [[ -n "$state" ]] || return 0
  for home in "$state"/r/*/codex; do
    [[ -d "$home" ]] || continue
    if [[ -z "$newest" || "$home" -nt "$newest" ]]; then newest="$home"; fi
  done
  printf '%s\n' "$newest"
}
