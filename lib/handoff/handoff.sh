#!/usr/bin/env bash
# Cross-vendor handoff lifecycle (LLD 11).

ihar_cmd_switch() {
  [[ "$IHAR_FLAG_TO" == claude || "$IHAR_FLAG_TO" == codex ]] \
    || ihar_die 2 "switch needs --to claude or --to codex"
  [[ -z "${IHAR_SUBCOMMAND:-}" && ${#IHAR_ARGS[@]} -eq 0 ]] \
    || ihar_die 2 "switch accepts only --to claude or --to codex"
  [[ -n "${IHAR_LAUNCH_ID:-}" ]] || ihar_die 2 "switch must run inside an ihar session"
  ihar_state_setup "$IHAR_PROJECT_ROOT" >/dev/null
  local source
  source="$(ihar_python ihar.sessions.index show "$IHAR_STATE/sessions.jsonl" "$IHAR_LAUNCH_ID")" \
    || ihar_die 2 "unknown source session '$IHAR_LAUNCH_ID'"
  local source_vendor source_session source_profile target_id context payload summary=""
  read -r source_vendor source_session source_profile < <(
    printf '%s' "$source" | ihar_python -c 'import json,sys; r=json.load(sys.stdin); print(r["vendor"],r["vendor_session_id"],r["profile"])')
  ihar_profile_resolve "$source_profile"
  [[ "$source_vendor" != "$IHAR_FLAG_TO" ]] \
    || ihar_die 2 "source already uses $IHAR_FLAG_TO; use that vendor's model switch instead"
  target_id="$(ihar_uuid)"
  context="$(ihar_adapter "$source_vendor" export_context "$source_session")" \
    || context='{"open_items":[],"decisions":[],"decisions_heuristic":[],"recent_messages":[]}'
  case "${IHAR_DISTILLER:-fork}" in
    off) ;;
    local)
      summary="$(printf '%s' "$context" | ihar_python -c 'import json,sys; c=json.load(sys.stdin); print("; ".join([*c.get("open_items",[]),*c.get("decisions",[])]))')"
      ;;
    fork)
      local binary home
      if [[ "$source_vendor" == claude ]]; then binary="$IHAR_CLAUDE_BIN"; else binary="$IHAR_CODEX_BIN"; fi
      home="${IHAR_RUNTIME:-$IHAR_STATE/st/$source_vendor}"
      summary="$(ihar_python ihar.handoff.distill "$source_vendor" "$binary" "$home" "$source_session" "$IHAR_STATE")" \
        || ihar_warn "the handoff distiller failed; deterministic context remains"
      ;;
    *) ihar_die 2 "IHAR_DISTILLER must be fork, local or off" ;;
  esac
  if [[ -n "$summary" ]]; then
    context="$(printf '%s\n%s' "$context" "$summary" | ihar_python -c 'import json,sys; c=json.loads(sys.stdin.readline()); c["summary"]=sys.stdin.read(); print(json.dumps(c))')"
  fi
  payload="$(printf '%s\n%s\n' "$source" "$context" | ihar_python -c 'import json,sys; print(json.dumps({"source":json.loads(sys.stdin.readline()),"context":json.loads(sys.stdin.readline())}))')"
  printf '%s' "$payload" | ihar_python ihar.handoff.build --target "$IHAR_FLAG_TO" \
    --cwd "$IHAR_PROJECT_ROOT" --state "$IHAR_STATE" --token "$target_id" \
    --masking-level "${IHAR_GATEWAY_MASKING_LEVEL:-off}" >/dev/null \
    || ihar_die 3 "cannot build and sanitise the handoff package"
  ihar_python ihar.sessions.index handoff "$IHAR_STATE/sessions.jsonl" "$IHAR_LAUNCH_ID" \
    "$target_id" "$IHAR_FLAG_TO" "$source_profile" "$(basename "$IHAR_PROJECT_ROOT")" "$IHAR_PROJECT_ROOT" \
    || ihar_die 3 "cannot link the handoff sessions"
  IHAR_HANDOFF_TARGET_ID="$target_id"
  IHAR_FLAG_PROFILE="$source_profile"
  ihar_cmd_launch "$IHAR_FLAG_TO"
}

ihar_handoff_prepare() {
  local vendor="$1" pending="$IHAR_STATE/handoff/pending/$IHAR_LAUNCH_ID.md"
  [[ -f "$pending" ]] || return 0
  IHAR_HANDOFF_PENDING="$pending"
  if [[ "$vendor" == claude ]]; then
    IHAR_FLAG_PROMPT="$(cat "$pending")"
  else
    local sentinel="__IHAR_HANDOFF_PREFIX_END__"
    IHAR_FLAG_PROMPT="$({ ihar_python ihar.handoff.carrier prefix "$pending"; printf '%s' "$sentinel"; })"
    IHAR_FLAG_PROMPT="${IHAR_FLAG_PROMPT%"$sentinel"}"$'\n\n'"The remaining handoff context will arrive through the SessionStart hook."
  fi
}

ihar_handoff_consume_claude() {
  [[ "${IHAR_VENDOR:-}" == claude && -n "${IHAR_HANDOFF_PENDING:-}" ]] || return 0
  rm -f -- "$IHAR_HANDOFF_PENDING"
}

ihar_handoff_sweep() {
  [[ -n "${IHAR_STATE:-}" ]] || return 0
  find "$IHAR_STATE/handoff/pending" -type f -name '*.md' -mmin +1440 -delete 2>/dev/null || true
}
