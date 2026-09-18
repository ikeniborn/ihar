#!/usr/bin/env bash
# Project configuration parsing (LLD 2.6). The file is parsed, never sourced: it sits
# in a checkout an agent can write, so sourcing it would hand an agent a shell.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
source "$ROOT/lib/core/logging.sh"
source "$ROOT/lib/core/init.sh"
source "$ROOT/lib/core/config.sh"

CFG="$IHAR_TEST_TMP/.ihar_config"

in_shell() { # <script> — run in a clean subshell with the modules loaded
  bash -c "source '$ROOT/lib/core/logging.sh'
           source '$ROOT/lib/core/init.sh'
           source '$ROOT/lib/core/config.sh'
           $1" 2>&1
}

# --- accepted keys --------------------------------------------------------------

cat > "$CFG" <<'EOF'
# a comment, and a blank line follow

IHAR_PROFILE=protected
IHAR_DEFAULT_AGENT=codex
IHAR_GATEWAY_MASKING_LEVEL="standard"
IHAR_IWIKI_REMOTE_URL=https://wiki.example/mcp
EOF

assert_eq "a known key is exported" "protected" \
  "$(in_shell "ihar_config_load '$CFG'; printf '%s' \"\$IHAR_PROFILE\"")"
assert_eq "a quoted value loses its quotes" "standard" \
  "$(in_shell "ihar_config_load '$CFG'; printf '%s' \"\$IHAR_GATEWAY_MASKING_LEVEL\"")"
assert_eq "an open-ended IHAR_IWIKI_* key is accepted" "https://wiki.example/mcp" \
  "$(in_shell "ihar_config_load '$CFG'; printf '%s' \"\$IHAR_IWIKI_REMOTE_URL\"")"

# --- rejected input -------------------------------------------------------------

printf 'IHAR_NONESUCH=1\n' > "$CFG"
assert_exit "an unknown IHAR_* key is a usage error" 2 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/config.sh';
           ihar_config_load '$CFG'"

printf 'PATH=/tmp/evil\n' > "$CFG"
assert_exit "a non-IHAR key is a usage error" 2 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/config.sh';
           ihar_config_load '$CFG'"

printf 'not a key=value line at all\n' > "$CFG"
assert_exit "a malformed line is a usage error" 2 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/config.sh';
           ihar_config_load '$CFG'"

# --- the file is data, not code --------------------------------------------------

printf 'IHAR_PROFILE=$(touch %s/pwned)\n' "$IHAR_TEST_TMP" > "$CFG"
in_shell "ihar_config_load '$CFG'" >/dev/null 2>&1
assert_exit "a command substitution in a value is not executed" 1 \
  test -f "$IHAR_TEST_TMP/pwned"
assert_eq "the value is kept verbatim" "\$(touch $IHAR_TEST_TMP/pwned)" \
  "$(in_shell "ihar_config_load '$CFG'; printf '%s' \"\$IHAR_PROFILE\"")"

# --- the environment map ---------------------------------------------------------

assert_eq "a native name is exported verbatim" "protected" \
  "$(in_shell "IHAR_PROFILE=protected ihar_env_map; printf '%s' \"\$IHAR_PROFILE\"")"
assert_eq "a non-native name is exported de-prefixed" "http://proxy.example" \
  "$(in_shell "IHAR_PROXY_URL=http://proxy.example ihar_env_map; printf '%s' \"\$PROXY_URL\"")"

# --- the roots -------------------------------------------------------------------

roots="$(in_shell "unset IHAR_STORE IHAR_STATE_ROOT
                   HOME=/tmp/home XDG_DATA_HOME= XDG_STATE_HOME= ihar_init '$ROOT/ihar.sh'
                   printf '%s %s %s' \"\$IHAR_STORE\" \"\$IHAR_STATE_ROOT\" \"\$IHAR_NVM\"")"
assert_contains "the store defaults outside the checkout" "$roots" "/tmp/home/.local/share/ihar"
assert_contains "state defaults to the XDG state directory" "$roots" "/tmp/home/.local/state/ihar"
assert_contains "the node tree is a sibling of the store" "$roots" "/tmp/home/.local/share/ihar-nvm"

store_in_checkout="$(in_shell "unset IHAR_STORE
                               HOME=/tmp/home XDG_DATA_HOME= ihar_init '$ROOT/ihar.sh'
                               case \"\$IHAR_STORE\" in \"\$IHAR_ROOT\"*) echo inside;; *) echo outside;; esac")"
assert_eq "the store is never inside the checkout" "outside" "$store_in_checkout"

finish
