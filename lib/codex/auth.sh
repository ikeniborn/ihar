#!/usr/bin/env bash
# One shared Codex credential writer for native, ACP, and managed daemon paths.

# Exact account verbs are selected before ordinary runtime materialization.
ihar_codex_auth_verb() {
  [[ -n "${IHAR_CODEX_AUTH_VERB:-}" ]] || return 1
  printf '%s\n' "$IHAR_CODEX_AUTH_VERB"
}

ihar_codex_auth_command() {
  local verb="$1"
  [[ "$IHAR_FLAG_DRY_RUN" != true ]] || ihar_die 2 "Codex $verb cannot be dry-run"
  [[ -x "$IHAR_CODEX_BIN" ]] || ihar_die 1 "the codex binary is not installed"
  ihar_python ihar.codex.auth_owner auth "$IHAR_STORE" "$IHAR_PROJECT_ROOT" -- \
    "$IHAR_CODEX_BIN" "${IHAR_PASSTHROUGH[@]}"
}

ihar_codex_auth_run() { # <store> <harness-root> <runtime> <hash> <mode> <vendor argv...>
  local store="$1" root="$2" runtime="$3" hash="$4" mode="$5"
  shift 5
  if (( ${#IHAR_ENV[@]} )); then
    env -i "${IHAR_ENV[@]}" PYTHONPATH="$root/lib/python" \
      "$(ihar_python_bin)" -m ihar.codex.auth_owner run \
      "$store" "$runtime" "$hash" "$mode" -- "$@"
  else
    PYTHONPATH="$root/lib/python" "$(ihar_python_bin)" -m ihar.codex.auth_owner \
      run "$store" "$runtime" "$hash" "$mode" -- "$@"
  fi
}

ihar_codex_guest_owner() { # <guest-action> <action-arguments...>
  local action="$1"
  shift
  ihar_python ihar.codex.auth_owner "guest-$action" "$IHAR_STORE" "$@"
}
