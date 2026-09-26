#!/usr/bin/env bash
# One shared Codex credential writer for native, ACP, and managed daemon paths.

# Exact account verbs are selected before ordinary runtime materialization.
ihar_codex_auth_verb() {
  [[ -n "${IHAR_CODEX_AUTH_VERB:-}" ]] || return 1
  if (( ${#IHAR_PASSTHROUGH[@]} == 1 )); then
    case "${IHAR_PASSTHROUGH[0]}" in
      login|logout) printf '%s\n' "${IHAR_PASSTHROUGH[0]}"; return 0 ;;
    esac
  elif (( ${#IHAR_PASSTHROUGH[@]} == 2 )) &&
       [[ "${IHAR_PASSTHROUGH[0]}" == login && "${IHAR_PASSTHROUGH[1]}" == status ]]; then
    printf 'status\n'
    return 0
  fi
  return 1
}

ihar_codex_auth_command() {
  local verb="$1"
  [[ "$IHAR_FLAG_DRY_RUN" != true ]] || ihar_die 2 "Codex $verb cannot be dry-run"
  [[ -x "$IHAR_CODEX_BIN" ]] || ihar_die 1 "the codex binary is not installed"
  ihar_python ihar.codex.guardian auth "$IHAR_GUARD_FD" -- \
    "$IHAR_CODEX_BIN" "${IHAR_PASSTHROUGH[@]}"
}

# ihar_codex_guard_drop — prevent a vendor child from inheriting the control channel.
ihar_codex_guard_drop() {
  exec {IHAR_GUARD_FD}>&-
  unset IHAR_GUARD_FD
}

ihar_codex_guest_owner() { # <guest-action> <action-arguments...>
  local action="$1"
  shift
  [[ -n "${IHAR_GUARD_FD:-}" ]] \
    || ihar_die 3 "Codex guest guardian channel is unavailable"
  ihar_python ihar.codex.guardian "guest-$action" "$IHAR_GUARD_FD" "$@"
}
