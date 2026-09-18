#!/usr/bin/env bash
# Mutual exclusion with two modes (LLD 4.3).
#
# iclaude has one lock and it is fail-soft: a missing flock, an unwritable lock file
# or a timeout warns and runs the command unlocked. That is right for the session
# index and wrong for anything that mutates a security asset, because running
# unlocked there puts two writers on the thing the lock protects.
#
# Failure class: `--required` is fail-closed (exit 3). `--best-effort` is fail-soft.

# The descriptors currently held, outermost first. A forked child inherits every one
# of them, and flock is released only when the last descriptor on the file closes — so
# a daemon started under a lock would hold that lock for its whole life. Measured: a
# plain `sleep 30 &` under a held lock keeps the next `flock -w 2` from ever taking it.
# Anything that spawns a process outliving its caller calls ihar_close_lock_fds first.
IHAR_LOCK_FDS=()

# ihar_close_lock_fds — drop the inherited lock descriptors. Only ever called in a
# forked child; calling it in the holding shell would release the lock early.
ihar_close_lock_fds() {
  local fd
  for fd in ${IHAR_LOCK_FDS[@]+"${IHAR_LOCK_FDS[@]}"}; do
    eval "exec ${fd}>&-" 2>/dev/null || true
  done
  IHAR_LOCK_FDS=()
}

# ihar_with_lock <--required|--best-effort> <lockfile> <timeout> <cmd...>
ihar_with_lock() {
  local mode="$1" lockfile="$2" timeout="$3"; shift 3

  case "$mode" in
    --required|--best-effort) ;;
    *) ihar_die 2 "ihar_with_lock: first argument must be --required or --best-effort, got '$mode'" ;;
  esac

  local flock_bin="${IHAR_FLOCK_BIN:-flock}"
  local reason=""

  if ! command -v "$flock_bin" >/dev/null 2>&1; then
    reason="flock is not installed"
  elif ! mkdir -p "$(dirname "$lockfile")" 2>/dev/null; then
    reason="cannot create $(dirname "$lockfile")"
  fi

  if [[ -z "$reason" ]]; then
    local fd
    # The braces matter. `exec {fd}>… 2>/dev/null` applies the stderr redirection to
    # the shell itself, permanently, so every later diagnostic — including the
    # abort message of a fail-closed check — would vanish into /dev/null. Grouping
    # scopes the redirection to the open attempt.
    if { exec {fd}>"$lockfile"; } 2>/dev/null; then
      if "$flock_bin" -w "$timeout" "$fd"; then
        local status=0
        IHAR_LOCK_FDS+=("$fd")
        "$@" || status=$?
        unset 'IHAR_LOCK_FDS[-1]'
        exec {fd}>&-
        return "$status"
      fi
      exec {fd}>&-
      reason="timed out after ${timeout}s"
    else
      reason="cannot open $lockfile"
    fi
  fi

  if [[ "$mode" == "--required" ]]; then
    ihar_die 3 "lock $lockfile is required and could not be taken: $reason"
  fi

  ihar_warn "lock $lockfile unavailable ($reason); continuing unlocked"
  "$@"
}
