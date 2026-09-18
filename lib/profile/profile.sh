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

  ihar_masking_resolve
}

# Ordered weakest to strongest; an override may move right, never left.
_IHAR_MASK_ORDER=(off secrets standard)

_ihar_mask_rank() {
  local level="$1" index=0 candidate
  for candidate in "${_IHAR_MASK_ORDER[@]}"; do
    [[ "$candidate" == "$level" ]] && { printf '%s\n' "$index"; return 0; }
    index=$((index + 1))
  done
  ihar_die 2 "unknown masking level '$level'; use off, secrets or standard"
}

# ihar_masking_resolve — the effective level (LLD 12.3).
#
# The profile's masking_level is a floor, not a default. An override in .ihar_config
# or on the command line may tighten it and never loosen it: a project file that
# could set `off` under `protected` would turn a mandatory enforcement point into a
# no-op while the profile's name went on promising otherwise.
ihar_masking_resolve() {
  local floor="$IHAR_PROFILE_MASKING_LEVEL" effective="$IHAR_PROFILE_MASKING_LEVEL"
  local candidate floor_rank rank

  floor_rank="$(_ihar_mask_rank "$floor")"
  for candidate in "${IHAR_GATEWAY_MASKING_LEVEL:-}" "${IHAR_FLAG_MASK_LEVEL:-}"; do
    [[ -n "$candidate" ]] || continue
    rank="$(_ihar_mask_rank "$candidate")"
    if (( rank < floor_rank )); then
      ihar_die 2 "profile '$IHAR_PROFILE' requires masking level '$floor'; '$candidate' would weaken it"
    fi
    effective="$candidate"
  done

  # Masking with nothing to enforce it is a guarantee nobody keeps: the handoff
  # package would be sanitised while every model request left untouched, and the
  # statusline would report masking as active. Promoting the gateway silently would
  # change the security topology behind the user's back, so this is an error.
  if [[ "$effective" != "off" && "${IHAR_PROFILE_GATEWAY:-off}" == "off" ]]; then
    ihar_die 2 "masking level is '$effective' but profile '$IHAR_PROFILE' has no model egress gateway
handoff would be sanitised while model requests would not
use --profile protected or remote-protected"
  fi

  IHAR_GATEWAY_MASKING_LEVEL="$effective"
  export IHAR_GATEWAY_MASKING_LEVEL
}
