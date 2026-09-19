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
    "$IHAR_PY" -m ihar.sessions.index launch "$IHAR_STATE/sessions.jsonl" \
    "$IHAR_LAUNCH_ID" "$vendor" "$vendor_id" "$(basename "$IHAR_PROJECT_ROOT")" \
    "$IHAR_PROJECT_ROOT" "$IHAR_PROFILE" \
    || ihar_warn "could not append the launch to the session index"
}

# ihar_cmd_sessions — list, resume or name canonical sessions.
ihar_cmd_sessions() {
  ihar_state_setup "$IHAR_PROJECT_ROOT" >/dev/null
  local index="$IHAR_STATE/sessions.jsonl" action="${IHAR_SUBCOMMAND:-list}"
  case "$action" in
    list)
      local daemon_home daemon_socket=""
      daemon_home="$(_ihar_daemon_home 2>/dev/null || true)"
      [[ -n "$daemon_home" ]] && daemon_socket="$daemon_home/app-server-control/app-server-control.sock"
      ihar_python ihar.sessions.cli --index "$index" --ephemeral "$IHAR_STATE/ephemeral.jsonl" \
        --cwd "$IHAR_PROJECT_ROOT" --claude-home "$IHAR_STATE/st/claude" \
        --codex-home "$IHAR_STATE/st/codex" --codex-binary "$IHAR_CODEX_BIN" \
        --daemon-socket "$daemon_socket"
      ;;
    resume)
      [[ ${#IHAR_ARGS[@]} -eq 1 ]] || ihar_die 2 "sessions resume needs one ihar id"
      local resolved vendor vendor_id profile
      resolved="$(ihar_python ihar.sessions.index resolve "$index" "${IHAR_ARGS[0]}")" \
        || ihar_die 2 "unknown session '${IHAR_ARGS[0]}'"
      IFS=$'\t' read -r vendor vendor_id profile <<< "$resolved"
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
