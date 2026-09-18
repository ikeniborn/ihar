#!/usr/bin/env bash
# Profile resolution (LLD 12.2).
#
# Resolution and field export only. The masking floor, the tighten-only override and
# the refusal of masking without a gateway are enforcement, and they arrive with the
# gateway in slice S7; the profile file already carries the values they will read.
#
# Failure class: usage (exit 2). An unknown profile is a typo worth stopping for,
# because falling back to a default would silently weaken the run.

# ihar_profile_resolve [flag-value] — flag > .ihar_config > standard.
ihar_profile_resolve() {
  local name="${1:-}"
  [[ -n "$name" ]] || name="${IHAR_PROFILE:-standard}"

  local file="$IHAR_ROOT/manifests/profiles/$name.json"
  if [[ ! -f "$file" ]]; then
    local available
    available="$(ls "$IHAR_ROOT"/manifests/profiles/*.json 2>/dev/null \
                 | xargs -r -n1 basename | sed 's/\.json$//' | paste -sd' ' -)"
    ihar_die 2 "unknown profile '$name'; available profiles are ${available:-none}"
  fi

  # Validated on read, so a hand-edited profile fails here rather than at the point
  # some later layer trusts one of its fields.
  local fields
  fields="$(ihar_python ihar.profile_read "$file")" \
    || ihar_die 2 "profile '$name' is not valid; see the error above"
  eval "$fields"

  IHAR_PROFILE="$name"
  export IHAR_PROFILE
}
