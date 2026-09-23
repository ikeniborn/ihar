#!/usr/bin/env bash
# ihar — a vendor-neutral control and security plane for native coding agents.
#
# Design: docs/hld/unified-harness.md, docs/lld/unified-harness.md.
# Rules: CLAUDE.md.

set -euo pipefail

# A launch that aborts under `set -e` reports only its exit code, which is the least
# useful thing it knows. IHAR_TRACE=1 turns on the shell trace so the failing step is
# visible without editing the script.
if [[ "${IHAR_TRACE:-}" == "1" ]]; then set -x; fi

_IHAR_ENTRY="${BASH_SOURCE[0]}"

source "$(dirname "$(readlink -f "$_IHAR_ENTRY")")/lib/core/logging.sh"
_IHAR_LIB="$(dirname "$(readlink -f "$_IHAR_ENTRY")")/lib"

source "$_IHAR_LIB/core/init.sh"
ihar_init "$_IHAR_ENTRY"

source "$_IHAR_LIB/core/lock.sh"
source "$_IHAR_LIB/core/config.sh"
source "$_IHAR_LIB/state/state.sh"
source "$_IHAR_LIB/state/links.sh"
source "$_IHAR_LIB/state/runtime.sh"
source "$_IHAR_LIB/state/migrate.sh"
source "$_IHAR_LIB/state/gc.sh"
source "$_IHAR_LIB/store/lockfile.sh"
source "$_IHAR_LIB/store/assets.sh"
source "$_IHAR_LIB/store/migrate.sh"
source "$_IHAR_LIB/store/install.sh"
source "$_IHAR_LIB/render/hooks.sh"
source "$_IHAR_LIB/render/config.sh"
source "$_IHAR_LIB/codex/daemon.sh"
source "$_IHAR_LIB/codex/auth.sh"
source "$_IHAR_LIB/sessions/sessions.sh"
source "$_IHAR_LIB/handoff/handoff.sh"
source "$_IHAR_LIB/console/console.sh"
source "$_IHAR_LIB/gateway/gateway.sh"
source "$_IHAR_LIB/sandbox/microvm.sh"
source "$_IHAR_LIB/profile/profile.sh"
source "$_IHAR_LIB/adapters/adapter.sh"
source "$_IHAR_LIB/adapters/claude.sh"
source "$_IHAR_LIB/adapters/codex.sh"
source "$_IHAR_LIB/cli/args.sh"
source "$_IHAR_LIB/cli/usage.sh"
source "$_IHAR_LIB/cli/check.sh"
source "$_IHAR_LIB/cli/commands.sh"

ihar_main() {
  # The project and its configuration come first: the parser reads
  # IHAR_DEFAULT_AGENT, and every command resolves its state under the roots the
  # project may override. Parsing before this made both work only from the ambient
  # environment, so a key set in a project file did nothing.
  IHAR_PROJECT_ROOT="$(ihar_project_root)"
  export IHAR_PROJECT_ROOT
  ihar_config_load

  ihar_args_parse "$@"
  ihar_guard_undelivered
  if [[ "$IHAR_COMMAND" == codex && "$IHAR_FLAG_WEB" == true &&
        -n "$IHAR_CODEX_AUTH_VERB" ]]; then
    ihar_die 2 "--web cannot be combined with Codex authentication passthrough"
  fi
  local needs_codex_guard=false joins_daemon_owner=false
  case "$IHAR_COMMAND:${IHAR_SUBCOMMAND:-}" in
    codex:*)
      needs_codex_guard=true
      [[ "$IHAR_FLAG_WEB" == true ]] && joins_daemon_owner=true
      ;;
    acp:codex) needs_codex_guard=true ;;
    web:codex)
      needs_codex_guard=true
      joins_daemon_owner=true
      ;;
    install:*|switch:*) needs_codex_guard=true ;;
    update:*)
      needs_codex_guard=true
      joins_daemon_owner=true
      ;;
    check:*)
      if [[ -x "$IHAR_CODEX_BIN" ]]; then
        needs_codex_guard=true
        IHAR_CHECK_CODEX_PROBES=true
      else
        # Keep this invocation metadata-only even if Codex appears after routing.
        IHAR_CHECK_CODEX_PROBES=false
      fi
      export IHAR_CHECK_CODEX_PROBES
      ;;
    claude:*|acp:claude|web:claude)
      # A microVM launch also renders, seals, and verifies the Codex runtime.
      ihar_profile_resolve "$IHAR_FLAG_PROFILE"
      [[ "$IHAR_PROFILE_SANDBOX" == microvm ]] && needs_codex_guard=true
      ;;
    sessions:*)
      if ihar_sessions_needs_codex_guard; then
        needs_codex_guard=true
      fi
      ;;
  esac
  if [[ "$needs_codex_guard" == true ]]; then
    [[ -z "${IHAR_CODEX_GUARD_FD:-}" ]] \
      || ihar_die 3 "Codex guardian admission cannot be verified"
    if [[ -n "${IHAR_GUARD_FD:-}" ]]; then
      ihar_python ihar.codex.guardian admit "$IHAR_GUARD_FD" \
        || ihar_die 3 "Codex guardian admission cannot be verified"
    else
      if [[ "$joins_daemon_owner" == true ]]; then
        local owner_status=0 owner_error="" joined_status=0
        owner_error="$(ihar_python ihar.codex.guardian owner-present "$IHAR_STORE" 2>&1)" \
          || owner_status=$?
        case "$owner_status" in
          0)
            ihar_python ihar.codex.guardian join "$IHAR_STORE" "$PWD" -- \
              "$(readlink -f "$_IHAR_ENTRY")" "$@" || joined_status=$?
            return "$joined_status"
            ;;
          1) ;;
          *) ihar_die 3 "Codex daemon guardian cannot be verified: ${owner_error:-no detail}" ;;
        esac
      fi
      ihar_python ihar.codex.guardian supervise "$IHAR_STORE" -- "$(readlink -f "$_IHAR_ENTRY")" "$@"
      return $?
    fi
  fi
  case "$IHAR_COMMAND" in
    help)         ihar_usage ;;
    claude|codex) ihar_cmd_launch "$IHAR_COMMAND" ;;
    acp)          ihar_cmd_acp ;;
    check)        ihar_cmd_check ;;
    install)      ihar_cmd_install ;;
    update)       ihar_cmd_update ;;
    daemon)       ihar_cmd_daemon ;;
    console)      ihar_cmd_console ;;
    sessions)     ihar_cmd_sessions ;;
    switch)       ihar_cmd_switch ;;
    web)          ihar_cmd_web ;;
    homes)        ihar_cmd_homes ;;
    *)            ihar_die 2 "unhandled command '$IHAR_COMMAND'" ;;
  esac
}

ihar_main "$@"
