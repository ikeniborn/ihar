#!/usr/bin/env bash
# CodexAdapter (LLD 5.4).
#
# Failure class: runtime for a missing binary; the vendor's own status otherwise.

adapter_codex_capabilities() {
  cat <<'JSON'
{
  "archive": true,
  "context_injection": ["initial_prompt", "session_start_hook"],
  "fork": true,
  "hook_events": ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Stop", "Interrupt"],
  "hook_input_rewrite": true,
  "hook_trust_api": true,
  "managed_hooks": true,
  "passthrough_separator": "none",
  "remote_control": true,
  "sandbox_modes": ["vendor-default", "read-only", "vendor", "microvm"],
  "schema": 1,
  "session_id_preset": false,
  "session_list_api": "app-server|sqlite",
  "vendor": "codex"
}
JSON
}

adapter_codex_env() {
  local runtime="$1"
  CODEX_HOME="$runtime"
  CODEX_PATH="$IHAR_CODEX_BIN"
  # The store bin carries the rg and tree shims icodex installs for agent workflows.
  PATH="$IHAR_STORE/bin:$PATH"
  export CODEX_HOME CODEX_PATH PATH
}

_adapter_codex_argv() {
  IHAR_ARGV=("$IHAR_CODEX_BIN")

  if [[ -n "$IHAR_FLAG_RESUME" ]]; then
    if [[ "$IHAR_FLAG_FORK" == true ]]; then
      IHAR_ARGV+=(fork "$IHAR_FLAG_RESUME")
    else
      IHAR_ARGV+=(resume "$IHAR_FLAG_RESUME")
    fi
  fi

  # `if` blocks, not `[[ … ]] && …`: under `set -e` a false test in an AND-list
  # returns 1 and would abort the launch.
  if [[ -n "$IHAR_FLAG_MODEL" ]]; then IHAR_ARGV+=(-m "$IHAR_FLAG_MODEL"); fi
  if [[ -n "$IHAR_FLAG_EFFORT" ]]; then
    IHAR_ARGV+=(-c "model_reasoning_effort=\"$IHAR_FLAG_EFFORT\"")
  fi
  if [[ "$IHAR_FLAG_WEB" == true ]]; then
    IHAR_ARGV+=(--remote "unix://$IHAR_RUNTIME/app-server-control/app-server-control.sock")
  fi

  # Mode, approval, trust, provider, MCP and hooks are not -c overrides: they live in
  # the rendered config.toml so that `codex mcp list`, `codex resume` and the daemon
  # see the same configuration as the TUI. icodex passes openai_base_url at launch
  # and that is exactly the divergence this avoids.

  # Codex is clap and rejects a bare `--`: `codex -- mcp list` answers
  # "unexpected argument 'list' found". The tokens go on unseparated.
  if [[ -n "${IHAR_FLAG_PROMPT:-}" ]]; then IHAR_ARGV+=("$IHAR_FLAG_PROMPT"); fi

  if (( ${#IHAR_PASSTHROUGH[@]} )); then IHAR_ARGV+=("${IHAR_PASSTHROUGH[@]}"); fi
  return 0
}

adapter_codex_launch() {
  local runtime="$1"
  adapter_codex_env "$runtime"
  _adapter_codex_argv
}

adapter_codex_start_remote() {
  local runtime="$1" hash="$2"
  [[ "$IHAR_FLAG_DRY_RUN" == true ]] && return 0
  ihar_codex_remote_start "$runtime" "$hash"
}

adapter_codex_switch_model() {
  local model="$1" effort="${2:-}"
  printf -- '-m %s' "$model"
  if [[ -n "$effort" ]]; then printf -- ' -c model_reasoning_effort="%s"' "$effort"; fi
  printf '\n'
}

adapter_codex_archive() {
  local runtime="$1" session="$2"
  CODEX_HOME="$runtime" "$IHAR_CODEX_BIN" archive "$session" >/dev/null 2>&1 \
    || ihar_warn "could not archive Codex session $session"
}

adapter_codex_export_context() {
  local session="$1"
  ihar_python ihar.handoff.export codex "$IHAR_STATE/st/codex" "$session"
}
