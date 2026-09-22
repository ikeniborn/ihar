#!/usr/bin/env bash
# Collect one validated status result, then render it without persistent writes.

ihar_check_receipt_status() { # <vendor> <binary>
  ihar_receipt_binary_status "$1" "$2"
}

ihar_check_conformance_status() { # <vendor> <binary>
  local vendor="$1" binary="$2" record
  if [[ "$vendor" == codex && "${IHAR_CHECK_CODEX_PROBES:-true}" != true ]]; then
    printf 'not-installed\n'
    return 0
  fi
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

_ihar_check_config_hash() { # <vendor>
  local vendor="$1" mcp_identity
  mcp_identity="$(ihar_effective_mcp_identity "$vendor")" || return
  ihar_config_hash \
    "$IHAR_PROFILE" "$IHAR_PROFILE_MASKING_LEVEL" "$IHAR_PROFILE_GATEWAY" \
    "$IHAR_PROFILE_SANDBOX" "$IHAR_PROFILE_MCP_STRICT" \
    "$(ihar_manifest_digest)" "$(ihar_registry_digest)" "$(ihar_vendor_version "$vendor")" \
    "$mcp_identity"
}

_ihar_check_runtime() { # <vendor> [state]
  local vendor="$1" state="${2:-$(_ihar_project_state)}" hash
  hash="$(_ihar_check_config_hash "$vendor")" || return
  printf '%s/r/%s/%s\n' "$state" "$hash" "$vendor"
}

# ihar_check_collect <target-json> — gather every fact exactly once.
ihar_check_collect() {
  local target="$1" vendor binary capabilities notes runtime
  ihar_profile_resolve "$IHAR_FLAG_PROFILE"
  IHAR_STATE="$(_ihar_project_state)"; export IHAR_STATE
  ihar_env_prepare claude

  _IHAR_CHECK_MASK_ENGINE="$(ihar_python ihar.mask.describe "$IHAR_GATEWAY_MASKING_LEVEL" 2>/dev/null || echo unknown)"
  _IHAR_CHECK_DROPPED_ENV="$(printf '%s\n' "${IHAR_ENV_DROPPED[@]:-}" | sed '/^$/d' | sort -u)"
  _IHAR_CHECK_GATEWAY_INSTANCES="$(ihar_gateway_status)" || return $?
  _IHAR_CHECK_ASSETS="$(ihar_asset_diagnostics)" || return $?
  _IHAR_CHECK_NETWORK_EVIDENCE="$(ihar_microvm_network_evidence)" || return $?
  # The console's chat tab shows these same lines, so a user reads one wording in the
  # terminal and in the window rather than two that have to be reconciled (LLD 13.3).
  _IHAR_CHECK_KNOWN_GAPS=$'claude-agent-acp #144: settings hooks may not fire\ncodex-acp #310/#477: sandbox and approval policy are overridden\nihar console: an ACP chat tab is offered no filesystem or terminal capability'

  for vendor in claude codex; do
    binary="$(eval echo "\$IHAR_${vendor^^}_BIN")"
    capabilities="$(ihar_adapter "$vendor" capabilities)" || return $?
    notes="$(ihar_python ihar.render.mcp "$vendor" "$IHAR_PROFILE" \
      "$IHAR_ROOT/manifests/mcp/registry.json" --report 2>&1)" || true
    printf -v "_IHAR_CHECK_${vendor^^}_CAPABILITIES" '%s' "$capabilities"
    printf -v "_IHAR_CHECK_${vendor^^}_RECEIPT" '%s' \
      "$(ihar_check_receipt_status "$vendor" "$binary")"
    printf -v "_IHAR_CHECK_${vendor^^}_CONFORMANCE" '%s' \
      "$(ihar_check_conformance_status "$vendor" "$binary")"
    runtime="$(_ihar_check_runtime "$vendor")" || return
    printf -v "_IHAR_CHECK_${vendor^^}_RUNTIME" '%s' "$runtime"
    printf -v "_IHAR_CHECK_${vendor^^}_BINARY" '%s' "$binary"
    printf -v "_IHAR_CHECK_MCP_${vendor^^}" '%s' "$notes"
  done

  export IHAR_PROFILE IHAR_PROFILE_GUARANTEE IHAR_PROFILE_MASKING_LEVEL
  export IHAR_GATEWAY_MASKING_LEVEL IHAR_PROFILE_GATEWAY IHAR_PROFILE_NETPOLICY
  export IHAR_PROFILE_SANDBOX
  export IHAR_PROFILE_MCP_STRICT _IHAR_CHECK_MASK_ENGINE _IHAR_CHECK_DROPPED_ENV
  export _IHAR_CHECK_GATEWAY_INSTANCES _IHAR_CHECK_ASSETS _IHAR_CHECK_NETWORK_EVIDENCE
  export _IHAR_CHECK_KNOWN_GAPS
  _IHAR_CHECK_MANIFEST="$IHAR_ROOT/manifests/hooks.json"; export _IHAR_CHECK_MANIFEST
  _IHAR_CHECK_NETPOLICY_DIR="$IHAR_ROOT/manifests/netpolicy"; export _IHAR_CHECK_NETPOLICY_DIR
  export _IHAR_CHECK_CLAUDE_CAPABILITIES _IHAR_CHECK_CLAUDE_RECEIPT
  export _IHAR_CHECK_CLAUDE_RUNTIME _IHAR_CHECK_CLAUDE_CONFORMANCE _IHAR_CHECK_MCP_CLAUDE
  export _IHAR_CHECK_CODEX_CAPABILITIES _IHAR_CHECK_CODEX_RECEIPT
  export _IHAR_CHECK_CODEX_RUNTIME _IHAR_CHECK_CODEX_BINARY
  export _IHAR_CHECK_CODEX_CONFORMANCE _IHAR_CHECK_MCP_CODEX
  ihar_python ihar.check_result collect "$target"
}

_ihar_check_file_matches() { # <desired> <active> <relative>
  local desired="$1" active="$2" relative="$3"
  if [[ "$relative" == config.toml ]]; then
    cmp -s <(_ihar_rtrim_blank < "$desired") \
      <(sed '/# ihar:hook-trust:start/,$d' "$active" | _ihar_rtrim_blank)
    return $?
  fi
  if [[ "$relative" == settings.json ]]; then
    ihar_python ihar.render.claude_compare "$desired" "$active"
    return $?
  fi
  cmp -s -- "$desired" "$active"
}

# ihar_check_diff — compare temporary desired renders with active homes.
ihar_check_diff() (
  ihar_profile_resolve "$IHAR_FLAG_PROFILE"
  local temp="" state vendor desired active file relative difference category found=false gateway_key port auth_diagnostic
  trap '[[ -z "$temp" ]] || rm -rf -- "$temp"' EXIT
  temp="$(mktemp -d "${TMPDIR:-/tmp}/ihar-check-diff-XXXXXX")" || return 1
  state="$(_ihar_project_state)"
  IHAR_STATE="$state"; export IHAR_STATE
  IHAR_GATEWAY_MODE="$IHAR_PROFILE_GATEWAY"; export IHAR_GATEWAY_MODE
  case "$IHAR_PROFILE_GATEWAY" in
    off) IHAR_GATEWAY_ACTIVE_PORT=0 ;;
    explicit)
      gateway_key="$(ihar_gateway_key)"
      port="$(cat "$IHAR_STATE_ROOT/gw/$gateway_key/port" 2>/dev/null || true)"
      [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) \
        || ihar_die 3 "gateway configuration $gateway_key has no valid recorded port"
      IHAR_GATEWAY_ACTIVE_PORT="$port"
      ;;
  esac
  export IHAR_GATEWAY_ACTIVE_PORT
  for vendor in claude codex; do
    desired="$temp/$vendor"
    ihar_render_all "$vendor" "$desired"
    active="$(_ihar_check_runtime "$vendor" "$state")" || return
    printf '%s selected runtime generation %s (effective-mcp-identity included)\n' \
      "$vendor" "$(basename "$(dirname "$active")")"
    if [[ "$vendor" == codex && -d "$active" ]]; then
      auth_diagnostic="$(ihar_python ihar.check_result auth-diff "$active" "$IHAR_STORE")" || return
      printf '%s\n' "$auth_diagnostic"
      [[ "$auth_diagnostic" == 'codex mutable-link: valid; auth-owner: no recorded owner' ]] || found=true
    fi
    while IFS= read -r -d '' file; do
      relative="${file#"$desired"/}"
      if [[ -z "$active" || ! -f "$active/$relative" ]]; then
        category=managed-setting-drift
        if [[ "$relative" == mcp/ihar.json ]]; then
          category=effective-mcp-identity
        elif [[ "$vendor" == codex && "$relative" == config.toml ]]; then
          category=rendered-config-missing
        fi
        printf '%s %s missing from selected runtime (%s)\n' "$vendor" "$relative" \
          "$category"
        found=true
      elif ! difference="$(_ihar_check_file_matches "$file" "$active/$relative" "$relative")"; then
        if [[ "$relative" == settings.json ]]; then
          printf '%s %s managed-setting-drift at %s\n' "$vendor" "$relative" "${difference:-root}"
        elif [[ "$vendor" == codex && "$relative" == config.toml ]]; then
          category="$(ihar_python ihar.check_result config-diff-category "$file" "$active/$relative")" || return
          printf '%s %s differs from selected runtime (%s)\n' "$vendor" "$relative" "$category"
        else
          printf '%s %s differs from selected runtime (%s)\n' "$vendor" "$relative" \
            "$([[ "$relative" == mcp/ihar.json ]] && printf effective-mcp-identity || printf managed-setting-drift)"
        fi
        found=true
      fi
    done < <(find "$desired" -type f -print0 | sort -z)
  done
  [[ "$found" == true ]] || printf 'no differences\n'
)

# ihar_cmd_acp_promotion — measure the console chat tab's promotion condition (LLD 13.3).
#
# Reports and records; it promotes nothing. Exit 1 while any condition is unmet or
# unmeasured, because the tab's experimental status is the safe answer either way.
ihar_cmd_acp_promotion() {
  local record="$IHAR_STORE/verification/acp-promotion.json"
  mkdir -p -- "$(dirname "$record")"
  IHAR_CLI="${IHAR_ENTRY:-$IHAR_ROOT/ihar.sh}" \
  IHAR_PROJECT_ROOT="$IHAR_PROJECT_ROOT" IHAR_STATE="${IHAR_STATE:-}" \
    ihar_python ihar.acp_promotion --manifest "$IHAR_ROOT/manifests/acp-promotion.json" \
      --record "$record" ${IHAR_FLAG_JSON:+$([[ "$IHAR_FLAG_JSON" == true ]] && printf -- --json)}
}

ihar_cmd_check() (
  local result="" conformance_status=0 status=0
  if [[ "$IHAR_FLAG_ACP_PROMOTION" == true ]]; then
    ihar_state_setup "$IHAR_PROJECT_ROOT" >/dev/null 2>&1 || true
    ihar_cmd_acp_promotion
    return $?
  fi
  trap '[[ -z "$result" ]] || rm -f -- "$result"' EXIT
  if [[ "$IHAR_FLAG_CONFORMANCE" == true ]]; then
    if [[ "$IHAR_FLAG_JSON" == true ]]; then
      ihar_cmd_conformance >&2 || conformance_status=$?
    else
      ihar_cmd_conformance || conformance_status=$?
    fi
  fi
  if [[ "$IHAR_FLAG_DIFF" == true ]]; then
    # An OR-list here would disable errexit inside the entire diff renderer.
    ihar_check_diff
    status=$?
    (( status == 0 )) || return "$status"
    return "$conformance_status"
  fi
  result="$(mktemp "${TMPDIR:-/tmp}/ihar-check-result-XXXXXX.json")" || return 1
  ihar_check_collect "$result" || return $?
  if [[ "$IHAR_FLAG_JSON" == true ]]; then
    ihar_python ihar.check_result json "$result" || status=$?
  else
    ihar_python ihar.check_result text "$result" || status=$?
  fi
  (( status == 0 )) || return "$status"
  return "$conformance_status"
)
