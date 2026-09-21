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
assert_exit "the failed transparent profile is unavailable" 2 \
  ihar --profile remote-protected check

json_check="$(ihar --json check)"
assert_eq "JSON check validates as a closed result" "standard" \
  "$(PYTHONPATH="$ROOT/lib/python" python3 -c 'import json,sys; from ihar import jsonio; print(jsonio.check("check-result", json.load(sys.stdin))["profile"]["name"])' <<<"$json_check")"
assert_eq "JSON check carries per-hook trust facts" "True" \
  "$(python3 -c 'import json,sys; d=json.load(sys.stdin); required={"id","trust","trusted_hash","trustStatus","enabled","source","currentHash"}; print(bool(d["vendors"]["claude"]["hooks"]) and all(set(x)==required for x in d["vendors"]["claude"]["hooks"]+d["vendors"]["codex"]["hooks"]))' <<<"$json_check")"
assert_contains "text and JSON check share the profile" "$(ihar check)" \
  "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["profile"]["name"])' <<<"$json_check")"
assert_eq "standard reports no network enforcement" \
  '{"active": false, "available": false, "configured": false, "default": "allow", "scope": "none", "state": "not enforced", "verified": false}' \
  "$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["network"], sort_keys=True))' <<<"$json_check")"

protected_json="$(ihar --profile protected --json check)"
assert_eq "protected does not claim whole-network enforcement" \
  '{"active": false, "available": false, "configured": false, "default": "allow", "scope": "none", "state": "not enforced", "verified": false}' \
  "$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["network"], sort_keys=True))' <<<"$protected_json")"
assert_contains "protected text names the absent network boundary" \
  "$(ihar --profile protected check)" \
  "network      not enforced (scope none, default allow; configured false, available false, active false, verified false)"

isolated_json="$(ihar --profile isolated --json check)"
assert_eq "isolated does not infer enforcement from its profile" \
  '{"active": false, "available": false, "configured": true, "default": "deny", "scope": "guest-boundary", "state": "not enforced", "verified": false}' \
  "$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["network"], sort_keys=True))' <<<"$isolated_json")"
assert_contains "isolated text names missing live guest evidence" \
  "$(ihar --profile isolated check)" \
  "network      not enforced (scope guest-boundary, default deny; configured true, available false, active false, verified false)"

# Diff renders in temporary directories only. A runtime difference names vendor and
# relative path while the persistent store/state/runtime bytes stay unchanged.
CHECK_STATE="$IHAR_STATE_ROOT/$(printf '%s' "$PROJECT" | sha256sum | cut -c1-8)"
mkdir -p "$CHECK_STATE/r/deadbeef/claude" "$CHECK_STATE/r/deadbeef/codex"
printf 'different\n' > "$CHECK_STATE/r/deadbeef/claude/settings.json"
printf 'different\n' > "$CHECK_STATE/r/deadbeef/codex/config.toml"
check_fingerprint() {
  { find "$IHAR_STORE" "$IHAR_STATE_ROOT" -printf '%y\t%m\t%P\t%l\n' | sort
    find "$IHAR_STORE" "$IHAR_STATE_ROOT" -type f -print0 | sort -z | xargs -0 -r sha256sum; } | sha256sum | cut -d' ' -f1
}
before_isolated_check="$(check_fingerprint)"
ihar --profile isolated check >/dev/null
assert_eq "isolated check leaves persistent files unchanged" \
  "$before_isolated_check" "$(check_fingerprint)"
before_check="$(check_fingerprint)"
diff_out="$(ihar check --diff)"
assert_contains "diff names Claude relative path" "$diff_out" "claude settings.json"
assert_contains "diff names Codex relative path" "$diff_out" "codex config.toml"
assert_eq "diff leaves persistent files unchanged" "$before_check" "$(check_fingerprint)"

EVIDENCE="$IHAR_TEST_TMP/conformance-called"
PY_WRAPPER="$IHAR_TEST_TMP/check-python"
VENDOR_STUB="$IHAR_TEST_TMP/vendor-stub"
cat > "$PY_WRAPPER" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"ihar.conformance.run"* ]]; then
  : > "$IHAR_TEST_EVIDENCE"
  if [[ "$3" == "${IHAR_TEST_FAIL_VENDOR:-}" ]]; then
    printf 'failed live_hook\n'
    exit 1
  fi
  exit 0
fi
exec python3 "$@"
EOF
printf '#!/usr/bin/env bash\necho vendor 1.0\n' > "$VENDOR_STUB"
chmod +x "$PY_WRAPPER" "$VENDOR_STUB"
IHAR_PY="$PY_WRAPPER" IHAR_TEST_EVIDENCE="$EVIDENCE" \
  IHAR_CLAUDE_BIN="$VENDOR_STUB" IHAR_CODEX_BIN="$VENDOR_STUB" ihar check >/dev/null
assert_exit "plain check does not run conformance" 1 test -e "$EVIDENCE"
IHAR_PY="$PY_WRAPPER" IHAR_TEST_EVIDENCE="$EVIDENCE" \
  IHAR_CLAUDE_BIN="$VENDOR_STUB" IHAR_CODEX_BIN="$VENDOR_STUB" ihar check --diff >/dev/null
assert_exit "diff does not run conformance" 1 test -e "$EVIDENCE"
IHAR_PY="$PY_WRAPPER" IHAR_TEST_EVIDENCE="$EVIDENCE" \
  IHAR_CLAUDE_BIN="$VENDOR_STUB" IHAR_CODEX_BIN="$VENDOR_STUB" ihar check --conformance >/dev/null
assert_exit "only conformance mode invokes live evidence" 0 test -e "$EVIDENCE"

text_status=0
text_output="$(IHAR_PY="$PY_WRAPPER" IHAR_TEST_EVIDENCE="$EVIDENCE" \
  IHAR_TEST_FAIL_VENDOR=claude IHAR_CLAUDE_BIN="$VENDOR_STUB" \
  IHAR_CODEX_BIN="$VENDOR_STUB" ihar check --conformance)" || text_status=$?
assert_eq "failed conformance retains nonzero status after text rendering" 1 "$text_status"
assert_contains "failed conformance still renders text status" "$text_output" "profile      standard"
json_stdout="$IHAR_TEST_TMP/check-conformance-stdout.json"
json_stderr="$IHAR_TEST_TMP/check-conformance-stderr"
json_status=0
( cd "$PROJECT" && IHAR_PY="$PY_WRAPPER" IHAR_TEST_EVIDENCE="$EVIDENCE" \
    IHAR_TEST_FAIL_VENDOR=claude IHAR_CLAUDE_BIN="$VENDOR_STUB" \
    IHAR_CODEX_BIN="$VENDOR_STUB" "$ROOT/ihar.sh" --json check --conformance \
    > "$json_stdout" 2> "$json_stderr" ) || json_status=$?
assert_eq "failed conformance retains nonzero status after JSON rendering" 1 "$json_status"
assert_exit "conformance JSON stdout is one status object" 0 python3 -m json.tool "$json_stdout"
assert_eq "conformance JSON stdout contains no case diagnostics" 0 \
  "$(grep -c 'failed live_hook' "$json_stdout")"
assert_contains "conformance JSON stderr identifies the vendor" \
  "$(cat "$json_stderr")" "claude conformance"
assert_contains "conformance JSON stderr retains bounded case diagnostics" \
  "$(cat "$json_stderr")" "failed live_hook"

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
source "$ROOT/lib/state/runtime.sh"
source "$ROOT/lib/render/config.sh"
source "$ROOT/lib/render/hooks.sh"
source "$ROOT/lib/codex/daemon.sh"
source "$ROOT/lib/cli/commands.sh"
IHAR_CODEX_BIN="$IHAR_TEST_TMP/missing-codex"; export IHAR_CODEX_BIN

render_codex() { # <sandbox> [approval]
  local dir="$IHAR_TEST_TMP/render-$RANDOM"
  mkdir -p "$dir"
  : > "$dir/config.toml"
  IHAR_PROFILE_SANDBOX="$1" IHAR_FLAG_APPROVAL="${2:-}" IHAR_GATEWAY_MODE=off \
    IHAR_PROJECT_ROOT="$PROJECT" _ihar_render_codex_config "$dir"
  # The renderer emits fragments and the assembly orders them; reading the fragments
  # would test half the contract and miss the ordering the assembly exists for.
  ihar_render_config_assemble "$dir"
  cat "$dir/config.toml"
}

render_claude() { # <sandbox> <store> <state-root> <runtime>
  local sandbox="$1" store="$2" state_root="$3" runtime="$4"
  mkdir -p "$runtime"
  printf '{}\n' > "$runtime/settings.json"
  IHAR_PROFILE_SANDBOX="$sandbox" IHAR_STORE="$store" \
    IHAR_STATE_ROOT="$state_root" IHAR_GATEWAY_MODE=off \
    _ihar_render_claude_config "$runtime" "$runtime"
  cat "$runtime/settings.json"
}

settings="$(render_claude protected "$IHAR_STORE" "$IHAR_STATE_ROOT" "$PROJECT/runtime")"
assert_eq "Claude disables unsandboxed retries" "False" \
  "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sandbox"]["allowUnsandboxedCommands"])' <<<"$settings")"
assert_eq "Claude fails when sandbox is unavailable" "True" \
  "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sandbox"]["failIfUnavailable"])' <<<"$settings")"
for protected in "$IHAR_STORE" "$IHAR_STATE_ROOT" "$PROJECT/runtime"; do
  assert_contains "Claude denies $protected" "$settings" "$protected"
done

settings="$(render_claude vendor-default "$IHAR_STORE" "$IHAR_STATE_ROOT" "$PROJECT/runtime-standard")"
assert_eq "standard omits the managed Claude sandbox" "False" \
  "$(python3 -c 'import json,sys; print("sandbox" in json.load(sys.stdin))' <<<"$settings")"

settings="$(render_claude protected "$PROJECT/../proj/store" "$PROJECT/store" "$PROJECT/runtime-dedup")"
assert_eq "Claude protected paths are absolute" "True" \
  "$(python3 -c 'import json,os,sys; roots=json.load(sys.stdin)["sandbox"]["filesystem"]["denyWrite"]; print(all(os.path.isabs(path) for path in roots))' <<<"$settings")"
assert_eq "Claude protected paths are deduplicated" "2" \
  "$(python3 -c 'import json,sys; roots=json.load(sys.stdin)["sandbox"]["filesystem"]["denyWrite"]; print(len(roots) if len(roots) == len(set(roots)) else -1)' <<<"$settings")"

ihar_manifest_digest() { printf 'hooks-fixture\n'; }
ihar_registry_digest() { printf 'registry-fixture\n'; }
ihar_vendor_version() { printf 'claude-2.1.274\n'; }
lifecycle_render="$PROJECT/render-lifecycle"
mkdir -p "$lifecycle_render"
printf '{}\n' > "$lifecycle_render/settings.json"
IHAR_STATE="$PROJECT/state" IHAR_PROFILE=protected IHAR_PROFILE_MASKING_LEVEL=standard \
  IHAR_PROFILE_GATEWAY=off IHAR_PROFILE_SANDBOX=vendor IHAR_PROFILE_MCP_STRICT=true \
  IHAR_GATEWAY_MODE=off ihar_render_config claude "$lifecycle_render"
settings="$(cat "$lifecycle_render/settings.json")"
lifecycle_roots="$(python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["sandbox"]["filesystem"]["denyWrite"]))' <<<"$settings")"
final_hash="$(printf '%s\n' \
  protected standard off vendor true hooks-fixture registry-fixture claude-2.1.274 \
  "$(ihar_state_manifest_digest)" "$(ihar_asset_manifest_identity)" \
  | sha256sum | cut -c1-8)"
final_runtime="$PROJECT/state/r/$final_hash/claude"
assert_contains "Claude denies the final selected runtime" "$lifecycle_roots" "$final_runtime"
assert_eq "Claude does not substitute the temporary render path" "0" \
  "$(grep -cxF "$lifecycle_render" <<<"$lifecycle_roots")"

# The settings that must live at the document's top level. A key after a table header
# belongs to that table — which is right for `".git/"` inside `[permissions.…]` and
# fatal for these four, because Codex then finds no sandbox settings at all. It parsed
# such a file without complaint and reported no hooks, which is how this surfaced.
_IHAR_TOP_LEVEL_KEYS='^(sandbox_mode|approval_policy|default_permissions|model_provider) *='

# assert_toml_order <name> <text> — none of those keys falls after a table header.
assert_toml_order() {
  local name="$1" text="$2" first_table=0 late="" n=0 line
  while IFS= read -r line; do
    n=$((n + 1))
    case "$line" in
      '['*) (( first_table )) || first_table=$n ;;
      *) if (( first_table )) && [[ "$line" =~ $_IHAR_TOP_LEVEL_KEYS ]]; then
           late="${line%% *} at line $n, after the table at line $first_table"
         fi ;;
    esac
  done <<<"$text"
  assert_eq "$name" "" "$late"
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
assert_toml_order "and the assembled file is valid TOML order" "$out"

out="$(render_codex read-only)"
assert_contains "read-only renders read-only" "$out" 'sandbox_mode = "read-only"'
assert_contains "and still names permissions" "$out" 'default_permissions'

out="$(render_codex vendor never)"
assert_contains "--approval changes the approval policy" "$out" 'approval_policy = "never"'
assert_contains "and nothing else" "$out" 'sandbox_mode = "workspace-write"'

# Under a gateway the provider is one decision written as two regions — the selector
# is a bare key and the provider itself is a table — so it is the case the ordering
# broke on first.
render_codex_gateway() {
  local dir="$IHAR_TEST_TMP/render-gw-$RANDOM"
  mkdir -p "$dir"
  IHAR_PROFILE_SANDBOX=vendor IHAR_FLAG_APPROVAL="" \
    IHAR_GATEWAY_MODE=explicit IHAR_GATEWAY_ACTIVE_PORT=41234 \
    IHAR_PROJECT_ROOT="$PROJECT" _ihar_render_codex_config "$dir"
  ihar_render_config_assemble "$dir"
  cat "$dir/config.toml"
}
out="$(render_codex_gateway)"
assert_contains "the gateway selects the ihar provider" "$out" 'model_provider = "ihar"'
assert_contains "and defines it" "$out" 'base_url = "http://127.0.0.1:41234/'
assert_toml_order "with the selector still at the top level" "$out"

# The assertion above would pass on an empty file too, so prove it fails on the shape
# the defect produced: the provider table written before the bare keys. Run in a
# subshell, whose FAIL count is discarded with it.
neg="$( (assert_toml_order "negative" '[model_providers.ihar]
name = "x"
sandbox_mode = "workspace-write"') )"
assert_contains "and the order check rejects a table-first document" "$neg" \
  "FAIL [negative]"

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

# Diff selects the exact desired configuration hash and the gateway port recorded
# for the real gateway key. A newer unrelated runtime must not be compared.
source "$ROOT/lib/render/hooks.sh"
source "$ROOT/lib/store/lockfile.sh"
source "$ROOT/lib/cli/commands.sh"
IHAR_LOCKFILE="$ROOT/.ihar-lockfile.json"; export IHAR_LOCKFILE
IHAR_PROJECT_ROOT="$PROJECT"; export IHAR_PROJECT_ROOT
IHAR_STATE="$CHECK_STATE"; export IHAR_STATE
IHAR_FLAG_PROFILE=protected
ihar_profile_resolve protected
gateway_key="$(ihar_gateway_key)"
mkdir -p "$IHAR_STATE_ROOT/gw/$gateway_key"
printf '41234\n' > "$IHAR_STATE_ROOT/gw/$gateway_key/port"
IHAR_GATEWAY_MODE=explicit IHAR_GATEWAY_ACTIVE_PORT=41234
export IHAR_GATEWAY_MODE IHAR_GATEWAY_ACTIVE_PORT
hooks_digest="$(ihar_manifest_digest)"
registry_digest="$(ihar_registry_digest)"
for vendor in claude codex; do
  expected_hash="$(ihar_config_hash \
    "$IHAR_PROFILE" "$IHAR_PROFILE_MASKING_LEVEL" "$IHAR_PROFILE_GATEWAY" \
    "$IHAR_PROFILE_SANDBOX" "$IHAR_PROFILE_MCP_STRICT" \
    "$hooks_digest" "$registry_digest" "$(ihar_vendor_version "$vendor")")"
  expected_render="$IHAR_TEST_TMP/expected-$vendor"
  ihar_render_all "$vendor" "$expected_render"
  mkdir -p "$CHECK_STATE/r/$expected_hash/$vendor"
  cp -R "$expected_render/." "$CHECK_STATE/r/$expected_hash/$vendor/"
done
mkdir -p "$CHECK_STATE/r/ffffffff/claude" "$CHECK_STATE/r/ffffffff/codex"
printf 'wrong newest\n' > "$CHECK_STATE/r/ffffffff/claude/settings.json"
printf 'wrong newest\n' > "$CHECK_STATE/r/ffffffff/codex/config.toml"
touch "$CHECK_STATE/r/ffffffff"
exact_diff="$(ihar --profile protected check --diff)"
assert_eq "diff uses exact desired runtime and real gateway inputs" "no differences" "$exact_diff"

FAIL_TMP="$IHAR_TEST_TMP/check-failure-temp"
FAIL_PY="$IHAR_TEST_TMP/fail-check-python"
mkdir -p "$FAIL_TMP"
cat > "$FAIL_PY" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"ihar.render.hooks"* || "$*" == *"ihar.check_result collect"* ]]; then exit 3; fi
exec python3 "$@"
EOF
chmod +x "$FAIL_PY"
assert_exit "failed diff reports render failure" 3 \
  env TMPDIR="$FAIL_TMP" IHAR_PY="$FAIL_PY" IHAR_STORE="$IHAR_STORE" IHAR_STATE_ROOT="$IHAR_STATE_ROOT" \
  bash -c "cd '$PROJECT'; '$ROOT/ihar.sh' check --diff"
assert_exit "failed diff removes temporary render directories" 1 \
  compgen -G "$FAIL_TMP/ihar-check-diff-*"
assert_exit "failed collection reports validation failure" 3 \
  env TMPDIR="$FAIL_TMP" IHAR_PY="$FAIL_PY" IHAR_STORE="$IHAR_STORE" IHAR_STATE_ROOT="$IHAR_STATE_ROOT" \
  bash -c "cd '$PROJECT'; '$ROOT/ihar.sh' check"
assert_exit "failed collection removes temporary result files" 1 \
  compgen -G "$FAIL_TMP/ihar-check-result-*"

finish
