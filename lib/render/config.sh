#!/usr/bin/env bash
# Managed configuration regions and the sandbox (LLD 4.4, 8.7, 9.1).
#
# Failure class: fail-closed. A region that cannot be produced aborts the launch.

# ihar_render_config <vendor> <render-dir> — the mode, provider and sandbox settings.
ihar_render_config() {
  local vendor="$1" render="$2"
  case "$vendor" in
    claude) _ihar_render_claude_config "$render" ;;
    codex)  _ihar_render_codex_config "$render" ;;
  esac
}

# --------------------------------------------------------------------------- #
# Claude
# --------------------------------------------------------------------------- #

_ihar_render_claude_config() {
  local render="$1" sandbox_json="null" base_url=""

  case "$IHAR_PROFILE_SANDBOX" in
    vendor-default) sandbox_json="null" ;;
    read-only)      sandbox_json='{"enabled": true, "filesystem": "read-only"}' ;;
    vendor|microvm) sandbox_json='{"enabled": true, "filesystem": "workspace-write"}' ;;
  esac

  if [[ "${IHAR_GATEWAY_MODE:-off}" == "explicit" ]]; then
    local gateway_host=127.0.0.1
    [[ "$IHAR_PROFILE_SANDBOX" == microvm ]] && gateway_host="${IHAR_MICROVM_HOST_IP:-172.31.0.1}"
    base_url="http://${gateway_host}:${IHAR_GATEWAY_ACTIVE_PORT}"
  fi

  ihar_python ihar.render.claude_settings \
    "$render/settings.json" "$sandbox_json" "$base_url" \
    || ihar_die 3 "cannot render the Claude managed settings"
}

# --------------------------------------------------------------------------- #
# Codex
# --------------------------------------------------------------------------- #

# The mode region. `vendor-default` writes nothing at all: HLD section 8 calls the
# sandbox optional for `standard`, and rendering a region there would write
# danger-full-access and, following icodex's default triple, drop
# default_permissions — which icodex itself warns disables managed rules. Writing
# nothing is what "optional" means.
_ihar_render_codex_config() {
  # Two statements, not one. `local a="$1" b="$a"` declares every name before it
  # performs the assignments, so the second reads an unset variable and `set -u`
  # aborts — which is how this arrived as "render: unbound variable" on a line that
  # plainly assigns it.
  local render="$1"
  local config="$render/.config-head"
  local tables="$render/.config-tables"
  : > "$config"
  touch "$tables"

  if [[ "$IHAR_PROFILE_SANDBOX" != "vendor-default" ]]; then
    local mode permissions approval="on-request"
    case "$IHAR_PROFILE_SANDBOX" in
      read-only)      mode="read-only";       permissions="dev-safe" ;;
      vendor|microvm) mode="workspace-write"; permissions="dev-safe" ;;
    esac
    [[ -n "${IHAR_FLAG_APPROVAL:-}" ]] && approval="$IHAR_FLAG_APPROVAL"

    {
      printf '# ihar:mode:start\n'
      printf 'sandbox_mode = "%s"\n' "$mode"
      printf 'approval_policy = "%s"\n' "$approval"
      # Never omitted for a rendered mode: icodex warns that dropping it disables
      # managed filesystem and network rules (lib/config/sandbox.sh:112-114).
      printf 'default_permissions = "%s"\n' "$permissions"
      printf '# ihar:mode:end\n'
    } >> "$config"

    # Git must stay writable or the agent cannot commit its own work. A table, so it
    # belongs after every bare key.
    {
      printf '# ihar:git:start\n'
      printf '[permissions.%s.filesystem.":workspace_roots"]\n' "$permissions"
      printf '".git/" = "write"\n'
      printf '# ihar:git:end\n'
    } >> "$tables"
  fi

  if [[ "${IHAR_GATEWAY_MODE:-off}" == "explicit" ]]; then
    local prefix gateway_host=127.0.0.1
    prefix="$(ihar_codex_auth_prefix)"
    [[ "$IHAR_PROFILE_SANDBOX" == microvm ]] && gateway_host="${IHAR_MICROVM_HOST_IP:-172.31.0.1}"
    # The selector is a bare key and the provider itself is a table, so the two go to
    # different fragments even though they are one decision.
    {
      printf '# ihar:provider:start\n'
      printf 'model_provider = "ihar"\n'
      printf '# ihar:provider:end\n'
    } >> "$config"
    {
      printf '# ihar:provider-table:start\n'
      printf '[model_providers.ihar]\n'
      printf 'name = "ihar gateway"\n'
      printf 'base_url = "http://%s:%s/%s"\n' "$gateway_host" "$IHAR_GATEWAY_ACTIVE_PORT" "$prefix"
      printf 'wire_api = "responses"\n'
      # Keeps ChatGPT OAuth working through a custom base URL; without it Codex
      # would demand an API key and a subscription user could not launch at all.
      printf 'requires_openai_auth = true\n'
      printf '# ihar:provider-table:end\n'
    } >> "$tables"
  fi

  {
    printf '# ihar:projects:start\n'
    printf '[projects."%s"]\n' "$IHAR_PROJECT_ROOT"
    printf 'trust_level = "trusted"\n'
    printf '# ihar:projects:end\n'
  } >> "$tables"
}

# ihar_render_config_assemble <render-dir> — join the fragments in the only order
# TOML accepts: every bare key, then every table.
#
# Assembled rather than appended in place, because three renderers produce regions in
# whatever order suits them and TOML cares about an order none of them knows. Getting
# this wrong made `sandbox_mode` a member of whichever table happened to precede it,
# and Codex then failed to parse the file at all and reported no hooks.
ihar_render_config_assemble() {
  local render="$1"
  local config="$render/config.toml"
  [[ -f "$render/.config-head" || -f "$render/.config-tables" ]] || return 0
  cat "$render/.config-head" "$render/.config-tables" > "$config" 2>/dev/null
  rm -f "$render/.config-head" "$render/.config-tables"
}

# ihar_codex_auth_prefix — the path segment the gateway route expects for the auth
# mode in use. The file is read, never written, and ihar holds no credential.
ihar_codex_auth_prefix() {
  local auth="$IHAR_STORE/auth/codex/auth.json"
  if [[ -f "$auth" ]] && grep -q 'OPENAI_API_KEY' "$auth" 2>/dev/null; then
    printf 'v1\n'
  else
    printf 'backend-api/codex\n'
  fi
}
