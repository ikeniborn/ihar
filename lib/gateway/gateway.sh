#!/usr/bin/env bash
# Gateway instances, refcounted and keyed by their whole configuration (LLD 8.1).
#
# Keying by mode alone was a defect the architecture review caught: two explicit
# launches with different masking levels would have shared one process, and one of
# them would silently have run under the other's policy. The key therefore covers
# everything that decides what the gateway does.
#
# Failure class: fail-closed. A profile that requires a gateway and does not get a
# healthy one aborts the launch (exit 3).

# ihar_gateway_key — the identity of the instance this launch needs.
ihar_gateway_key() {
  printf '%s\n' "$IHAR_PROFILE_GATEWAY" "$IHAR_GATEWAY_MASKING_LEVEL" \
                "${IHAR_GATEWAY_ENGINE:-presidio}" \
                "${IHAR_GATEWAY_ANTHROPIC_UPSTREAM:-default}" \
                "${IHAR_GATEWAY_OPENAI_UPSTREAM:-default}" \
                "${IHAR_GATEWAY_CHATGPT_UPSTREAM:-default}" \
                "route-policy-1" \
    | sha256sum | cut -c1-12
}

_ihar_gateway_dir() { printf '%s\n' "$IHAR_STATE_ROOT/gw/$1"; }

# ihar_gateway_acquire — start or attach, and register this process as a consumer.
ihar_gateway_acquire() {
  local key dir
  key="$(ihar_gateway_key)"
  dir="$(_ihar_gateway_dir "$key")"
  mkdir -p "$dir/consumers" || ihar_die 3 "cannot create the gateway state at $dir"

  ihar_with_lock --required "$dir/lock" 30 _ihar_gateway_acquire_locked "$key" "$dir" \
    || ihar_die 3 "gateway ($IHAR_PROFILE_GATEWAY) required by profile '$IHAR_PROFILE' did not become healthy"

  IHAR_GATEWAY_ACTIVE=1
  IHAR_GATEWAY_MODE="$IHAR_PROFILE_GATEWAY"
  IHAR_GATEWAY_KEY="$key"
  IHAR_GATEWAY_LOG_PATH="$dir/logs"
  export IHAR_GATEWAY_ACTIVE IHAR_GATEWAY_MODE IHAR_GATEWAY_ACTIVE_PORT \
         IHAR_GATEWAY_KEY IHAR_GATEWAY_LOG_PATH
}

_ihar_gateway_acquire_locked() {
  local key="$1" dir="$2" pid port

  _ihar_gateway_sweep "$dir"

  pid="$(cat "$dir/pid" 2>/dev/null || true)"
  port="$(cat "$dir/port" 2>/dev/null || true)"
  if [[ -n "$pid" && -n "$port" ]] && kill -0 "$pid" 2>/dev/null \
     && _ihar_gateway_healthy "$port"; then
    IHAR_GATEWAY_ACTIVE_PORT="$port"
    _ihar_gateway_register "$dir"
    return 0
  fi

  # Whatever was here is not answering, so the stale files go rather than being
  # attached to forever. The port it used is carried forward as a preference: the
  # base_url rendered into the vendor's configuration embeds it, so an ephemeral port
  # on every restart rewrote config.toml, and the runtime home keyed by that
  # configuration then failed its own drift check — a fail-closed abort of every
  # second launch.
  # Held in a variable and cleared on disk, so the wait loop below cannot mistake the
  # remembered value for a port the new server has already published.
  local preferred="${port:-0}"
  rm -f "$dir/pid" "$dir/port"

  local enforced=()
  [[ "$IHAR_PROFILE_HOOKS" == "enforced" ]] && enforced=(--enforced)

  # The server outlives this function by design, so the child must first drop the
  # flock descriptor it inherits: flock releases only when the last descriptor on the
  # file closes, and keeping it would hold the gateway lock for the gateway's whole
  # life — the next launch's release then sat there until it timed out.
  #
  # `exec` the interpreter rather than calling ihar_python, so that the pid recorded
  # here is the server itself and not a shell that happens to be its parent; a kill
  # aimed at that shell would leave the server running.
  local py
  py="$(ihar_python_bin)"
  (
    ihar_close_lock_fds
    exec env PYTHONPATH="$IHAR_ROOT/lib/python${PYTHONPATH:+:$PYTHONPATH}" \
      "$py" -m ihar.gateway.explicit \
      --port "$preferred" --port-file "$dir/port" --log-dir "$dir/logs" \
      --level "$IHAR_GATEWAY_MASKING_LEVEL" \
      --engine "${IHAR_GATEWAY_ENGINE:-presidio}" \
      "${enforced[@]}"
  ) </dev/null >/dev/null 2>"$dir/stderr" &
  printf '%s\n' "$!" > "$dir/pid"

  local waited=0
  while (( waited < 150 )); do
    port="$(cat "$dir/port" 2>/dev/null || true)"
    if [[ -n "$port" ]] && _ihar_gateway_healthy "$port"; then
      IHAR_GATEWAY_ACTIVE_PORT="$port"
      _ihar_gateway_register "$dir"
      return 0
    fi
    kill -0 "$(cat "$dir/pid")" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done

  ihar_warn "the gateway did not answer: $(tail -3 "$dir/stderr" 2>/dev/null || true)"
  return 1
}

# _ihar_gateway_healthy <port> — the probe the listener answers itself, never the
# vendor. In transparent mode this is what proves the interception is in place.
_ihar_gateway_healthy() {
  ihar_python ihar.gateway.probe "$1" >/dev/null 2>&1
}

_ihar_gateway_register() {
  printf '%s\n' "$$" > "$1/consumers/$$.pid"
}

# _ihar_gateway_sweep <dir> — drop consumer files whose process is gone, so a crashed
# launch does not keep an instance alive forever.
_ihar_gateway_sweep() {
  local file pid
  for file in "$1"/consumers/*.pid; do
    [[ -e "$file" ]] || continue
    pid="$(basename "$file" .pid)"
    kill -0 "$pid" 2>/dev/null || rm -f "$file"
  done
}

# ihar_gateway_release — the last consumer of an instance stops it.
ihar_gateway_release() {
  [[ -n "${IHAR_GATEWAY_KEY:-}" ]] || return 0
  local dir
  dir="$(_ihar_gateway_dir "$IHAR_GATEWAY_KEY")"
  ihar_with_lock --best-effort "$dir/lock" 5 _ihar_gateway_release_locked "$dir"
}

_ihar_gateway_release_locked() {
  local dir="$1" pid
  rm -f "$dir/consumers/$$.pid"
  _ihar_gateway_sweep "$dir"
  compgen -G "$dir/consumers/*.pid" >/dev/null && return 0

  pid="$(cat "$dir/pid" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 0
  kill "$pid" 2>/dev/null || true
  # The port file outlives the instance on purpose — it is what the next start asks
  # for, so that the configuration rendered for this key stays the same one.
  rm -f "$dir/pid"
}

# ihar_gateway_status — every instance, for ihar check.
ihar_gateway_status() {
  local root="$IHAR_STATE_ROOT/gw" dir key pid port consumers
  [[ -d "$root" ]] || return 0
  for dir in "$root"/*/; do
    [[ -d "$dir" ]] || continue
    key="$(basename "$dir")"
    pid="$(cat "$dir/pid" 2>/dev/null || echo -)"
    port="$(cat "$dir/port" 2>/dev/null || echo -)"
    consumers="$(find "$dir/consumers" -name '*.pid' 2>/dev/null | wc -l)"
    printf '             instance %s port %s pid %s consumers %s\n' \
      "$key" "$port" "$pid" "$consumers"
  done
}
