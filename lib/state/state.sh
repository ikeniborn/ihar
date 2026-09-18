#!/usr/bin/env bash
# Project state: the per-project tree that survives every profile switch (LLD 2.4).
#
# Failure class: runtime for a tree that cannot be created, usage for a path the
# platform cannot hold.

# ihar_project_root [dir] — the git top level, else the physical working directory.
ihar_project_root() {
  local dir="${1:-$PWD}"
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null || (cd "$dir" && pwd -P)
}

# ihar_home_id <root> — sha256(project root), first eight characters.
#
# iclaude prefixes the sanitised basename (lib/config/isolated.sh:resolve_claude_home_id)
# and that is friendlier to read, but it does not fit here: the Codex daemon opens a
# socket under this directory and the platform caps that path near 108 bytes. The
# readable form measured 120 for an ordinary project, so the id is the hash alone and
# the project it belongs to is read from the marker instead.
#
# Eight hex is 32 bits, so distinct projects can in principle collide. The marker
# guard is what makes that safe rather than silent: a state directory recording a
# different project aborts instead of attaching a session to the wrong one.
ihar_home_id() {
  local root="$1"
  printf '%s' "$root" | sha256sum | cut -c1-8
}

# ihar_state_preflight <state-dir> — refuse a state path the Codex daemon socket
# cannot fit in (LLD 2.2). The limit is the platform's sun_path, about 108 bytes on
# Linux; IHAR_SOCKET_PATH_MAX keeps headroom. Measured before anything is created,
# because a half-built tree under an unusable path helps nobody.
ihar_state_preflight() {
  local state="$1"
  local socket="$state/r/00000000/codex/app-server-control/app-server-control.sock"
  local length=${#socket}
  # Defaulted here as well as in ihar_init, so the check holds for a caller that
  # sourced only this module. A preflight that silently does not run is worse than
  # no preflight, because the failure then surfaces as a daemon that will not start.
  local limit="${IHAR_SOCKET_PATH_MAX:-107}"
  if (( length > limit )); then
    ihar_die 2 "state path too long for a Codex daemon socket ($length > $limit bytes): $socket
set IHAR_STATE_ROOT to a shorter directory"
  fi
  return 0
}

# ihar_state_setup <root> — create the state tree and the marker, export IHAR_STATE.
ihar_state_setup() {
  local root="$1" id state
  id="$(ihar_home_id "$root")"
  state="$IHAR_STATE_ROOT/$id"

  ihar_state_preflight "$state"

  mkdir -p "$state/st/claude" "$state/st/codex" "$state/r" \
           "$state/handoff/pending" "$state/daemons" "$state/launches" \
    || ihar_die 1 "cannot create the state tree at $state"
  chmod 700 "$state/handoff" 2>/dev/null || true

  ihar_with_lock --required "$state/.ihar.lock" 30 _ihar_state_marker "$state" "$root"

  IHAR_STATE="$state"
  export IHAR_STATE
  printf '%s\n' "$state"
}

# _ihar_state_marker <state> <root> — write home.json on first creation, upgrade an
# older schema in place. Schema 1 is the iclaude marker and schema 2 was LLD
# revision 2's; both predate the split of state from runtime configuration.
_ihar_state_marker() {
  # Split deliberately. In one `local`, a right-hand side referring to a name on the
  # same line is evaluated against the enclosing scope, not the new local: this line
  # only ever worked because the caller happens to have a `state` holding the same
  # path. Without that coincidence it would abort under `set -u`.
  local state="$1" root="$2"
  local marker="$state/home.json"
  ihar_python ihar.state_marker "$marker" "$root" \
    || ihar_die 1 "cannot write the state marker at $marker"
}
