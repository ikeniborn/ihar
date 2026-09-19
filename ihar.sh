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
source "$_IHAR_LIB/store/install.sh"
source "$_IHAR_LIB/render/hooks.sh"
source "$_IHAR_LIB/render/config.sh"
source "$_IHAR_LIB/codex/daemon.sh"
source "$_IHAR_LIB/sessions/sessions.sh"
source "$_IHAR_LIB/handoff/handoff.sh"
source "$_IHAR_LIB/gateway/gateway.sh"
source "$_IHAR_LIB/profile/profile.sh"
source "$_IHAR_LIB/adapters/adapter.sh"
source "$_IHAR_LIB/adapters/claude.sh"
source "$_IHAR_LIB/adapters/codex.sh"
source "$_IHAR_LIB/cli/args.sh"
source "$_IHAR_LIB/cli/usage.sh"
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
  case "$IHAR_COMMAND" in
    help)         ihar_usage ;;
    claude|codex) ihar_cmd_launch "$IHAR_COMMAND" ;;
    check)        ihar_cmd_check ;;
    install)      ihar_cmd_install ;;
    update)       ihar_cmd_update ;;
    daemon)       ihar_cmd_daemon ;;
    sessions)     ihar_cmd_sessions ;;
    switch)       ihar_cmd_switch ;;
    web)          ihar_cmd_web ;;
    homes)        ihar_cmd_homes ;;
    *)            ihar_die 2 "unhandled command '$IHAR_COMMAND'" ;;
  esac
}

ihar_main "$@"
