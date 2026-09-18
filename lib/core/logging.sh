#!/usr/bin/env bash
# Human-facing output. Everything goes to stderr so stdout stays a machine channel:
# several functions print JSON lines that a caller parses.
#
# Failure class: none of these decide anything; they report.

ihar_info()  { printf 'ihar: %s\n'          "$*" >&2; }
ihar_warn()  { printf 'ihar: warning: %s\n' "$*" >&2; }
ihar_error() { printf 'ihar: %s\n'          "$*" >&2; }

# ihar_die <exit-code> <message...> — the one way a module aborts. The code carries
# the failure class of CLAUDE.md: 3 fail-closed, 2 usage, 1 runtime.
ihar_die() {
  local code="$1"; shift
  ihar_error "$*"
  exit "$code"
}
