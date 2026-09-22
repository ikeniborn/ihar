#!/usr/bin/env bash
# Commands and the launch lifecycle (LLD 3.3).
#
# The step order is not arbitrary. Four data dependencies fix it: the profile decides
# how severe a store mismatch is, the effective configuration decides which runtime
# home is used, the gateway port is an input to the render, and the rendered
# fragments are the content of the home. LLD revision 2 had steps consuming outputs
# produced after them, which is what this order corrects.

# ihar_uuid — UUIDv7: time-ordered, so session ids sort by creation (LLD 10.1).
ihar_uuid() {
  ihar_python ihar.ids
}

# ihar_cmd_launch <vendor>
ihar_cmd_launch() {
  local vendor="$1"

  # 1. the project and its configuration are resolved by the entry point, before the
  #    parser runs: IHAR_DEFAULT_AGENT is a configuration key the parser reads.

  # 2. profile, before anything reads its severity
  ihar_profile_resolve "$IHAR_FLAG_PROFILE"
  if [[ "${IHAR_ACP_MODE:-false}" == true && "${IHAR_PROFILE_ACP:-refuse}" != allow ]]; then
    ihar_die 2 "profile '$IHAR_PROFILE' refuses experimental ACP mode
claude-agent-acp #144: settings hooks may not fire
codex-acp #310/#477: sandbox and approval policy are overridden"
  fi
  if [[ "$IHAR_FLAG_WEB" == true ]]; then
    case " ${IHAR_PROFILE_REMOTE:-} " in
      *" $vendor "*) ;;
      *) ihar_die 2 "profile '$IHAR_PROFILE' does not allow ${vendor^} web" ;;
    esac
  fi
  # 3. store integrity, at the severity the profile asks for
  IHAR_VENDOR="$vendor"; export IHAR_VENDOR
  local native_binary
  case "$vendor" in
    claude) native_binary="$IHAR_CLAUDE_BIN" ;;
    codex)  native_binary="$IHAR_CODEX_BIN" ;;
  esac
  local verify_receipt=true
  if [[ "$IHAR_FLAG_DRY_RUN" == true ]]; then
    verify_receipt=false
  fi
  ihar_store_verify "$vendor" "$native_binary" "$verify_receipt"

  local auth_verb=""
  if [[ "$vendor" == codex ]]; then
    auth_verb="$(ihar_codex_auth_verb)" || auth_verb=""
    if [[ -n "$auth_verb" ]]; then
      ihar_codex_auth_command "$auth_verb"
      return $?
    fi
  fi

  # 4. project state. Called directly rather than in a command substitution: the
  # setup exports IHAR_STATE, and a subshell would drop that export while still
  # returning the path, so everything downstream would look right and be unset.
  local root state
  root="$IHAR_PROJECT_ROOT"
  ihar_state_setup "$root" >/dev/null
  state="$IHAR_STATE"

  if [[ "$IHAR_PROFILE_SANDBOX" == microvm ]]; then
    ihar_launch_state_enter isolated
  else
    ihar_launch_state_enter native
  fi

  # 5. enforcement points, before the render, because the gateway port is an input
  #    to the Codex provider region.
  case "${IHAR_PROFILE_GATEWAY:-off}" in
    off) ;;
    explicit)
      ihar_gateway_acquire
      # The last consumer of an instance stops it, so the launch must stay in the
      # foreground rather than exec: an exec would leave the refcount held forever.
      trap ihar_gateway_release EXIT INT TERM
      ;;
  esac

  if [[ "$IHAR_PROFILE_SANDBOX" == "microvm" ]]; then
    ihar_microvm_reserve_slot
    trap 'ihar_microvm_release_slot; ihar_gateway_release' EXIT INT TERM
  fi

  # 6. render. The hook block and the effective policy are produced here; the MCP
  #    registry and the managed config regions arrive with S6 and S7.
  local render hooks_digest registry_digest mcp_identity
  render="$(mktemp -d "${TMPDIR:-/tmp}/ihar-render-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$render'" RETURN
  hooks_digest="$(ihar_manifest_digest)"
  registry_digest="$(ihar_registry_digest)"
  mcp_identity="$(ihar_effective_mcp_identity "$vendor")" || return
  ihar_render_all "$vendor" "$render"

  # 7. runtime home, keyed by the configuration and never rewritten
  local version hash runtime
  version="$(ihar_vendor_version "$vendor")"
  hash="$(ihar_config_hash \
            "$IHAR_PROFILE" "$IHAR_PROFILE_MASKING_LEVEL" "$IHAR_PROFILE_GATEWAY" \
            "$IHAR_PROFILE_SANDBOX" "$IHAR_PROFILE_MCP_STRICT" \
            "$hooks_digest" "$registry_digest" "$version" "$mcp_identity")"
  local mode=writable
  if [[ "${IHAR_PROFILE_HOOKS:-best-effort}" == "enforced" ]]; then mode=immutable; fi
  ihar_runtime_materialise "$vendor" "$hash" "$render" "$mode" >/dev/null
  runtime="$IHAR_RUNTIME"
  if [[ "$vendor" == codex ]]; then
    ihar_python ihar.codex.guardian bind-runtime "$IHAR_GUARD_FD" "$runtime" "$hash" \
      || ihar_die 3 "Codex runtime guardian binding failed"
  fi

  if [[ "$IHAR_PROFILE_SANDBOX" == microvm ]]; then
    local other_vendor=claude other_render other_hash other_runtime other_mcp_identity
    [[ "$vendor" == claude ]] && other_vendor=codex
    other_mcp_identity="$(ihar_effective_mcp_identity "$other_vendor")" || return
    other_render="$(mktemp -d "${TMPDIR:-/tmp}/ihar-render-other-XXXXXX")"
    ihar_render_all "$other_vendor" "$other_render"
    other_hash="$(ihar_config_hash \
      "$IHAR_PROFILE" "$IHAR_PROFILE_MASKING_LEVEL" "$IHAR_PROFILE_GATEWAY" \
      "$IHAR_PROFILE_SANDBOX" "$IHAR_PROFILE_MCP_STRICT" \
      "$hooks_digest" "$registry_digest" "$(ihar_vendor_version "$other_vendor")" \
      "$other_mcp_identity")"
    ihar_runtime_materialise "$other_vendor" "$other_hash" "$other_render" "$mode" >/dev/null
    other_runtime="$IHAR_RUNTIME"
    ihar_verify_hook_trust "$other_vendor" "$other_runtime"
    IHAR_VENDOR="$other_vendor"; export IHAR_VENDOR
    ihar_store_verify_conformance true
    IHAR_VENDOR="$vendor"; export IHAR_VENDOR
    IHAR_OTHER_RUNTIME="$other_runtime"; export IHAR_OTHER_RUNTIME
    IHAR_RUNTIME="$runtime"; export IHAR_RUNTIME
    rm -rf "$other_render"
  fi

  # 7b. the hooks the profile depends on must be trusted by the vendor itself, not
  #     merely rendered by us (LLD 6.5).
  ihar_verify_hook_trust "$vendor" "$runtime"

  # 8. a daemon serving this home must be the one this configuration asked for. Codex
  #    hands every client the environment the daemon inherited at start, so a daemon
  #    left over from another profile would serve this launch under that profile.
  if [[ "$vendor" == codex && "$IHAR_PROFILE_SANDBOX" != microvm && "${IHAR_ACP_MODE:-false}" != true ]]; then
    ihar_codex_daemon_reconcile "$runtime" "$hash"
  fi

  # 8b. Create the control-plane identity before either vendor starts. The hook
  # claims it using its own payload session id, never the daemon's environment.
  if [[ "${IHAR_ACP_MODE:-false}" != true ]]; then
    # A console tab is minted by the broker so its record and the session index agree on
    # one id; the handoff and resume ids keep precedence over it (LLD 13.2).
    IHAR_LAUNCH_ID="${IHAR_HANDOFF_TARGET_ID:-${IHAR_RESUME_IHAR_ID:-${IHAR_CONSOLE_LAUNCH_ID:-$(ihar_uuid)}}}"; export IHAR_LAUNCH_ID
    ihar_handoff_prepare "$vendor"
  fi

  # 9. and 10. the adapter builds its argv and the environment it needs
  IHAR_VENDOR="$vendor"; export IHAR_VENDOR
  if [[ "${IHAR_ACP_MODE:-false}" == true ]]; then
    ihar_adapter "$vendor" env "$runtime"
    case "$vendor" in
      claude) IHAR_ARGV=("$IHAR_CLAUDE_ACP_BIN") ;;
      codex)  IHAR_ARGV=("$IHAR_CODEX_ACP_BIN") ;;
    esac
  else
    ihar_adapter "$vendor" launch "$runtime"
  fi
  local binary="${IHAR_ARGV[0]}"
  if [[ "${IHAR_ACP_MODE:-false}" == true && "$IHAR_FLAG_DRY_RUN" != true ]]; then
    ihar_store_verify_acp "$vendor"
  fi
  if [[ "$IHAR_FLAG_DRY_RUN" != true && ! -x "$binary" ]]; then
    if [[ "${IHAR_ACP_MODE:-false}" == true ]]; then
      ihar_die 1 "the $vendor ACP adapter is not installed at $binary"
    fi
    ihar_die 1 "the $vendor binary is not installed at $binary
run 'ihar install'"
  fi
  if [[ "$IHAR_FLAG_WEB" == true ]]; then
    ihar_adapter "$vendor" start_remote "$runtime" "$hash"
  fi
  ihar_env_map
  ihar_env_prepare "$vendor"

  if [[ "$IHAR_FLAG_DRY_RUN" == true ]]; then
    ihar_dry_run "$vendor" "$runtime"
    return 0
  fi

  if [[ "${IHAR_ACP_MODE:-false}" == true ]]; then
    ihar_env_apply
    if [[ "$vendor" == codex ]]; then ihar_codex_guard_drop; fi
    if (( ${#IHAR_ENV[@]} )); then
      exec env -i "${IHAR_ENV[@]}" "${IHAR_ARGV[@]}"
    fi
    exec "${IHAR_ARGV[@]}"
  fi

  ihar_session_claim "$vendor" "$hash"
  if [[ "$vendor" == claude && -z "$IHAR_FLAG_RESUME" ]]; then
    ihar_session_append_launch "$vendor" "$IHAR_LAUNCH_ID"
  fi
  ihar_handoff_consume_claude

  if [[ "$IHAR_PROFILE_SANDBOX" == "microvm" ]]; then
    ihar_microvm_launch "$vendor" "$runtime"
    return $?
  fi

  ihar_env_apply
  if [[ "$vendor" == codex ]]; then ihar_codex_guard_drop; fi
  if (( ${#IHAR_ENV[@]} )); then
    exec env -i "${IHAR_ENV[@]}" "${IHAR_ARGV[@]}"
  fi
  exec "${IHAR_ARGV[@]}"
}

# ihar_cmd_acp <vendor> — experimental presentation layer over a standard runtime.
ihar_cmd_acp() {
  local vendor="${IHAR_SUBCOMMAND:-}"
  [[ "$vendor" == claude || "$vendor" == codex ]] \
    || ihar_die 2 "ihar acp: expected claude or codex, got '${vendor:-nothing}'"
  (( ${#IHAR_ARGS[@]} == 0 && ${#IHAR_PASSTHROUGH[@]} == 0 )) \
    || ihar_die 2 "ihar acp accepts one vendor and no other positional arguments"
  IHAR_ACP_MODE=true
  ihar_cmd_launch "$vendor"
}

# ihar_cmd_web <vendor> — command spelling for the same launch path as --web.
ihar_cmd_web() {
  local vendor="${IHAR_SUBCOMMAND:-}"
  [[ "$vendor" == claude || "$vendor" == codex ]] \
    || ihar_die 2 "ihar web: expected claude or codex, got '${vendor:-nothing}'"
  (( ${#IHAR_ARGS[@]} == 0 )) \
    || ihar_die 2 "ihar web accepts one vendor and no other positional arguments"
  IHAR_FLAG_WEB=true
  ihar_cmd_launch "$vendor"
}

# ihar_vendor_version <vendor> — the pinned version, from the lockfile. Part of the
# configuration hash, so a vendor upgrade produces a new runtime home rather than
# reusing one rendered for the previous version.
ihar_vendor_version() {
  local pinned
  case "$1" in
    claude) pinned="$(ihar_lockfile_get claude.version)" ;;
    codex)  pinned="$(ihar_lockfile_get codex.version)" ;;
  esac
  printf '%s\n' "${pinned:-unpinned}"
}

# ihar_dry_run <vendor> <runtime> — the resolved command and environment, launching
# nothing. This is what the adapter tests assert against, so no vendor binary has to
# be installed to prove the argv is right.
ihar_dry_run() {
  local vendor="$1" runtime="$2"
  ihar_python ihar.dryrun "$vendor" "$IHAR_PROFILE" "$runtime" \
    "${#IHAR_ENV[@]}" "${IHAR_ENV_DROPPED[*]:-}" -- "${IHAR_ARGV[@]}"
}

# ihar_cmd_conformance — run the live suite and record the result (LLD 6.6).
ihar_conformance_revoke_vendor() { # <vendor>
  local vendor="$1" directory="$IHAR_STORE/verification" record name
  local -a records=()
  case "$vendor" in claude|codex) ;; *) return 3 ;; esac
  [[ -e "$directory" || -L "$directory" ]] || return 0
  [[ -d "$directory" && ! -L "$directory" && -r "$directory" && -x "$directory" ]] || return 3
  for record in "$directory/$vendor-"*.json; do
    [[ -e "$record" || -L "$record" ]] || continue
    name="${record##*/}"
    [[ "$name" =~ ^${vendor}-[A-Za-z0-9._-]+\.json$ && -f "$record" && ! -L "$record" ]] || return 3
    records+=("$record")
  done
  for record in "${records[@]}"; do
    rm -f -- "$record" || return 3
  done
}

ihar_cmd_conformance() {
  local vendor binary status=0 run_status directory="$IHAR_STORE/verification" marker
  for vendor in claude codex; do
    binary="$(eval echo "\$IHAR_${vendor^^}_BIN")"
    [[ -x "$binary" ]] || continue
    marker="$directory/.recheck-$vendor"
    if [[ ! -e "$directory" && ! -L "$directory" ]]; then
      mkdir -- "$directory" || {
        ihar_warn "cannot begin conformance recheck for $vendor"
        status=3
        continue
      }
    fi
    if [[ ! -d "$directory" || -L "$directory" ]]; then
      ihar_warn "cannot begin conformance recheck for $vendor"
      status=3
      continue
    fi
    if [[ -e "$marker" || -L "$marker" ]]; then
      if [[ ! -d "$marker" || -L "$marker" ]]; then
        ihar_warn "cannot begin conformance recheck for $vendor"
        status=3
        continue
      fi
    elif ! mkdir -- "$marker"; then
      ihar_warn "cannot begin conformance recheck for $vendor"
      status=3
      continue
    fi
    if ! ihar_conformance_revoke_vendor "$vendor"; then
      ihar_warn "cannot revoke conformance proof for $vendor"
      status=3
      continue
    fi
    printf '\n%s conformance\n' "$vendor"
    if ihar_python ihar.conformance.run "$vendor" "$binary" "$IHAR_STORE" \
      "$IHAR_ROOT/manifests/hooks.json" \
      --auth-store "$IHAR_STORE" --lockfile "$IHAR_LOCKFILE"; then
      rmdir -- "$marker" || {
        ihar_warn "cannot complete conformance recheck for $vendor"
        status=3
      }
    else
      run_status=$?
      if [[ "$run_status" == 3 || "$status" == 0 ]]; then status="$run_status"; fi
    fi
  done
  return "$status"
}

# ihar_cmd_homes <subcommand>
ihar_cmd_homes() {
  case "${IHAR_SUBCOMMAND:-list}" in
    list)  ihar_state_list ;;
    clean)
      (( ${#IHAR_ARGS[@]} <= 1 )) \
        || ihar_die 2 "ihar homes clean accepts at most one state id"
      local clean_state clean_id="${IHAR_ARGS[0]:-}"
      if [[ -n "$clean_id" ]]; then
        [[ "$clean_id" =~ ^[0-9a-f]{8}$ ]] \
          || ihar_die 2 "invalid state id '$clean_id'"
        clean_state="$IHAR_STATE_ROOT/$clean_id"
        [[ -d "$clean_state" && -f "$clean_state/home.json" ]] \
          || ihar_die 2 "unknown state id '$clean_id'"
        local marker_root
        marker_root="$(ihar_python ihar.state_marker --validate-root "$clean_state/home.json" 2>/dev/null)" \
          || ihar_die 2 "state id '$clean_id' has an invalid marker"
        [[ "$(ihar_home_id "$marker_root")" == "$clean_id" ]] \
          || ihar_die 2 "state id '$clean_id' does not own marker project '$marker_root'"
      else
        clean_state="$IHAR_STATE_ROOT/$(ihar_home_id "$IHAR_PROJECT_ROOT")"
        if [[ ! -d "$clean_state" ]]; then printf '0\n'; return 0; fi
        [[ -f "$clean_state/home.json" ]] \
          || ihar_die 2 "current state has no valid marker"
        local marker_root
        marker_root="$(ihar_python ihar.state_marker --validate-root "$clean_state/home.json" 2>/dev/null)" \
          || ihar_die 2 "current state has an invalid marker"
        [[ "$marker_root" == "$IHAR_PROJECT_ROOT" ]] \
          || ihar_die 2 "current state marker belongs to '$marker_root', not '$IHAR_PROJECT_ROOT'"
      fi
      ihar_state_clean_runtimes 30 "$clean_state"
      ;;
    migrate)
      (( ${#IHAR_ARGS[@]} == 0 )) \
        || ihar_die 2 "ihar homes migrate accepts no positional arguments"
      ihar_state_setup "$IHAR_PROJECT_ROOT" >/dev/null
      ihar_with_lock --required "$IHAR_STATE/.ihar.lock" 30 \
        _ihar_homes_migrate_locked "$IHAR_STATE" "$IHAR_PROJECT_ROOT"
      ;;
    *)     ihar_die 2 "unknown homes subcommand '$IHAR_SUBCOMMAND'; known are list, clean, migrate" ;;
  esac
}

_ihar_homes_migrate_locked() {
  local state="$1" root="$2" vendor source status=0
  ihar_migration_acquire_locks "$root" || return $?
  if ! ihar_migration_require_quiescent "$root"; then
    ihar_migration_release_locks
    return 1
  fi
  for vendor in claude codex; do
    if ! source="$(ihar_migrate_vendor "$vendor" "$state" "$root" | tail -1)"; then
      ihar_warn "$vendor legacy state was not migrated"
      status=1
      continue
    fi
    [[ -n "$source" ]] || continue
    if ! ihar_python ihar.state_marker --record-migration \
      "$state/home.json" "$vendor" "$source"; then
      _ihar_homes_migration_rollback "$state" "$vendor" \
        || ihar_die 1 "cannot roll back the unrecorded $vendor migration"
      ihar_warn "cannot record the $vendor migration; copied state was rolled back"
      status=1
      continue
    fi
    printf '%s migrated from %s\n' "$vendor" "$source"
  done
  ihar_migration_release_locks
  return "$status"
}

_ihar_homes_migration_rollback() {
  local state="$1" vendor="$2"
  local target="$state/st/$vendor" rollback="$state/st/.${vendor}-rollback-$$"
  mv "$target" "$rollback" || return 1
  mkdir -p "$target" || { mv "$rollback" "$target"; return 1; }
  rm -rf "$rollback"
}
