#!/usr/bin/env bash
# Mutual exclusion with two modes (LLD 4.3).
#
# iclaude has one lock and it is fail-soft: a missing flock, an unwritable lock file
# or a timeout warns and runs the command unlocked. That is right for the session
# index and wrong for anything that mutates a security asset, because running
# unlocked there puts two writers on the thing the lock protects.
#
# Failure class: `--required` is fail-closed (exit 3). `--best-effort` is fail-soft.

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
    if exec {fd}>"$lockfile" 2>/dev/null; then
      if "$flock_bin" -w "$timeout" "$fd"; then
        local status=0
        "$@" || status=$?
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
