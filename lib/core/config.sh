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
  IHAR_HANDOFF_HISTORY IHAR_HANDOFF_TRANSCRIPT_BYTES
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
#
# The file belongs to the project being worked on, not to the harness checkout. An
# earlier draft defaulted to $IHAR_ROOT/.ihar_config, so a project pinning a strict
# profile silently ran `standard`: the one file whose whole purpose is to raise a
# project's floor was read from somewhere else entirely.
ihar_config_load() {
  local file="${1:-${IHAR_PROJECT_ROOT:-$PWD}/.ihar_config}"
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

# Exported names the child must not inherit, and which the harness no longer needs
# once it is about to exec.
#
# Only exported names belong here. An earlier draft also listed the launcher's own
# shell arrays, and `ihar_env_apply` then unset IHAR_ARGV immediately before
# `exec "${IHAR_ARGV[@]}"`, which under `set -u` expands to nothing: every launch
# became a bare `exec`, a no-op that returned 0 without starting the agent. Shell
# variables that were never exported cannot reach a child anyway, so unsetting them
# buys nothing and costs exactly that.
_IHAR_ENV_DENY=(
  IHAR_ROOT IHAR_STORE IHAR_STATE_ROOT IHAR_NVM IHAR_PY IHAR_LOCKFILE
  IHAR_CLAUDE_BIN IHAR_CODEX_BIN IHAR_CLAUDE_ACP_BIN IHAR_CODEX_ACP_BIN
  IHAR_SOCKET_PATH_MAX IHAR_FLOCK_BIN IHAR_TRACE
  IHAR_GATEWAY_ANTHROPIC_UPSTREAM IHAR_GATEWAY_OPENAI_UPSTREAM IHAR_GATEWAY_CHATGPT_UPSTREAM
  CHROME_DESKTOP
)

# Launcher state: shell variables, never exported, never unset before the exec that
# reads them. Named so the map below can refuse to sweep them.
_IHAR_INTERNAL=(
  IHAR_ARGV IHAR_ENV IHAR_ENV_DROPPED IHAR_PASSTHROUGH IHAR_ARGS
  IHAR_COMMAND IHAR_SUBCOMMAND
  IHAR_ACP_MODE
  IHAR_FLAG_PROFILE IHAR_FLAG_DRY_RUN IHAR_FLAG_JSON IHAR_FLAG_RESUME IHAR_FLAG_FORK
  IHAR_FLAG_NAME IHAR_FLAG_MODEL IHAR_FLAG_EFFORT IHAR_FLAG_APPROVAL
  IHAR_FLAG_MASK_LEVEL IHAR_FLAG_WEB IHAR_FLAG_PROMPT IHAR_FLAG_CONFORMANCE
  IHAR_FLAG_TO IHAR_FLAG_HISTORY
  IHAR_FLAG_ACP IHAR_FLAG_MICROVM
  IHAR_HANDOFF_TARGET_ID IHAR_HANDOFF_PENDING
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
    claude) allowed+=(CLAUDE_CONFIG_DIR CLAUDE_CODE_EXECUTABLE ANTHROPIC_BASE_URL) ;;
    codex)  allowed+=(CODEX_HOME CODEX_PATH) ;;
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
    if [[ -z "$name" ]]; then continue; fi
    # Never touch launcher state. `exec "${IHAR_ARGV[@]}"` runs one line after this,
    # and an unset array expands to nothing under `set -u`, turning the exec into a
    # silent no-op. Only exported names are dropped, which is all a child can see.
    if _ihar_name_in "$name" "${_IHAR_INTERNAL[@]}"; then continue; fi
    unset -v "$name" 2>/dev/null || true
  done
}

# ihar_env_map — export every IHAR_* variable the vendor should see. Names on the
# native list go verbatim; the rest are exported de-prefixed, so IHAR_PROXY_URL
# becomes PROXY_URL for the modules that expect it.
ihar_env_map() {
  local name bare

  # Native names go verbatim.
  for name in "${_IHAR_NATIVE_LIST[@]}"; do
    if [[ -n "${!name:-}" ]]; then export "${name?}"; fi
  done

  # Configuration keys go de-prefixed, so IHAR_PROXY_URL becomes PROXY_URL for the
  # modules that expect it.
  #
  # An explicit set, not a sweep over every IHAR_* variable. The sweep exported the
  # launcher's own parser state under generic names — COMMAND, TRACE, FLAG_MODEL —
  # which are names other tools in the agent's shell honour, and it read element zero
  # of any array it met. What reaches a vendor is now what the key table names, and
  # nothing else.
  for name in "${_IHAR_CONFIG_KEYS[@]}" $(compgen -v | grep '^IHAR_IWIKI_' || true); do
    if [[ -z "${!name:-}" ]]; then continue; fi
    if _ihar_name_in "$name" "${_IHAR_NATIVE_LIST[@]}"; then continue; fi
    if _ihar_name_in "$name" "${_IHAR_ENV_DENY[@]}"; then continue; fi
    bare="${name#IHAR_}"
    printf -v "$bare" '%s' "${!name}"
    export "${bare?}"
  done
}

_ihar_name_in() {
  local needle="$1"; shift
  local candidate
  for candidate in "$@"; do
    if [[ "$needle" == "$candidate" ]]; then return 0; fi
  done
  return 1
}
