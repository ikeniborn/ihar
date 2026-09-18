#!/usr/bin/env bash
# Adapter dispatch (LLD 5.1).
#
# An adapter translates canonical operations into vendor commands. It implements no
# policy: it receives the rendered files and the enforcement results through the
# environment and does what they say. Keeping policy out of here is what makes a
# third agent an adapter plus renderers rather than a second copy of the harness.
#
# Failure class: usage for an operation a vendor does not implement.

# ihar_adapter <vendor> <op> [args...]
ihar_adapter() {
  local vendor="$1" op="$2"; shift 2
  local fn="adapter_${vendor}_${op}"
  if ! declare -F "$fn" >/dev/null; then
    ihar_die 2 "adapter '$vendor' does not implement '$op'"
  fi
  "$fn" "$@"
}

# ihar_adapter_has <vendor> <op> — for callers that can do without an operation.
ihar_adapter_has() {
  declare -F "adapter_${1}_${2}" >/dev/null
}
