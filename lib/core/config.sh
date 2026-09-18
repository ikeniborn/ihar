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

# Harness-internal names, never exported to a vendor (LLD 1.3).
_IHAR_ENV_DENY=(
  IHAR_ROOT IHAR_STORE IHAR_STATE_ROOT IHAR_NVM IHAR_PY IHAR_LOCKFILE
  IHAR_CLAUDE_BIN IHAR_CODEX_BIN IHAR_SOCKET_PATH_MAX IHAR_FLOCK_BIN
  IHAR_PASSTHROUGH IHAR_ARGV IHAR_ENV
  IHAR_GATEWAY_ANTHROPIC_UPSTREAM IHAR_GATEWAY_OPENAI_UPSTREAM IHAR_GATEWAY_CHATGPT_UPSTREAM
  CHROME_DESKTOP
)

# Kept under an enforced profile even though nothing lists them: without these a
# shell is not usable, and an agent that cannot run a tool is not safer, just broken.
_IHAR_ENV_BASE=(HOME PATH TERM LANG LC_ALL SHELL USER LOGNAME TMPDIR)

# ihar_env_prepare <vendor> — build IHAR_ENV, the environment the child receives.
#
# Under `standard` the child inherits the shell minus the denylist: developer
# convenience, and the profile promises nothing. Under an enforced profile the model
# inverts to an allowlist, because a developer shell routinely carries AWS_*,
# GITHUB_TOKEN, DATABASE_URL and *_PASSWORD, and an agent that can read its own
# environment can exfiltrate them through any channel the profile does not close.
ihar_env_prepare() {
  local vendor="$1" name value keep
  # Declared unconditionally: a caller reading ${#IHAR_ENV[@]} under `set -u` must
  # find an array in both branches, empty meaning "inherit the shell". Not exported,
  # because bash cannot export an array and the child is handed these through
  # `env -i` instead.
  IHAR_ENV=()
  IHAR_ENV_DROPPED=()

  if [[ "${IHAR_PROFILE_HOOKS:-best-effort}" != "enforced" ]]; then
    # Compute only. The harness still needs IHAR_ROOT and the rest to render a dry
    # run and to report, so the names are dropped by ihar_env_apply immediately
    # before the exec rather than here.
    for name in "${_IHAR_ENV_DENY[@]}"; do
      if [[ "${!name+set}" == set ]]; then IHAR_ENV_DROPPED+=("$name"); fi
    done
    # An inherited base URL would silently shadow whatever the profile decides about
    # model egress, so it is dropped whenever the profile owns a gateway.
    if [[ "${IHAR_PROFILE_GATEWAY:-off}" != "off" ]]; then
      IHAR_ENV_DROPPED+=(ANTHROPIC_BASE_URL OPENAI_BASE_URL)
    fi
    return 0
  fi

  local -a allowed=("${_IHAR_ENV_BASE[@]}" "${_IHAR_NATIVE_LIST[@]}")
  # Vendor-facing names the adapter set for this launch.
  case "$vendor" in
    claude) allowed+=(CLAUDE_CONFIG_DIR CLAUDE_CODE_EXECUTABLE ANTHROPIC_BASE_URL NODE_EXTRA_CA_CERTS) ;;
    codex)  allowed+=(CODEX_HOME CODEX_PATH SSL_CERT_FILE) ;;
  esac
  read -r -a keep <<< "${IHAR_PROFILE_ENV_PASSTHROUGH:-}"
  allowed+=("${keep[@]}")

  local -A wanted=()
  for name in "${allowed[@]}"; do [[ -n "$name" ]] && wanted["$name"]=1; done

  for name in $(compgen -e); do
    if [[ -n "${wanted[$name]:-}" ]]; then
      value="${!name}"
      IHAR_ENV+=("$name=$value")
    else
      IHAR_ENV_DROPPED+=("$name")
    fi
  done
}

# ihar_env_apply — drop what ihar_env_prepare marked. Called immediately before the
# exec, because everything on the list is something the harness itself still needs
# right up to that point.
ihar_env_apply() {
  local name
  if (( ${#IHAR_ENV[@]} )); then return 0; fi   # allowlist mode hands over via env -i
  for name in "${IHAR_ENV_DROPPED[@]:-}"; do
    if [[ -n "$name" ]]; then unset -v "$name" 2>/dev/null || true; fi
  done
}

# ihar_env_map — export every IHAR_* variable the vendor should see. Names on the
# native list go verbatim; the rest are exported de-prefixed, so IHAR_PROXY_URL
# becomes PROXY_URL for the modules that expect it.
ihar_env_map() {
  local name native bare denied
  for name in $(compgen -v | grep '^IHAR_' || true); do
    # Harness-internal names are not configuration and must not reach the child. Two
    # of them are arrays, where ${!name} silently yields element zero, so a sweep
    # that did not skip them would export a fragment of the argv as ARGV=.
    denied=false
    for bare in "${_IHAR_ENV_DENY[@]}"; do
      if [[ "$name" == "$bare" ]]; then denied=true; break; fi
    done
    if [[ "$denied" == true ]]; then continue; fi
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
