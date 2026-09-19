#!/usr/bin/env bash
# ClaudeAdapter (LLD 5.3).
#
# Failure class: runtime for a missing binary; the vendor's own status otherwise.

adapter_claude_capabilities() {
  cat <<'JSON'
{
  "archive": false,
  "context_injection": ["initial_prompt", "append_system_prompt", "session_start_hook"],
  "fork": true,
  "hook_events": ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Stop"],
  "hook_input_rewrite": true,
  "hook_trust_api": false,
  "managed_hooks": false,
  "passthrough_separator": "--",
  "remote_control": true,
  "sandbox_modes": ["vendor-default", "read-only", "vendor", "microvm"],
  "schema": 1,
  "session_id_preset": true,
  "session_list_api": "sdk|jsonl",
  "vendor": "claude"
}
JSON
}

# adapter_claude_env <runtime> — the vendor-facing variables only this adapter sets.
adapter_claude_env() {
  local runtime="$1"
  CLAUDE_CONFIG_DIR="$runtime"
  # claude-agent-acp resolves the CLI from this rather than from PATH, so setting it
  # keeps the ACP surface on the same pinned binary as the native launch.
  CLAUDE_CODE_EXECUTABLE="$IHAR_CLAUDE_BIN"
  export CLAUDE_CONFIG_DIR CLAUDE_CODE_EXECUTABLE
  # Explicit mode costs Claude Remote Control, which refuses a custom base URL since
  # 2.1.196. The profile schema already refuses that combination, so reaching here
  # with both set is impossible rather than merely unlikely.
  if [[ "${IHAR_GATEWAY_MODE:-off}" == "explicit" ]]; then
    ANTHROPIC_BASE_URL="http://127.0.0.1:${IHAR_GATEWAY_ACTIVE_PORT}"
    export ANTHROPIC_BASE_URL
  fi
}

# _adapter_claude_argv <runtime> — the command this launch would run.
_adapter_claude_argv() {
  local runtime="$1"
  IHAR_ARGV=("$IHAR_CLAUDE_BIN")

  if [[ -n "$IHAR_FLAG_RESUME" ]]; then
    IHAR_ARGV+=(--resume "$IHAR_FLAG_RESUME")
    if [[ "$IHAR_FLAG_FORK" == true ]]; then IHAR_ARGV+=(--fork-session); fi
  else
    # ihar generates the session id so the index knows it before the vendor starts;
    # Codex has no equivalent, which is why its id is learned from a hook instead.
    IHAR_ARGV+=(--session-id "${IHAR_LAUNCH_ID:-$(ihar_uuid)}")
  fi

  # Written as `if` blocks rather than `[[ … ]] && …`: the launcher runs under
  # `set -e`, where a false test in an AND-list returns 1 and aborts the launch.
  if [[ -n "$IHAR_FLAG_NAME" ]];   then IHAR_ARGV+=(-n "$IHAR_FLAG_NAME"); fi
  if [[ -n "$IHAR_FLAG_MODEL" ]];  then IHAR_ARGV+=(--model "$IHAR_FLAG_MODEL"); fi
  if [[ -n "$IHAR_FLAG_EFFORT" ]]; then IHAR_ARGV+=(--effort "$IHAR_FLAG_EFFORT"); fi
  if [[ -n "${IHAR_HANDOFF_PENDING:-}" && "${IHAR_PROFILE_HANDOFF_SYSTEM_PROMPT:-false}" == true ]]; then
    IHAR_ARGV+=(--append-system-prompt "Continue from the ihar handoff in the initial prompt; preserve its constraints and verify its open items.")
  fi

  # Rendered by slice S6. Passing a path that does not exist would make the vendor
  # fail on a file the harness promised, so the flag appears only with the file.
  if [[ -f "$runtime/mcp/ihar.json" ]]; then
    IHAR_ARGV+=(--mcp-config "$runtime/mcp/ihar.json")
    if [[ "${IHAR_PROFILE_MCP_STRICT:-false}" == true ]]; then
      IHAR_ARGV+=(--strict-mcp-config)
    fi
  fi

  if [[ -n "${IHAR_FLAG_PROMPT:-}" ]]; then IHAR_ARGV+=("$IHAR_FLAG_PROMPT"); fi

  # Claude accepts `--` and dispatches what follows, including its own subcommands.
  if (( ${#IHAR_PASSTHROUGH[@]} )); then IHAR_ARGV+=(-- "${IHAR_PASSTHROUGH[@]}"); fi
  return 0
}

adapter_claude_launch() {
  local runtime="$1"
  adapter_claude_env "$runtime"
  _adapter_claude_argv "$runtime"
}

adapter_claude_switch_model() {
  local model="$1" effort="${2:-}"
  printf -- '--model %s' "$model"
  if [[ -n "$effort" ]]; then printf -- ' --effort %s' "$effort"; fi
  printf '\n'
}

adapter_claude_export_context() {
  local session="$1"
  ihar_python ihar.handoff.export claude "$IHAR_STATE/st/claude" "$session"
}
