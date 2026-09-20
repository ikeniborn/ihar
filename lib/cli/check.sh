#!/usr/bin/env bash
# Collect one validated status result, then render it without persistent writes.

ihar_check_receipt_status() { # <vendor> <binary>
  ihar_python ihar.check_result receipt "$IHAR_STORE/install-receipt.json" \
    "$IHAR_LOCKFILE" "$1" "$2"
}

ihar_check_conformance_status() { # <vendor> <binary>
  local vendor="$1" binary="$2" record
  [[ -x "$binary" ]] || { printf 'not-installed\n'; return 0; }
  record="$IHAR_STORE/verification/$vendor-$(ihar_version_slug "$binary").json"
  [[ -f "$record" ]] || { printf 'unproven\n'; return 0; }
  if ihar_python ihar.conformance.check "$record" "$binary" \
       "$IHAR_ROOT/manifests/hooks.json" >/dev/null 2>&1; then
    printf 'proven\n'
  else
    printf 'stale\n'
  fi
}

# ihar_check_collect <target-json> — gather every fact exactly once.
ihar_check_collect() {
  local target="$1" vendor binary capabilities notes
  ihar_profile_resolve "$IHAR_FLAG_PROFILE"
  ihar_env_prepare claude

  _IHAR_CHECK_MASK_ENGINE="$(ihar_python ihar.mask.describe "$IHAR_GATEWAY_MASKING_LEVEL" 2>/dev/null || echo unknown)"
  _IHAR_CHECK_DROPPED_ENV="$(printf '%s\n' "${IHAR_ENV_DROPPED[@]:-}" | sed '/^$/d' | sort -u)"
  _IHAR_CHECK_GATEWAY_INSTANCES="$(ihar_gateway_status | sed 's/^[[:space:]]*//')"
  _IHAR_CHECK_ASSETS="$(ihar_asset_diagnostics)" || return $?
  _IHAR_CHECK_KNOWN_GAPS=$'claude-agent-acp #144: settings hooks may not fire\ncodex-acp #310/#477: sandbox and approval policy are overridden'

  for vendor in claude codex; do
    binary="$(eval echo "\$IHAR_${vendor^^}_BIN")"
    capabilities="$(ihar_adapter "$vendor" capabilities)" || return $?
    notes="$(ihar_python ihar.render.mcp "$vendor" "$IHAR_PROFILE" \
      "$IHAR_ROOT/manifests/mcp/registry.json" --report 2>&1)" || true
    printf -v "_IHAR_CHECK_${vendor^^}_CAPABILITIES" '%s' "$capabilities"
    printf -v "_IHAR_CHECK_${vendor^^}_RECEIPT" '%s' \
      "$(ihar_check_receipt_status "$vendor" "$binary")"
    printf -v "_IHAR_CHECK_${vendor^^}_HOOKS" '%s' "$IHAR_PROFILE_HOOKS"
    printf -v "_IHAR_CHECK_${vendor^^}_CONFORMANCE" '%s' \
      "$(ihar_check_conformance_status "$vendor" "$binary")"
    printf -v "_IHAR_CHECK_MCP_${vendor^^}" '%s' "$notes"
  done

  export IHAR_PROFILE IHAR_PROFILE_GUARANTEE IHAR_PROFILE_MASKING_LEVEL
  export IHAR_GATEWAY_MASKING_LEVEL IHAR_PROFILE_GATEWAY IHAR_PROFILE_NETPOLICY
  export IHAR_PROFILE_MCP_STRICT _IHAR_CHECK_MASK_ENGINE _IHAR_CHECK_DROPPED_ENV
  export _IHAR_CHECK_GATEWAY_INSTANCES _IHAR_CHECK_ASSETS _IHAR_CHECK_KNOWN_GAPS
  export _IHAR_CHECK_CLAUDE_CAPABILITIES _IHAR_CHECK_CLAUDE_RECEIPT
  export _IHAR_CHECK_CLAUDE_HOOKS _IHAR_CHECK_CLAUDE_CONFORMANCE _IHAR_CHECK_MCP_CLAUDE
  export _IHAR_CHECK_CODEX_CAPABILITIES _IHAR_CHECK_CODEX_RECEIPT
  export _IHAR_CHECK_CODEX_HOOKS _IHAR_CHECK_CODEX_CONFORMANCE _IHAR_CHECK_MCP_CODEX
  ihar_python ihar.check_result collect "$target"
}

_ihar_check_active_runtime() { # <vendor>
  local vendor="$1" state runtime newest=""
  state="$(_ihar_project_state)"
  [[ -n "$state" ]] || return 0
  for runtime in "$state"/r/*/"$vendor"; do
    [[ -d "$runtime" ]] || continue
    if [[ -z "$newest" || "$runtime" -nt "$newest" ]]; then newest="$runtime"; fi
  done
  printf '%s\n' "$newest"
}

_ihar_check_file_matches() { # <desired> <active> <relative>
  local desired="$1" active="$2" relative="$3"
  if [[ "$relative" == config.toml ]]; then
    cmp -s <(_ihar_rtrim_blank < "$desired") \
      <(sed '/# ihar:hook-trust:start/,$d' "$active" | _ihar_rtrim_blank)
    return $?
  fi
  cmp -s -- "$desired" "$active"
}

# ihar_check_diff — compare temporary desired renders with active homes.
ihar_check_diff() (
  ihar_profile_resolve "$IHAR_FLAG_PROFILE"
  local temp state vendor desired active file relative found=false
  temp="$(mktemp -d "${TMPDIR:-/tmp}/ihar-check-diff-XXXXXX")" || return 1
  state="$(_ihar_project_state)"
  IHAR_STATE="$state"; export IHAR_STATE
  IHAR_GATEWAY_MODE="$IHAR_PROFILE_GATEWAY"; export IHAR_GATEWAY_MODE
  IHAR_GATEWAY_ACTIVE_PORT="${IHAR_GATEWAY_ACTIVE_PORT:-0}"; export IHAR_GATEWAY_ACTIVE_PORT
  for vendor in claude codex; do
    desired="$temp/$vendor"
    ihar_render_all "$vendor" "$desired"
    active="$(_ihar_check_active_runtime "$vendor")"
    while IFS= read -r -d '' file; do
      relative="${file#"$desired"/}"
      if [[ -z "$active" || ! -f "$active/$relative" ]]; then
        printf '%s %s missing from active runtime\n' "$vendor" "$relative"
        found=true
      elif ! _ihar_check_file_matches "$file" "$active/$relative" "$relative"; then
        printf '%s %s differs from active runtime\n' "$vendor" "$relative"
        found=true
      fi
    done < <(find "$desired" -type f -print0 | sort -z)
  done
  [[ "$found" == true ]] || printf 'no differences\n'
  rm -rf -- "$temp"
)

ihar_cmd_check() {
  if [[ "$IHAR_FLAG_CONFORMANCE" == true ]]; then
    if [[ "$IHAR_FLAG_JSON" == true ]]; then ihar_cmd_conformance >/dev/null; else ihar_cmd_conformance; fi
  fi
  if [[ "$IHAR_FLAG_DIFF" == true ]]; then ihar_check_diff; return $?; fi
  local result
  result="$(mktemp "${TMPDIR:-/tmp}/ihar-check-result-XXXXXX.json")" || return 1
  ihar_check_collect "$result"
  local status=0
  if [[ "$IHAR_FLAG_JSON" == true ]]; then
    ihar_python ihar.check_result json "$result" || status=$?
  else
    ihar_python ihar.check_result text "$result" || status=$?
  fi
  rm -f -- "$result"
  return "$status"
}
