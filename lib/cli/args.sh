#!/usr/bin/env bash
# Argument parsing (LLD 3.1, 3.2).
#
# Three rules, and they exist to fix one defect. iclaude forwards any token it does
# not recognise straight to the vendor (iclaude.sh:692-695), so a mistyped harness
# flag silently becomes a vendor argument and the setting the user asked for is not
# applied. Here an unknown flag is a usage error naming the way to forward it.
#
# Failure class: usage (exit 2) for everything this file decides.

IHAR_COMMAND=""
IHAR_PASSTHROUGH=()
IHAR_FLAG_PROFILE=""
IHAR_FLAG_DRY_RUN=false
IHAR_FLAG_JSON=false
IHAR_FLAG_RESUME=""
IHAR_FLAG_FORK=false
IHAR_FLAG_NAME=""
IHAR_FLAG_MODEL=""
IHAR_FLAG_EFFORT=""
IHAR_FLAG_APPROVAL=""
IHAR_FLAG_MASK_LEVEL=""
IHAR_FLAG_WEB=false
IHAR_FLAG_PROMPT=""
IHAR_FLAG_CONFORMANCE=false
IHAR_FLAG_TO=""
IHAR_FLAG_MICROVM=false
IHAR_SUBCOMMAND=""
IHAR_ARGS=()

# Flags the parser accepts but no slice has delivered yet. Empty after S12.
_IHAR_UNDELIVERED_SLICE=()

ihar_guard_undelivered() {
  local entry flag slice value
  for entry in "${_IHAR_UNDELIVERED_SLICE[@]}"; do
    flag="${entry%%:*}"; slice="${entry##*:}"
    case "$flag" in
      --web)        value="$([[ "$IHAR_FLAG_WEB" == true ]] && echo set || true)" ;;
      --json)       value="$([[ "$IHAR_FLAG_JSON" == true ]] && echo set || true)" ;;
    esac
    [[ -z "$value" ]] || ihar_die 2 "$flag is accepted but not yet enforced; slice $slice delivers it
running now would report success while doing nothing"
  done

  if [[ "$IHAR_FLAG_FORK" == true && -z "$IHAR_FLAG_RESUME" ]]; then
    ihar_die 2 "--fork needs --resume: there is nothing to fork from"
  fi
}

# Commands this build implements. A command a later slice adds is not listed, so
# asking for it is an error naming the slice rather than a silent no-op.
_IHAR_COMMANDS=(claude codex check homes install update daemon sessions switch web)

_ihar_is_command() {
  local candidate="$1" known
  for known in "${_IHAR_COMMANDS[@]}"; do
    [[ "$candidate" == "$known" ]] && return 0
  done
  return 1
}

_ihar_needs_value() {
  [[ -n "${2:-}" ]] || ihar_die 2 "$1 needs a value"
}

# ihar_args_parse "$@"
ihar_args_parse() {
  # Rule 1: global flags come before the command, and an unknown one is an error.
  while (( $# )); do
    case "$1" in
      --profile)    _ihar_needs_value "$1" "${2:-}"; IHAR_FLAG_PROFILE="$2"; shift 2 ;;
      --profile=*)  IHAR_FLAG_PROFILE="${1#*=}"; shift ;;
      --dry-run)    IHAR_FLAG_DRY_RUN=true; shift ;;
      --json)       IHAR_FLAG_JSON=true; shift ;;
      --assume-yes) IHAR_ASSUME_YES=1; export IHAR_ASSUME_YES; shift ;;
      -h|--help)    IHAR_COMMAND="help"; return 0 ;;
      --)           ihar_die 2 "-- before a command: name the agent first, as in 'ihar codex -- mcp list'" ;;
      -*)           ihar_die 2 "unknown global flag '$1'" ;;
      *)            break ;;
    esac
  done

  if (( $# == 0 )); then
    IHAR_COMMAND="${IHAR_DEFAULT_AGENT:-claude}"
    # Validated here rather than left to the dispatcher: an unknown value would
    # otherwise surface as an internal "unhandled command" from the entry point,
    # which tells the user nothing about the key that caused it.
    _ihar_is_command "$IHAR_COMMAND" \
      || ihar_die 2 "IHAR_DEFAULT_AGENT is '$IHAR_COMMAND', which is not an agent; use claude or codex"
    return 0
  fi

  _ihar_is_command "$1" || ihar_die 2 "unknown command '$1'; known commands are ${_IHAR_COMMANDS[*]}"
  IHAR_COMMAND="$1"; shift

  # Rule 2: after the command only its own flags are parsed. Rule 3: -- ends parsing.
  while (( $# )); do
    case "$1" in
      --) shift; IHAR_PASSTHROUGH=("$@"); return 0 ;;
    esac

    if [[ "$IHAR_COMMAND" == claude || "$IHAR_COMMAND" == codex ||
          ( "$IHAR_COMMAND" == web && -n "$IHAR_SUBCOMMAND" ) ]]; then
      case "$1" in
        --resume)      _ihar_needs_value "$1" "${2:-}"; IHAR_FLAG_RESUME="$2"; shift 2; continue ;;
        --resume=*)    IHAR_FLAG_RESUME="${1#*=}"; shift; continue ;;
        --fork)        IHAR_FLAG_FORK=true; shift; continue ;;
        --name)        _ihar_needs_value "$1" "${2:-}"; IHAR_FLAG_NAME="$2"; shift 2; continue ;;
        --model)       _ihar_needs_value "$1" "${2:-}"; IHAR_FLAG_MODEL="$2"; shift 2; continue ;;
        --effort)      _ihar_needs_value "$1" "${2:-}"; IHAR_FLAG_EFFORT="$2"; shift 2; continue ;;
        --approval)    _ihar_needs_value "$1" "${2:-}"; IHAR_FLAG_APPROVAL="$2"; shift 2; continue ;;
        --mask-level)  _ihar_needs_value "$1" "${2:-}"; IHAR_FLAG_MASK_LEVEL="$2"; shift 2; continue ;;
        --web)         IHAR_FLAG_WEB=true; shift; continue ;;
      esac
    fi

    if [[ "$IHAR_COMMAND" == switch ]]; then
      case "$1" in
        --to) _ihar_needs_value "$1" "${2:-}"; IHAR_FLAG_TO="$2"; shift 2; continue ;;
        --to=*) IHAR_FLAG_TO="${1#*=}"; shift; continue ;;
      esac
    fi

    case "$1" in
      # A global flag written after the command is a position mistake, not a request
      # to forward it. Telling the user to pass it to the agent would send a harness
      # flag to the vendor, which is the defect this parser exists to prevent.
      --profile|--profile=*|--dry-run|--json|--assume-yes)
        ihar_die 2 "'${1%%=*}' is a global flag and goes before the command
try: ihar $1 $IHAR_COMMAND ..."
        ;;
      --conformance)
        # Before the catch-all below, or it would never be reached.
        [[ "$IHAR_COMMAND" == check ]] \
          || ihar_die 2 "--conformance belongs to 'ihar check'"
        IHAR_FLAG_CONFORMANCE=true; shift; continue
        ;;
      --microvm)
        [[ "$IHAR_COMMAND" == install ]] \
          || ihar_die 2 "--microvm belongs to 'ihar install'"
        IHAR_FLAG_MICROVM=true; shift; continue
        ;;
      -*)
        ihar_die 2 "unknown flag '$1' for '$IHAR_COMMAND'
use -- to forward it to the agent, as in 'ihar $IHAR_COMMAND -- $1'"
        ;;
      *)
        # A positional belongs to the command. For an agent it is the initial
        # prompt, which both vendors accept; an earlier draft collected it into a
        # variable nothing read, so `ihar claude "fix the bug"` dropped the prompt
        # silently — the very defect this parser exists to prevent.
        if [[ "$IHAR_COMMAND" == claude || "$IHAR_COMMAND" == codex ]]; then
          [[ -z "$IHAR_FLAG_PROMPT" ]] \
            || ihar_die 2 "only one prompt is accepted; quote it as a single argument"
          IHAR_FLAG_PROMPT="$1"
        elif [[ -z "$IHAR_SUBCOMMAND" ]]; then
          IHAR_SUBCOMMAND="$1"
        else
          IHAR_ARGS+=("$1")
        fi
        shift
        ;;
    esac
  done
}
