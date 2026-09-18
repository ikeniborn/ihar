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

  # 3. store integrity, at the severity the profile asks for
  ihar_store_verify

  # 4. project state. Called directly rather than in a command substitution: the
  # setup exports IHAR_STATE, and a subshell would drop that export while still
  # returning the path, so everything downstream would look right and be unset.
  local root state
  root="$IHAR_PROJECT_ROOT"
  ihar_state_setup "$root" >/dev/null
  state="$IHAR_STATE"

  # 4b. seed vendor state from a legacy wrapper home, once
  ihar_migrate_vendor "$vendor" "$state" "$root" >/dev/null || true

  # 5. enforcement points. Slice S7 starts the gateway and the sandbox here; until
  #    then a profile that requires one cannot be honoured, so it is refused rather
  #    than launched with the enforcement silently absent.
  if [[ "${IHAR_PROFILE_GATEWAY:-off}" != "off" ]]; then
    ihar_die 3 "profile '$IHAR_PROFILE' requires a '$IHAR_PROFILE_GATEWAY' model egress gateway, which slice S7 delivers
use --profile standard until then"
  fi

  # 6. render. The hook block and the effective policy are produced here; the MCP
  #    registry and the managed config regions arrive with S6 and S7.
  local render hooks_digest registry_digest
  render="$(mktemp -d "${TMPDIR:-/tmp}/ihar-render-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$render'" RETURN
  hooks_digest="$(ihar_manifest_digest)"
  registry_digest="none"
  ihar_render_all "$vendor" "$render"

  # 7. runtime home, keyed by the configuration and never rewritten
  local version hash runtime
  version="$(ihar_vendor_version "$vendor")"
  hash="$(ihar_config_hash \
            "$IHAR_PROFILE" "$IHAR_PROFILE_MASKING_LEVEL" "$IHAR_PROFILE_GATEWAY" \
            "$IHAR_PROFILE_SANDBOX" "$IHAR_PROFILE_MCP_STRICT" \
            "$hooks_digest" "$registry_digest" "$version")"
  local mode=writable
  if [[ "${IHAR_PROFILE_HOOKS:-best-effort}" == "enforced" ]]; then mode=immutable; fi
  ihar_runtime_materialise "$vendor" "$hash" "$render" "$mode" >/dev/null
  runtime="$IHAR_RUNTIME"

  # 7b. the hooks the profile depends on must be trusted by the vendor itself, not
  #     merely rendered by us (LLD 6.5).
  ihar_verify_hook_trust "$vendor" "$runtime"

  # 8. session index: slice S9.

  # 9. and 10. the adapter builds its argv and the environment it needs
  IHAR_VENDOR="$vendor"; export IHAR_VENDOR
  IHAR_LAUNCH_ID="$(ihar_uuid)"; export IHAR_LAUNCH_ID
  ihar_adapter "$vendor" launch "$runtime"
  ihar_env_map
  ihar_env_prepare "$vendor"

  if [[ "$IHAR_FLAG_DRY_RUN" == true ]]; then
    ihar_dry_run "$vendor" "$runtime"
    return 0
  fi

  local binary="${IHAR_ARGV[0]}"
  [[ -x "$binary" ]] || ihar_die 1 "the $vendor binary is not installed at $binary
run 'ihar install'"

  ihar_env_apply
  if (( ${#IHAR_ENV[@]} )); then
    exec env -i "${IHAR_ENV[@]}" "${IHAR_ARGV[@]}"
  fi
  exec "${IHAR_ARGV[@]}"
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

# ihar_cmd_check — what is in force right now (LLD 12.4). Grows with every slice.
ihar_cmd_check() {
  ihar_profile_resolve "$IHAR_FLAG_PROFILE"
  printf 'profile      %s\n' "$IHAR_PROFILE"
  printf 'guarantee    %s\n' "$IHAR_PROFILE_GUARANTEE"
  printf 'hooks        %s\n' "$IHAR_PROFILE_HOOKS"
  printf 'gateway      %s%s\n' "$IHAR_PROFILE_GATEWAY" \
    "$([[ "$IHAR_PROFILE_GATEWAY" != off ]] && printf ' (unavailable until slice S7)')"
  printf 'masking      %s\n' "$IHAR_PROFILE_MASKING_LEVEL"
  printf 'sandbox      %s%s\n' "$IHAR_PROFILE_SANDBOX" \
    "$([[ "$IHAR_PROFILE_SANDBOX" != vendor-default ]] && printf ' (unavailable until slice S7)')"
  printf 'store        %s\n' "$IHAR_STORE"
  printf 'state root   %s\n' "$IHAR_STATE_ROOT"
  printf 'lockfile     %s\n' "$([[ -f "$IHAR_LOCKFILE" ]] && echo present || echo absent)"

  local vendor binary version record
  for vendor in claude codex; do
    binary="$(eval echo "\$IHAR_${vendor^^}_BIN")"
    if [[ ! -x "$binary" ]]; then
      printf '%-12s not installed\n' "$vendor"
      continue
    fi
    version="$("$binary" --version 2>/dev/null | head -1)"
    record="$IHAR_STORE/verification/$vendor-$(ihar_version_slug "$binary").json"
    if [[ -f "$record" ]]; then
      if ihar_python ihar.conformance.check "$record" "$binary" \
           "$IHAR_ROOT/manifests/hooks.json" >/dev/null 2>&1; then
        printf '%-12s %s, hook enforcement proven\n' "$vendor" "$version"
      else
        printf '%-12s %s, conformance record is stale\n' "$vendor" "$version"
      fi
    else
      printf '%-12s %s, hook enforcement unproven\n' "$vendor" "$version"
    fi
  done

  if [[ "${IHAR_SUBCOMMAND:-}" == "--conformance" || "${IHAR_FLAG_CONFORMANCE:-false}" == true ]]; then
    ihar_cmd_conformance
  fi
}

# ihar_cmd_conformance — run the live suite and record the result (LLD 6.6).
ihar_cmd_conformance() {
  local vendor binary status=0
  for vendor in claude codex; do
    binary="$(eval echo "\$IHAR_${vendor^^}_BIN")"
    [[ -x "$binary" ]] || continue
    printf '\n%s conformance\n' "$vendor"
    ihar_python ihar.conformance.run "$vendor" "$binary" "$IHAR_STORE" \
      "$IHAR_ROOT/manifests/hooks.json" || status=$?
  done
  return "$status"
}

# ihar_cmd_homes <subcommand>
ihar_cmd_homes() {
  case "${IHAR_SUBCOMMAND:-list}" in
    list)  ihar_state_list ;;
    clean) ihar_state_clean_orphans >/dev/null ;;
    *)     ihar_die 2 "unknown homes subcommand '$IHAR_SUBCOMMAND'; known are list, clean" ;;
  esac
}
