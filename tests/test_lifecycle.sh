#!/usr/bin/env bash
# The launch lifecycle (LLD 3.3). The step order is the point: LLD revision 2 had
# steps consuming outputs produced after them.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox

PROJECT="$IHAR_TEST_TMP/proj"
mkdir -p "$PROJECT"
IHAR_LOCKFILE="$IHAR_TEST_TMP/lifecycle-lock.json"
export IHAR_LOCKFILE
printf '%s\n' \
  '{"schema":1,"claude":{"version":"2.1.274"},"codex":{"version":"rust-v0.154.0","asset":"codex.tar.gz","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"hooks":{},"managedHooks":{}}' \
  > "$IHAR_LOCKFILE"
cp -R "$ROOT/hooks" "$ROOT/manifests" "$ROOT/skills" "$IHAR_STORE/"

# The launcher runs under `set -e`; the tests must exercise it that way, because the
# failure this catches only happens there.
ihar() { # <args...>
  ( cd "$PROJECT" && IHAR_STORE="$IHAR_STORE" IHAR_STATE_ROOT="$IHAR_STATE_ROOT" \
      "$ROOT/ihar.sh" "$@" ) 2>&1
}

# --- the harness runs at all ------------------------------------------------------

out="$(ihar check)"
assert_contains "check prints the profile" "$out" "profile      standard"
assert_contains "check prints the guarantee verbatim" "$out" "No guarantee."

# --- a launch resolves end to end under set -e -------------------------------------

out="$(ihar --dry-run codex -- mcp list)"
assert_contains "a codex launch resolves" "$out" '"vendor": "codex"'
assert_contains "the passthrough reaches the argv" "$out" '"mcp"'

out="$(ihar --dry-run claude)"
assert_contains "a claude launch resolves" "$out" '"vendor": "claude"'

# --- step order --------------------------------------------------------------------

# The profile is resolved before the store is verified, so an unknown profile is a
# usage error rather than a store complaint.
assert_exit "an unknown profile fails before store verification" 2 \
  bash -c "cd '$PROJECT' && IHAR_STORE='$IHAR_STORE' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' \
           '$ROOT/ihar.sh' --profile nonesuch --dry-run claude"

# The runtime home exists by the time the adapter is asked for its argv, because the
# adapter reads files out of it.
out="$(ihar --dry-run claude)"
runtime="$(sed -n 's/.*"runtime": "\(.*\)".*/\1/p' <<<"$out")"
assert_exit "the runtime home exists after a dry run" 0 test -d "$runtime"
assert_contains "the runtime home is keyed under r/" "$runtime" "/r/"

# A profile whose enforcement this build cannot deliver is refused, not launched with
# the enforcement quietly missing.
assert_exit "a profile needing an undelivered gateway is fail-closed" 3 \
  bash -c "cd '$PROJECT' && IHAR_STORE='$IHAR_STORE' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' \
           '$ROOT/ihar.sh' --profile protected --dry-run claude"

# --- the configuration hash reaches the runtime home ---------------------------------

first="$(ihar --dry-run claude | sed -n 's/.*"runtime": "\(.*\)".*/\1/p')"
second="$(ihar --dry-run claude | sed -n 's/.*"runtime": "\(.*\)".*/\1/p')"
assert_eq "the same configuration resolves to the same home" "$first" "$second"

claude_home="$(ihar --dry-run claude | sed -n 's/.*"runtime": "\(.*\)".*/\1/p')"
codex_home="$(ihar --dry-run codex | sed -n 's/.*"runtime": "\(.*\)".*/\1/p')"
assert_exit "each vendor gets its own runtime home" 1 test "$claude_home" = "$codex_home"

# A change in selected MCP servers chooses a new immutable home for each vendor.
# The variable's value is forwarded by name, so changing only that value does not.
unset IWIKI_REMOTE_TOKEN IHAR_IWIKI_REMOTE_URL
for vendor in claude codex; do
  absent_home="$(ihar --dry-run "$vendor" | sed -n 's/.*"runtime": "\(.*\)".*/\1/p')"
  if [[ "$vendor" == claude ]]; then
    old_render=settings.json
  else
    old_render=config.toml
  fi
  absent_inode="$(stat -c '%i' "$absent_home/$old_render")"
  enabled_home="$(IWIKI_REMOTE_TOKEN=synthetic \
    IHAR_IWIKI_REMOTE_URL=https://wiki.example/mcp \
    ihar --dry-run "$vendor" | sed -n 's/.*"runtime": "\(.*\)".*/\1/p')"
  changed_value_home="$(IWIKI_REMOTE_TOKEN=other-synthetic \
    IHAR_IWIKI_REMOTE_URL=https://wiki.example/mcp \
    ihar --dry-run "$vendor" | sed -n 's/.*"runtime": "\(.*\)".*/\1/p')"
  assert_exit "$vendor selected MCP server chooses a new runtime" 1 \
    test "$absent_home" = "$enabled_home"
  assert_eq "$vendor token value reuses its runtime" "$enabled_home" "$changed_value_home"
  assert_exit "$vendor old generation remains available" 0 test -d "$absent_home"
  assert_eq "$vendor old generation is not rewritten" "$absent_inode" \
    "$(stat -c '%i' "$absent_home/$old_render")"
done
enabled_diff="$(IWIKI_REMOTE_TOKEN=synthetic \
  IHAR_IWIKI_REMOTE_URL=https://wiki.example/mcp ihar check --diff)"
assert_eq "check selects the same MCP generations as launch" "no differences" "$enabled_diff"

# --- the project's own configuration is what is read ------------------------------------
#
# Regression. The loader defaulted to the harness checkout, so a project pinning a
# strict profile silently ran `standard`: the one file whose purpose is to raise a
# project's floor was read from somewhere else entirely.

printf 'IHAR_PROFILE=protected\n' > "$PROJECT/.ihar_config"
out="$(ihar --dry-run claude)"
# It aborts at the store check, which runs before the gateway guard; what matters is
# that the pinned profile was in force at all rather than silently replaced by
# `standard`, which is what a launch resolving successfully would prove.
assert_contains "a profile pinned by the project is in force" "$out" "protected"
assert_eq "and the launch does not resolve as standard" "0" \
  "$(grep -c '"profile": "standard"' <<<"$out")"

printf 'IHAR_DEFAULT_AGENT=codex\n' > "$PROJECT/.ihar_config"
out="$(ihar --dry-run)"
assert_contains "the default agent comes from the project file" "$out" '"vendor": "codex"'

printf 'IHAR_DEFAULT_AGENT=gemini\n' > "$PROJECT/.ihar_config"
assert_exit "an unknown default agent is a usage error" 2 ihar --dry-run
assert_contains "and it names the key" "$(ihar --dry-run)" "IHAR_DEFAULT_AGENT"

printf 'IHAR_NONESUCH=1\n' > "$PROJECT/.ihar_config"
assert_exit "an unknown key in the project file is a usage error" 2 ihar check

rm -f "$PROJECT/.ihar_config"

# --- state is created once and reused ------------------------------------------------

# runtime is <state>/r/<config-hash>/<vendor>, so the state root is three levels up.
state_dir="$(dirname "$(dirname "$(dirname "$claude_home")")")"
assert_exit "the project state carries a marker" 0 test -f "$state_dir/home.json"
assert_exit "vendor state sits beside the runtime homes" 0 test -d "$state_dir/st/claude"

# --- enforced receipt failure precedes vendor execution -------------------------------

FAKE_CLAUDE="$IHAR_TEST_TMP/receipt-claude"
START_MARKER="$IHAR_TEST_TMP/vendor-started"
cat > "$FAKE_CLAUDE" <<SH
#!/usr/bin/env bash
touch '$START_MARKER'
SH
chmod +x "$FAKE_CLAUDE"
RECEIPT_LOCK="$IHAR_TEST_TMP/receipt-lock.json"
printf '%s\n' '{"schema":1,"claude":{"version":"2.1.274"},"hooks":{},"managedHooks":{}}' \
  > "$RECEIPT_LOCK"
lock_sha="$(sha256sum "$RECEIPT_LOCK" | cut -d' ' -f1)"
printf '{"schema":1,"release_lock_sha256":"%s","installed_at":"2026-09-20T00:00:00Z","components":{"claude":{"version":"2.1.274","binary_sha256":"%064d"}}}\n' \
  "$lock_sha" 0 > "$IHAR_STORE/install-receipt.json"

receipt_status=0
receipt_out="$(cd "$PROJECT" && \
  IHAR_STORE="$IHAR_STORE" IHAR_STATE_ROOT="$IHAR_STATE_ROOT" \
  IHAR_LOCKFILE="$RECEIPT_LOCK" IHAR_CLAUDE_BIN="$FAKE_CLAUDE" \
  "$ROOT/ihar.sh" --profile protected claude 2>&1)" || receipt_status=$?
assert_eq "an enforced receipt mismatch exits fail-closed" "3" "$receipt_status"
assert_contains "the launch names receipt verification" "$receipt_out" "install receipt"
assert_exit "receipt failure occurs before the vendor starts" 1 test -e "$START_MARKER"

finish
