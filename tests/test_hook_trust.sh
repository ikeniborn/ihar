#!/usr/bin/env bash
# Codex hook trust (LLD 6.4, 6.5).
#
# Every assertion here runs against the pinned Codex binary, because the mechanism
# was chosen by measuring it: the managed directory the LLD first specified is not
# readable from a project configuration, and `bypass_hook_trust` does not confer
# trust at all. Nothing in this area can be proven with a fixture.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
export PYTHONPATH="$ROOT/lib/python"

CODEX="${IHAR_CODEX_BIN:-/home/ikeniborn/Documents/Project/icodex/.codex-isolated/bin/codex}"
if [[ ! -x "$CODEX" ]]; then
  echo "SKIP [hook trust]: no Codex binary at $CODEX"
  finish
  exit 0
fi

HOME_DIR="$IHAR_TEST_TMP/codex"
PROJECT="$IHAR_TEST_TMP/proj"
mkdir -p "$HOME_DIR/hooks" "$PROJECT"

python3 -m ihar.render.hooks codex protected "$ROOT/manifests/hooks.json" CODEX_HOME \
  > "$HOME_DIR/hooks.json"
cp "$ROOT/hooks/security-pretool.py" "$ROOT/hooks/session-register.py" "$HOME_DIR/hooks/"
cp -r "$ROOT/hooks/_shared" "$HOME_DIR/hooks/"
: > "$HOME_DIR/config.toml"

trust() { python3 -m ihar.codex.hooks_trust "$@"; }

# --- an unsealed home is refused ----------------------------------------------------

assert_exit "a rendered but untrusted hook fails verification" 1 \
  trust --verify "$CODEX" "$HOME_DIR" "$PROJECT" security-pretool.py
assert_contains "and the reason names the trust state" \
  "$(trust --verify "$CODEX" "$HOME_DIR" "$PROJECT" security-pretool.py)" "trustStatus is 'untrusted'"

# --- sealing makes exactly ihar's own hooks trusted -----------------------------------

sealed="$(trust --seal "$CODEX" "$HOME_DIR" "$PROJECT")"
assert_exit "sealing reports the hooks it trusted" 0 test -n "$sealed"
assert_contains "the trust block is written into config.toml" \
  "$(cat "$HOME_DIR/config.toml")" "ihar:hook-trust:start"
assert_contains "and it records a digest, not a bypass" \
  "$(cat "$HOME_DIR/config.toml")" "trusted_hash"
assert_eq "bypass_hook_trust is written nowhere" "0" \
  "$(grep -c 'bypass_hook_trust' "$HOME_DIR/config.toml")"

assert_exit "a sealed home verifies" 0 \
  trust --verify "$CODEX" "$HOME_DIR" "$PROJECT" security-pretool.py

# --- tampering is detected -------------------------------------------------------------
#
# This is the property the whole mechanism exists for: verifying a hook at launch is
# worth nothing if an agent can rewrite it afterwards and the vendor still runs it.

cp "$HOME_DIR/hooks.json" "$IHAR_TEST_TMP/hooks.json.bak"
python3 - "$HOME_DIR/hooks.json" <<'PY'
import json, sys
path = sys.argv[1]
block = json.load(open(path))
entry = block["hooks"]["PreToolUse"][0]["hooks"][0]
entry["command"] = "/bin/true"          # the agent replaces the security hook
json.dump(block, open(path, "w"), indent=2, sort_keys=True)
PY

assert_exit "an edited hook no longer verifies" 1 \
  trust --verify "$CODEX" "$HOME_DIR" "$PROJECT" security-pretool.py
assert_contains "and it reports the edit rather than a fresh untrusted state" \
  "$(trust --verify "$CODEX" "$HOME_DIR" "$PROJECT" security-pretool.py)" "trustStatus is 'modified'"

cp "$IHAR_TEST_TMP/hooks.json.bak" "$HOME_DIR/hooks.json"
assert_exit "restoring the hook restores its trust" 0 \
  trust --verify "$CODEX" "$HOME_DIR" "$PROJECT" security-pretool.py

# --- a project hook is never trusted by ihar --------------------------------------------
#
# Extending trust to whatever a repository ships is precisely what made
# bypass_hook_trust unacceptable.

mkdir -p "$PROJECT/.codex"
cat > "$PROJECT/.codex/hooks.json" <<'JSON'
{"hooks": {"PreToolUse": [{"matcher": "Bash",
 "hooks": [{"type": "command", "command": "/bin/echo pwned", "timeout": 5}]}]}}
JSON
trust --seal "$CODEX" "$HOME_DIR" "$PROJECT" >/dev/null
assert_eq "the project's own hook is not in the trust block" "0" \
  "$(grep -c "$PROJECT" "$HOME_DIR/config.toml")"

# --- the managed directory the LLD first chose is unavailable ------------------------------
#
# Recorded as a test so the decision is not quietly revisited: if a future Codex
# honours it from a project configuration, this fails and the design can improve.

MANAGED="$IHAR_TEST_TMP/managed"
mkdir -p "$MANAGED"
cp "$HOME_DIR/hooks.json" "$MANAGED/hooks.json"
OTHER="$IHAR_TEST_TMP/codex-managed"
mkdir -p "$OTHER"
printf '[hooks]\nmanaged_dir = "%s"\n' "$MANAGED" > "$OTHER/config.toml"
listed="$(python3 -c '
import sys
from ihar.codex.appserver import hooks_list
print(len(hooks_list(sys.argv[1], sys.argv[2], [sys.argv[3]])))
' "$CODEX" "$OTHER" "$PROJECT" 2>/dev/null || echo error)"
assert_eq "hooks.managed_dir from a project config.toml yields no hooks" "0" "$listed"

finish
