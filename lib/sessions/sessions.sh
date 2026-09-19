#!/usr/bin/env bash
# Canonical session index and operator commands (LLD 10).
# Failure class: fail-soft for discovery and index writes; usage for bad commands.

# ihar_session_claim <vendor> <runtime-hash> — create the hook's launch claim.
ihar_session_claim() {
  local vendor="$1" runtime_hash="$2" out
  out="$(ihar_python ihar.sessions.index claim "$vendor" "$IHAR_PROFILE" "$runtime_hash" "$IHAR_STATE/launches" 2>&1)" \
    || { ihar_warn "could not create the session launch claim: $out"; return 0; }
  IHAR_LAUNCH_CLAIM="$out"; export IHAR_LAUNCH_CLAIM
}

# ihar_session_append_launch <vendor> <vendor-session-id> — best-effort metadata.
ihar_session_append_launch() {
  local vendor="$1" vendor_id="$2" now record
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  record="$(printf '{"schema":1,"ihar_id":"%s","vendor":"%s","vendor_session_id":"%s","project":"%s","cwd":"%s","git_branch":null,"title":null,"model":null,"profile":"%s","started_at":"%s","updated_at":"%s","parent_ihar_id":null,"handoff_from":null,"handoff_to":null,"tags":[],"source":"launch"}' \
    "$IHAR_LAUNCH_ID" "$vendor" "$vendor_id" "$(basename "$IHAR_PROJECT_ROOT")" "$IHAR_PROJECT_ROOT" "$IHAR_PROFILE" "$now" "$now")"
  ihar_with_lock --best-effort "$IHAR_STATE/.ihar-sessions.lock" 5 \
    bash -c 'printf "%s" "$1" | "$2" -m ihar.sessions.index append "$3"' \
    -- "$record" "$IHAR_PY" "$IHAR_STATE/sessions.jsonl" \
    || ihar_warn "could not append the launch to the session index"
}

# ihar_cmd_sessions — list, resume or name canonical sessions.
ihar_cmd_sessions() {
  ihar_state_setup "$IHAR_PROJECT_ROOT" >/dev/null
  local index="$IHAR_STATE/sessions.jsonl" action="${IHAR_SUBCOMMAND:-list}"
  case "$action" in
    list)
      ihar_python ihar.sessions.cli --index "$index" --ephemeral "$IHAR_STATE/ephemeral.jsonl" \
        --cwd "$IHAR_PROJECT_ROOT" --claude-home "$IHAR_STATE/st/claude" \
        --codex-home "$IHAR_STATE/st/codex" --codex-binary "$IHAR_CODEX_BIN"
      ;;
    resume)
      [[ ${#IHAR_ARGS[@]} -eq 1 ]] || ihar_die 2 "sessions resume needs one ihar id"
      local resolved vendor vendor_id
      resolved="$(ihar_python ihar.sessions.index resolve "$index" "${IHAR_ARGS[0]}")" \
        || ihar_die 2 "unknown session '${IHAR_ARGS[0]}'"
      IFS=$'\t' read -r vendor vendor_id <<< "$resolved"
      IHAR_FLAG_RESUME="$vendor_id"
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
