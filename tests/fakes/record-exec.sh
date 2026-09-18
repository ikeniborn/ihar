#!/usr/bin/env bash
# A stand-in for a vendor binary. Records the argv and the environment it was given
# into IHAR_FAKE_RECORD, then exits with IHAR_FAKE_EXIT.
#
# The adapter tests assert against this, so the exact command a launch would run is
# provable without either vendor installed.
set -uo pipefail

record="${IHAR_FAKE_RECORD:-/dev/stdout}"
{
  printf 'argv0\t%s\n' "$0"
  for arg in "$@"; do printf 'arg\t%s\n' "$arg"; done
  while IFS='=' read -r name _; do printf 'env\t%s\n' "$name"; done < <(env)
} > "$record"

exit "${IHAR_FAKE_EXIT:-0}"
