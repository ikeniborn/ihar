#!/usr/bin/env bash
# Profile resolution, the masking floor, and the sandbox render (LLD 9.1, 12.2, 12.3).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox

PROJECT="$IHAR_TEST_TMP/proj"
mkdir -p "$PROJECT" "$IHAR_STORE"
cp -r "$ROOT/hooks" "$IHAR_STORE/hooks"

ihar() {
  ( cd "$PROJECT" && IHAR_STORE="$IHAR_STORE" IHAR_STATE_ROOT="$IHAR_STATE_ROOT" \
      "$ROOT/ihar.sh" "$@" ) 2>&1
}

# --- resolution precedence --------------------------------------------------------

assert_contains "the default profile is standard" "$(ihar check)" "profile      standard"
printf 'IHAR_PROFILE=protected\n' > "$PROJECT/.ihar_config"
assert_contains "the project file sets it" "$(ihar check)" "profile      protected"
assert_contains "and the flag beats the file" "$(ihar --profile standard check)" "profile      standard"
rm -f "$PROJECT/.ihar_config"
assert_exit "an unknown profile is a usage error" 2 ihar --profile nonesuch check

# --- the masking floor may be tightened, never loosened ------------------------------
#
# A project file that could set `off` under `protected` would turn a mandatory
# enforcement point into a no-op while the profile's name went on promising
# otherwise.

assert_exit "loosening the floor is refused" 2 \
  bash -c "cd '$PROJECT' && IHAR_STORE='$IHAR_STORE' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' \
           IHAR_GATEWAY_MASKING_LEVEL=off '$ROOT/ihar.sh' --profile protected check"
out="$(bash -c "cd '$PROJECT' && IHAR_STORE='$IHAR_STORE' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' \
      IHAR_GATEWAY_MASKING_LEVEL=off '$ROOT/ihar.sh' --profile protected check" 2>&1)"
assert_contains "and it says which level is required" "$out" "requires masking level 'standard'"

# An override equal to the floor is accepted; there is no profile where a level
# above `standard` exists to tighten to, and any level above `off` needs a gateway,
# which is the next rule.
assert_exit "an override equal to the floor is accepted" 0 \
  bash -c "cd '$PROJECT' && IHAR_STORE='$IHAR_STORE' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' \
           IHAR_GATEWAY_MASKING_LEVEL=off '$ROOT/ihar.sh' --profile standard check"

source "$ROOT/lib/core/logging.sh"
source "$ROOT/lib/profile/profile.sh"
assert_eq "the levels rank weakest to strongest" "0 1 2" \
  "$(_ihar_mask_rank off) $(_ihar_mask_rank secrets) $(_ihar_mask_rank standard)"
assert_exit "an unknown level is a usage error" 2 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/profile/profile.sh'
           _ihar_mask_rank nonesuch"

# --- masking without a gateway is refused ----------------------------------------------
#
# Handoff would be sanitised while every model request left untouched, and the
# statusline would report masking as active. Promoting the gateway silently would
# change the security topology behind the user's back, so this is an error.

assert_exit "masking under a gateway-less profile is a usage error" 2 \
  bash -c "cd '$PROJECT' && IHAR_STORE='$IHAR_STORE' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' \
           IHAR_GATEWAY_MASKING_LEVEL=standard '$ROOT/ihar.sh' --profile standard check"
out="$(bash -c "cd '$PROJECT' && IHAR_STORE='$IHAR_STORE' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' \
      IHAR_GATEWAY_MASKING_LEVEL=standard '$ROOT/ihar.sh' --profile standard check" 2>&1)"
assert_contains "and it explains the asymmetry" "$out" "handoff would be sanitised while model requests would not"

# --- the sandbox render --------------------------------------------------------------------

source "$ROOT/lib/core/logging.sh"
source "$ROOT/lib/core/init.sh"
IHAR_ROOT="$ROOT"; export IHAR_ROOT
source "$ROOT/lib/render/config.sh"

render_codex() { # <sandbox> [approval]
  local dir="$IHAR_TEST_TMP/render-$RANDOM"
  mkdir -p "$dir"
  : > "$dir/config.toml"
  IHAR_PROFILE_SANDBOX="$1" IHAR_FLAG_APPROVAL="${2:-}" IHAR_GATEWAY_MODE=off \
    IHAR_PROJECT_ROOT="$PROJECT" _ihar_render_codex_config "$dir"
  cat "$dir/config.toml"
}

# `vendor-default` writes nothing. HLD section 8 calls the sandbox optional for
# `standard`, and rendering a region there would write danger-full-access and drop
# default_permissions, which icodex warns disables managed rules — strictly weaker
# than what icodex ships.
out="$(render_codex vendor-default)"
assert_eq "vendor-default writes no mode region" "0" "$(grep -c 'sandbox_mode' <<<"$out")"
assert_eq "and no danger-full-access anywhere" "0" "$(grep -c 'danger-full-access' <<<"$out")"

out="$(render_codex vendor)"
assert_contains "vendor renders workspace-write" "$out" 'sandbox_mode = "workspace-write"'
assert_contains "with managed permissions" "$out" 'default_permissions = "dev-safe"'
assert_contains "and the git grant" "$out" '".git/" = "write"'

out="$(render_codex read-only)"
assert_contains "read-only renders read-only" "$out" 'sandbox_mode = "read-only"'
assert_contains "and still names permissions" "$out" 'default_permissions'

out="$(render_codex vendor never)"
assert_contains "--approval changes the approval policy" "$out" 'approval_policy = "never"'
assert_contains "and nothing else" "$out" 'sandbox_mode = "workspace-write"'

# --- the gateway instance key covers the whole configuration -----------------------------------
#
# Keying by mode alone let two launches with different masking levels share one
# process, so one of them silently ran under the other's policy.

source "$ROOT/lib/core/lock.sh"
source "$ROOT/lib/gateway/gateway.sh"
key_a="$(IHAR_PROFILE_GATEWAY=explicit IHAR_GATEWAY_MASKING_LEVEL=standard ihar_gateway_key)"
key_b="$(IHAR_PROFILE_GATEWAY=explicit IHAR_GATEWAY_MASKING_LEVEL=secrets ihar_gateway_key)"
key_c="$(IHAR_PROFILE_GATEWAY=explicit IHAR_GATEWAY_MASKING_LEVEL=standard ihar_gateway_key)"
assert_eq "the same configuration keys the same instance" "$key_a" "$key_c"
assert_exit "a different masking level keys a different one" 1 test "$key_a" = "$key_b"

key_d="$(IHAR_PROFILE_GATEWAY=explicit IHAR_GATEWAY_MASKING_LEVEL=standard \
         IHAR_GATEWAY_ENGINE=regex ihar_gateway_key)"
assert_exit "so does a different engine" 1 test "$key_a" = "$key_d"

finish
