#!/usr/bin/env bash
# Canonical session index and operator commands (LLD 10).
# Failure class: fail-soft for discovery and index writes; usage for bad commands.

# ihar_session_claim <vendor> <runtime-hash> — create the hook's launch claim.
ihar_session_claim() {
  local vendor="$1" runtime_hash="$2" out
  out="$(ihar_python ihar.sessions.index claim "$vendor" "$IHAR_PROFILE" "$runtime_hash" "$IHAR_STATE/launches" --ihar-id "$IHAR_LAUNCH_ID" 2>&1)" \
    || { ihar_warn "could not create the session launch claim: $out"; return 0; }
  IHAR_LAUNCH_CLAIM="$out"; export IHAR_LAUNCH_CLAIM
}

# ihar_session_append_launch <vendor> <vendor-session-id> — best-effort metadata.
ihar_session_append_launch() {
  local vendor="$1" vendor_id="$2"
  ihar_with_lock --best-effort "$IHAR_STATE/.ihar-sessions.lock" 5 \
    env PYTHONPATH="${IHAR_ROOT:?IHAR_ROOT is not set}/lib/python" \
    "$IHAR_PY" -m ihar.sessions.index launch "$IHAR_STATE/sessions.jsonl" \
    "$IHAR_LAUNCH_ID" "$vendor" "$vendor_id" "$(basename "$IHAR_PROJECT_ROOT")" \
    "$IHAR_PROJECT_ROOT" "$IHAR_PROFILE" \
    || ihar_warn "could not append the launch to the session index"
}

# ihar_sessions_needs_codex_guard — classify session work before command dispatch.
#
# Listing may fall back from the daemon to a short-lived Codex app-server. Resume
# resolves the durable vendor id without starting either vendor, then pins that
# decision so a changed index cannot route Codex after an unguarded classification.
ihar_sessions_needs_codex_guard() {
  local action="${IHAR_SUBCOMMAND:-list}" state resolved vendor="unresolved"
  case "$action" in
    list)
      if [[ -x "$IHAR_CODEX_BIN" ]]; then
        IHAR_SESSIONS_CODEX_PROBES=true
        export IHAR_SESSIONS_CODEX_PROBES
        return 0
      fi
      IHAR_SESSIONS_CODEX_PROBES=false
      export IHAR_SESSIONS_CODEX_PROBES
      return 1
      ;;
    resume)
      if (( ${#IHAR_ARGS[@]} == 1 )); then
        state="$(_ihar_project_state)"
        if [[ -f "$state/sessions.jsonl" ]] \
          && resolved="$(ihar_python ihar.sessions.index resolve \
               "$state/sessions.jsonl" "${IHAR_ARGS[0]}" 2>/dev/null)"; then
          IFS=$'\t' read -r vendor _ <<< "$resolved"
        fi
      fi
      IHAR_SESSIONS_RESUME_VENDOR="$vendor"
      export IHAR_SESSIONS_RESUME_VENDOR
      [[ "$vendor" == codex ]]
      ;;
    *) return 1 ;;
  esac
}

# ihar_cmd_sessions — list, resume or name canonical sessions.
ihar_cmd_sessions() {
  ihar_state_setup "$IHAR_PROJECT_ROOT" >/dev/null
  local index="$IHAR_STATE/sessions.jsonl" action="${IHAR_SUBCOMMAND:-list}"
  case "$action" in
    list)
      local daemon_home daemon_socket="" codex_binary=""
      daemon_home="$(_ihar_daemon_home 2>/dev/null || true)"
      [[ -n "$daemon_home" ]] && daemon_socket="$daemon_home/app-server-control/app-server-control.sock"
      [[ "${IHAR_SESSIONS_CODEX_PROBES:-false}" == true ]] && codex_binary="$IHAR_CODEX_BIN"
      ihar_python ihar.sessions.cli --index "$index" --ephemeral "$IHAR_STATE/ephemeral.jsonl" \
        --cwd "$IHAR_PROJECT_ROOT" --claude-home "$IHAR_STATE/st/claude" \
        --codex-home "$IHAR_STATE/st/codex" --codex-binary "$codex_binary" \
        --daemon-socket "$daemon_socket"
      ;;
    resume)
      [[ ${#IHAR_ARGS[@]} -eq 1 ]] || ihar_die 2 "sessions resume needs one ihar id"
      local resolved vendor vendor_id profile
      resolved="$(ihar_python ihar.sessions.index resolve "$index" "${IHAR_ARGS[0]}")" \
        || ihar_die 2 "unknown session '${IHAR_ARGS[0]}'"
      IFS=$'\t' read -r vendor vendor_id profile <<< "$resolved"
      [[ "${IHAR_SESSIONS_RESUME_VENDOR:-unresolved}" == "$vendor" ]] \
        || ihar_die 3 "session vendor changed after Codex guardian routing"
      IHAR_FLAG_RESUME="$vendor_id"
      IHAR_FLAG_PROFILE="$profile"
      IHAR_RESUME_IHAR_ID="${IHAR_ARGS[0]}"
      ihar_cmd_launch "$vendor"
      ;;
    name)
      [[ ${#IHAR_ARGS[@]} -eq 2 ]] || ihar_die 2 "sessions name needs an ihar id and title"
      ihar_python ihar.sessions.index name "$index" "${IHAR_ARGS[0]}" "${IHAR_ARGS[1]}" \
        || ihar_die 2 "unknown session '${IHAR_ARGS[0]}'"
      ;;
    *) ihar_die 2 "unknown sessions subcommand '$action'; known are list, resume, name" ;;
  esac
}
