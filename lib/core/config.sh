#!/usr/bin/env bash
# Project configuration (LLD 2.6).
#
# The file is parsed, never sourced. iclaude sources its `.claude_config`, which
# executes whatever the file contains; `.ihar_config` sits in a checkout an agent can
# write, so sourcing it would hand an agent a shell.
#
# Failure class: usage (exit 2). An unknown key is a mistake worth stopping for: a
# typo in a security-relevant key would otherwise be silently ignored.

# Keys the file may set. `IHAR_IWIKI_*` is open-ended by design, since it forwards
# settings to an MCP server this harness does not model.
_IHAR_CONFIG_KEYS=(
  IHAR_PROFILE IHAR_DEFAULT_AGENT
  IHAR_GATEWAY_MASKING_LEVEL IHAR_GATEWAY_ENGINE
  IHAR_STORE IHAR_STATE_ROOT IHAR_SOCKET_PATH_MAX
  IHAR_PROXY_URL IHAR_PROXY_CA IHAR_PROXY_INSECURE
  IHAR_TELEMETRY IHAR_CHAT_LANG IHAR_DOC_LANG IHAR_DISTILLER
)

# Exported to the vendor verbatim (LLD 1.3). Everything else the file sets is
# exported de-prefixed, the iclaude env-map rule.
_IHAR_NATIVE_LIST=(
  IHAR_VENDOR IHAR_PROJECT_ROOT IHAR_STATE IHAR_RUNTIME IHAR_LAUNCH_ID IHAR_PROFILE
  IHAR_GATEWAY_ACTIVE IHAR_GATEWAY_MODE IHAR_GATEWAY_ACTIVE_PORT
  IHAR_GATEWAY_MASKING_LEVEL IHAR_SANDBOX_MODE
  IHAR_CHAT_LANG IHAR_DOC_LANG IHAR_ASSUME_YES
)

_ihar_config_key_known() {
  local key="$1" known
  [[ "$key" == IHAR_IWIKI_* ]] && return 0
  for known in "${_IHAR_CONFIG_KEYS[@]}"; do
    [[ "$key" == "$known" ]] && return 0
  done
  return 1
}

# ihar_config_load [file] — parse the file and export what it sets. Values already
# in the environment win, so the precedence is defaults < file < flags only because
# the caller applies flags after this.
ihar_config_load() {
  local file="${1:-$IHAR_ROOT/.ihar_config}"
  [[ -f "$file" ]] || return 0

  local line number=0 key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    number=$((number + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" != *=* ]]; then
      ihar_die 2 "$file:$number: not a KEY=value line"
    fi

    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"

    if [[ ! "$key" =~ ^IHAR_[A-Z0-9_]+$ ]]; then
      ihar_die 2 "$file:$number: key '$key' is not an IHAR_* name"
    fi
    if ! _ihar_config_key_known "$key"; then
      ihar_die 2 "$file:$number: unknown key '$key'"
    fi

    # Strip one layer of surrounding quotes; the value is data, never evaluated.
    if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
      value="${value:1:${#value}-2}"
    fi

    printf -v "$key" '%s' "$value"
    export "${key?}"
  done < "$file"
}

# ihar_env_map — export every IHAR_* variable the vendor should see. Names on the
# native list go verbatim; the rest are exported de-prefixed, so IHAR_PROXY_URL
# becomes PROXY_URL for the modules that expect it.
ihar_env_map() {
  local name native bare
  for name in $(compgen -v | grep '^IHAR_' || true); do
    [[ -n "${!name:-}" ]] || continue
    native=false
    for bare in "${_IHAR_NATIVE_LIST[@]}"; do
      [[ "$name" == "$bare" ]] && native=true && break
    done
    if [[ "$native" == true ]]; then
      export "${name?}"
    else
      bare="${name#IHAR_}"
      printf -v "$bare" '%s' "${!name}"
      export "${bare?}"
    fi
  done
}
