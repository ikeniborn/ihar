#!/usr/bin/env bash
# Project state and immutable runtime homes (LLD 2.2, 2.4, 4.1, 4.2, 4.5, 4.6).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
source "$ROOT/lib/core/logging.sh"
source "$ROOT/lib/core/init.sh"
source "$ROOT/lib/core/lock.sh"
source "$ROOT/lib/store/assets.sh"
source "$ROOT/lib/state/state.sh"
source "$ROOT/lib/state/links.sh"
source "$ROOT/lib/state/runtime.sh"
source "$ROOT/lib/render/hooks.sh"
IHAR_CODEX_BIN="$IHAR_TEST_TMP/missing-codex"
source "$ROOT/lib/state/migrate.sh"
source "$ROOT/lib/state/gc.sh"

assert_eq "legacy migration is explicit, never hidden in launch" "1" \
  "$(grep -c 'ihar_migrate_vendor ' "$ROOT/lib/cli/commands.sh")"

IHAR_ROOT="$ROOT"; export IHAR_ROOT
PROJECT="$IHAR_TEST_TMP/My Project"
mkdir -p "$PROJECT"
ihar_asset_install "$IHAR_STORE" >/dev/null
mkdir -p "$IHAR_STORE/auth/claude" "$IHAR_STORE/auth/codex" \
  "$IHAR_STORE/plugins/claude" "$IHAR_STORE/plugins/codex"
printf 'claude auth\n' > "$IHAR_STORE/auth/claude/.credentials.json"
printf 'codex auth\n' > "$IHAR_STORE/auth/codex/auth.json"
printf 'claude plugin\n' > "$IHAR_STORE/plugins/claude/sentinel"
printf 'codex plugin\n' > "$IHAR_STORE/plugins/codex/sentinel"

# --- home id ---------------------------------------------------------------------

id_a="$(ihar_home_id "$PROJECT")"
id_b="$(ihar_home_id "$PROJECT")"
assert_eq "the id is stable for one root" "$id_a" "$id_b"
# The id is the hash alone: the readable basename iclaude prefixes does not fit
# under the Codex socket limit, and the project is read from the marker instead.
assert_eq "the id is eight characters" "8" \
  "$(printf '%s' "$id_a" | wc -c | awk '{print $1-0}')"
assert_exit "the id is lowercase hex" 0 \
  bash -c "[[ '$id_a' =~ ^[0-9a-f]{8}$ ]]"

other="$(ihar_home_id "$IHAR_TEST_TMP/other")"
assert_exit "a different root gets a different id" 1 test "$id_a" = "$other"

upper="$(ihar_home_id "$IHAR_TEST_TMP/UPPER!!Case")"
assert_exit "an awkward basename still yields a clean id" 0 \
  bash -c "[[ '$upper' =~ ^[0-9a-f]{8}$ ]]"

# --- socket path preflight -------------------------------------------------------

assert_exit "a short state path passes the preflight" 0 \
  ihar_state_preflight "$IHAR_TEST_TMP/s"

long="$IHAR_TEST_TMP/$(printf 'x%.0s' {1..120})"
assert_exit "a state path that overflows the socket limit is refused" 2 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/state/state.sh'
           IHAR_SOCKET_PATH_MAX=100 ihar_state_preflight '$long'"

# This layout exists to fit this path. The readable id of LLD revision 3 measured
# 120 bytes against a usable sun_path of 107, which is why the id is a bare hash and
# the runtime segment is one character.
default_socket="$HOME/.local/state/ihar/$id_a/r/00000000/codex/app-server-control/app-server-control.sock"
assert_exit "the default layout fits a Codex daemon socket" 0 \
  test "${#default_socket}" -le 107
assert_exit "and it clears the preflight" 0 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/state/state.sh'
           ihar_state_preflight '$HOME/.local/state/ihar/$id_a'"

# --- state tree and marker -------------------------------------------------------

STATE="$(ihar_state_setup "$PROJECT")"
assert_exit "the state tree is created" 0 test -d "$STATE/st/claude"
assert_exit "the runtime parent is created" 0 test -d "$STATE/r"
assert_exit "the marker is written" 0 test -f "$STATE/home.json"

marker_root="$(ihar_python ihar.state_marker --read "$STATE/home.json")"
assert_eq "the marker records the project" "$PROJECT" "$marker_root"
assert_eq "the marker validates as schema 3" "3" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["schema"])' "$STATE/home.json")"

assert_exit "setup is idempotent" 0 ihar_state_setup "$PROJECT"

# A marker naming another project means two roots collided or the file moved;
# guessing would attach a session to the wrong project.
python3 - "$STATE/home.json" <<'PY'
import json, sys
path = sys.argv[1]
marker = json.load(open(path))
marker["project_root"] = "/somewhere/else"
json.dump(marker, open(path, "w"))
PY
assert_exit "a marker naming another project aborts" 1 \
  ihar_python ihar.state_marker "$STATE/home.json" "$PROJECT"
rm -rf "$STATE"
STATE="$(ihar_state_setup "$PROJECT")"

# --- schema upgrade ---------------------------------------------------------------

printf '{"schema":1,"project_root":"%s","created":"2026-01-01T00:00:00Z"}\n' "$PROJECT" \
  > "$STATE/home.json"
assert_exit "a schema 1 marker upgrades in place" 0 \
  ihar_python ihar.state_marker "$STATE/home.json" "$PROJECT"
assert_eq "the upgraded marker keeps its creation date" "2026-01-01T00:00:00Z" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["created"])' "$STATE/home.json")"
assert_eq "the upgraded marker is schema 3" "3" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["schema"])' "$STATE/home.json")"

# --- configuration hash ------------------------------------------------------------

h1="$(ihar_config_hash protected standard explicit vendor true aaa bbb 2.1.274 mcp)"
h2="$(ihar_config_hash protected standard explicit vendor true aaa bbb 2.1.274 mcp)"
assert_eq "the hash is deterministic" "$h1" "$h2"
assert_eq "the hash is eight characters" "8" "$(printf '%s' "$h1" | wc -c | awk '{print $1-0}')"

h3="$(ihar_config_hash standard off off vendor-default false aaa bbb 2.1.274 mcp)"
assert_exit "a different profile yields a different hash" 1 test "$h1" = "$h3"
h4="$(ihar_config_hash protected secrets explicit vendor true aaa bbb 2.1.274 mcp)"
assert_exit "a different masking level yields a different hash" 1 test "$h1" = "$h4"
h5="$(ihar_config_hash protected standard explicit vendor true aaa bbb 2.1.999 mcp)"
assert_exit "a different vendor version yields a different hash" 1 test "$h1" = "$h5"

# The registry bytes stay fixed while requires_env changes the selected server set.
IHAR_PROFILE=standard
export IHAR_PROFILE
unset IWIKI_REMOTE_TOKEN
for vendor in claude codex; do
  absent_identity="$(IHAR_IWIKI_REMOTE_URL=https://wiki.example/mcp \
    ihar_effective_mcp_identity "$vendor")"
  present_identity="$(IHAR_IWIKI_REMOTE_URL=https://wiki.example/mcp \
    IWIKI_REMOTE_TOKEN=synthetic ihar_effective_mcp_identity "$vendor")"
  changed_value_identity="$(IHAR_IWIKI_REMOTE_URL=https://wiki.example/mcp \
    IWIKI_REMOTE_TOKEN=other-synthetic ihar_effective_mcp_identity "$vendor")"
  absent_hash="$(ihar_config_hash standard off off vendor-default false aaa bbb 2.1.274 "$absent_identity")"
  present_hash="$(ihar_config_hash standard off off vendor-default false aaa bbb 2.1.274 "$present_identity")"
  changed_value_hash="$(ihar_config_hash standard off off vendor-default false aaa bbb 2.1.274 "$changed_value_identity")"
  assert_exit "$vendor required environment presence selects a generation" 1 \
    test "$absent_hash" = "$present_hash"
  assert_eq "$vendor secret value does not select a generation" \
    "$present_hash" "$changed_value_hash"
done

ASSET_HASH_ROOT="$IHAR_TEST_TMP/asset-hash-root"
ASSET_HASH_STORE="$IHAR_TEST_TMP/asset-hash-store"
ASSET_HASH_STATE="$IHAR_TEST_TMP/asset-hash-state"
mkdir -p "$ASSET_HASH_ROOT/manifests" "$ASSET_HASH_STORE" \
  "$ASSET_HASH_STATE/r" "$ASSET_HASH_STATE/st/claude"
ln -s "$ROOT/lib" "$ASSET_HASH_ROOT/lib"
cp "$ROOT/manifests/state.json" "$ASSET_HASH_ROOT/manifests/state.json"
printf '%s\n' '{"schema":1,"entries":[]}' \
  > "$ASSET_HASH_ROOT/manifests/mutable-links.json"
cat > "$ASSET_HASH_ROOT/manifests/assets.json" <<'JSON'
{"schema":1,"entries":[{"vendor":"common","source":"optional/tools","target":"tools","kind":"directory","required":false,"runtime":true}]}
JSON
asset_hash_missing="$(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  ihar_config_hash asset identity optional source a b c d mcp)"
asset_runtime_missing="$(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  IHAR_STATE="$ASSET_HASH_STATE" ihar_runtime_materialise claude "$asset_hash_missing")"
assert_exit "an absent optional store source is absent from its generation" 1 \
  test -e "$asset_runtime_missing/tools"

# Wrong-kind and symlinked optional sources are distinct store topologies, but
# neither is eligible for linking into a runtime.
mkdir -p "$ASSET_HASH_STORE/optional"
printf 'wrong kind\n' > "$ASSET_HASH_STORE/optional/tools"
asset_hash_wrong_kind="$(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  ihar_config_hash asset identity optional source a b c d mcp)"
assert_exit "an optional wrong-kind store source has a distinct generation" 1 \
  test "$asset_hash_missing" = "$asset_hash_wrong_kind"
asset_runtime_wrong_kind="$(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  IHAR_STATE="$ASSET_HASH_STATE" ihar_runtime_materialise claude "$asset_hash_wrong_kind")"
assert_exit "an optional wrong-kind store source is not linked" 1 \
  test -e "$asset_runtime_wrong_kind/tools"

rm -rf "$ASSET_HASH_STORE/optional"
mkdir -p "$ASSET_HASH_STORE/outside-optional/tools"
ln -s "$ASSET_HASH_STORE/outside-optional" "$ASSET_HASH_STORE/optional"
asset_hash_symlink="$(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  ihar_config_hash asset identity optional source a b c d mcp)"
assert_exit "a symlinked optional store parent has a distinct generation" 1 \
  test "$asset_hash_wrong_kind" = "$asset_hash_symlink"
asset_runtime_symlink="$(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  IHAR_STATE="$ASSET_HASH_STATE" ihar_runtime_materialise claude "$asset_hash_symlink")"
assert_exit "an optional source behind a symlinked parent is not linked" 1 \
  test -e "$asset_runtime_symlink/tools"
rm "$ASSET_HASH_STORE/optional"

# A repository source appearing before install does not change the actual topology
# the runtime linker sees. Publishing it into the store does, and must choose a new
# generation rather than silently reuse the link-less one.
mkdir -p "$ASSET_HASH_ROOT/optional/tools"
asset_hash_before_install="$(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  ihar_config_hash asset identity optional source a b c d mcp)"
assert_eq "repository presence alone does not change runtime asset identity" \
  "$asset_hash_missing" "$asset_hash_before_install"
IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  ihar_asset_install "$ASSET_HASH_STORE" >/dev/null
asset_hash_present="$(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  ihar_config_hash asset identity optional source a b c d mcp)"
assert_exit "an optional store asset becoming available selects a new generation" 1 \
  test "$asset_hash_missing" = "$asset_hash_present"
assert_exit "an optional correct-kind store source differs from wrong kind" 1 \
  test "$asset_hash_wrong_kind" = "$asset_hash_present"
assert_exit "an optional correct-kind source differs from symlinked topology" 1 \
  test "$asset_hash_symlink" = "$asset_hash_present"
asset_runtime_present="$(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  IHAR_STATE="$ASSET_HASH_STATE" ihar_runtime_materialise claude "$asset_hash_present")"
assert_exit "the optional asset generation is distinct" 1 \
  test "$asset_runtime_missing" = "$asset_runtime_present"
assert_eq "the optional asset generation links the installed source" \
  "$ASSET_HASH_STORE/optional/tools" "$(readlink "$asset_runtime_present/tools")"

python3 - "$ASSET_HASH_ROOT/manifests/assets.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path, encoding="utf-8"))
document["entries"].append({
    "vendor": "claude", "source": "required/new.txt", "target": "new.txt",
    "kind": "file", "required": True, "runtime": True,
})
json.dump(document, open(path, "w", encoding="utf-8"))
PY
mkdir -p "$ASSET_HASH_ROOT/required"
printf 'required\n' > "$ASSET_HASH_ROOT/required/new.txt"
asset_hash_required_absent="$(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  ihar_config_hash asset identity optional source a b c d mcp)"
required_absent_runtime="$IHAR_TEST_TMP/required-absent-runtime"
mkdir -p "$required_absent_runtime"
printf 'runtime stays\n' > "$required_absent_runtime/sentinel"
required_absent_status=0
(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  ihar_link_runtime claude "$required_absent_runtime" "$ASSET_HASH_STATE") \
  >/dev/null 2>&1 || required_absent_status=$?
assert_eq "an absent required store source fails closed" "3" "$required_absent_status"
assert_exit "required absence mutates no earlier optional target" 1 \
  test -e "$required_absent_runtime/tools"
assert_eq "required absence preserves existing runtime bytes" "runtime stays" \
  "$(cat "$required_absent_runtime/sentinel")"

mkdir -p "$ASSET_HASH_STORE/required/new.txt"
asset_hash_required_wrong="$(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  ihar_config_hash asset identity optional source a b c d mcp)"
assert_exit "a required wrong-kind store source has a distinct generation" 1 \
  test "$asset_hash_required_absent" = "$asset_hash_required_wrong"
required_wrong_runtime="$IHAR_TEST_TMP/required-wrong-runtime"
mkdir -p "$required_wrong_runtime"
printf 'runtime stays\n' > "$required_wrong_runtime/sentinel"
required_wrong_status=0
(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  ihar_link_runtime claude "$required_wrong_runtime" "$ASSET_HASH_STATE") \
  >/dev/null 2>&1 || required_wrong_status=$?
assert_eq "a wrong-kind required store source fails closed" "3" "$required_wrong_status"
assert_exit "required wrong kind mutates no earlier optional target" 1 \
  test -e "$required_wrong_runtime/tools"
assert_eq "required wrong kind preserves existing runtime bytes" "runtime stays" \
  "$(cat "$required_wrong_runtime/sentinel")"
required_wrong_materialise_status=0
(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  IHAR_STATE="$ASSET_HASH_STATE" \
  ihar_runtime_materialise claude "$asset_hash_required_wrong") \
  >/dev/null 2>&1 || required_wrong_materialise_status=$?
assert_eq "required wrong kind aborts runtime materialisation" \
  "3" "$required_wrong_materialise_status"
assert_exit "required wrong kind creates no runtime generation" 1 \
  test -e "$ASSET_HASH_STATE/r/$asset_hash_required_wrong"
assert_eq "required wrong kind creates no runtime staging tree" "0" \
  "$(find "$ASSET_HASH_STATE/r" -maxdepth 1 -type d -name '.staging-*' | wc -l)"

# Invalid required assets must be rejected before a legacy materialized owner is
# migrated into canonical state or rewritten as a link.
required_owner="$ASSET_HASH_STATE/r/legacy-owner/claude"
mkdir -p "$required_owner"
printf 'legacy history\n' > "$required_owner/.claude.json"
required_owner_before="$(sha256sum "$required_owner/.claude.json" | cut -d' ' -f1)"
required_owner_status=0
(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  IHAR_STATE="$ASSET_HASH_STATE" \
  ihar_runtime_materialise claude "$asset_hash_required_wrong") \
  >/dev/null 2>&1 || required_owner_status=$?
assert_eq "required wrong kind rejects before state migration" "3" "$required_owner_status"
assert_exit "required asset rejection preserves materialized owner kind" 0 \
  test -f "$required_owner/.claude.json"
assert_eq "required asset rejection preserves materialized owner bytes" \
  "$required_owner_before" "$(sha256sum "$required_owner/.claude.json" | cut -d' ' -f1)"
assert_exit "required asset rejection publishes no canonical history" 1 \
  test -e "$ASSET_HASH_STATE/st/claude/.claude.json"
assert_eq "required asset rejection creates no recovery state" "0" \
  "$(find "$ASSET_HASH_STATE/recovery" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
rm -rf "$required_owner"

rm -rf "$ASSET_HASH_STORE/required/new.txt"
IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  ihar_asset_install "$ASSET_HASH_STORE" >/dev/null
asset_hash_required_added="$(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  ihar_config_hash asset identity optional source a b c d mcp)"
assert_exit "a required runtime asset addition selects a new generation" 1 \
  test "$asset_hash_present" = "$asset_hash_required_added"
assert_exit "a required correct-kind store source differs from wrong kind" 1 \
  test "$asset_hash_required_wrong" = "$asset_hash_required_added"
assert_exit "a required correct-kind store source differs from absence" 1 \
  test "$asset_hash_required_absent" = "$asset_hash_required_added"
asset_runtime_required="$(IHAR_ROOT="$ASSET_HASH_ROOT" IHAR_STORE="$ASSET_HASH_STORE" \
  IHAR_STATE="$ASSET_HASH_STATE" ihar_runtime_materialise claude "$asset_hash_required_added")"
assert_eq "the required asset generation links the installed source" \
  "$ASSET_HASH_STORE/required/new.txt" "$(readlink "$asset_runtime_required/new.txt")"

assert_exit "a wrong input count is a usage error" 2 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/state/runtime.sh'
           ihar_config_hash one two"

# --- runtime materialisation --------------------------------------------------------

RENDER="$IHAR_TEST_TMP/render"
mkdir -p "$RENDER"
printf '{"rendered":true}\n' > "$RENDER/settings.json"

rt="$(ihar_runtime_materialise claude "$h1" "$RENDER")"
assert_exit "the runtime home is published" 0 test -d "$rt"
assert_exit "the render is present" 0 test -f "$rt/settings.json"
assert_eq "an immutable runtime file is read-only" "444" \
  "$(stat -c '%a' "$rt/settings.json")"
staging_left="$(find "$STATE/r" -maxdepth 1 -name '.staging-*' | wc -l)"
assert_eq "no staging directory is left behind" "0" "$staging_left"

# A second launch of the same configuration reuses the directory rather than
# rewriting it: that reuse is what removes the last-writer-wins window.
inode_before="$(stat -c '%i' "$rt/settings.json")"
rt_again="$(ihar_runtime_materialise claude "$h1" "$RENDER")"
assert_eq "the same configuration reuses its home" "$rt" "$rt_again"
assert_eq "the existing render is left untouched" "$inode_before" \
  "$(stat -c '%i' "$rt/settings.json")"

# Two profiles are two directories, so neither can overwrite the other.
rt_other="$(ihar_runtime_materialise claude "$h3" "$RENDER")"
assert_exit "a different configuration gets its own home" 1 test "$rt" = "$rt_other"
assert_exit "the first home still exists" 0 test -f "$rt/settings.json"

# Drift between the hash and the content means one of them is wrong.
printf '{"rendered":"changed"}\n' > "$RENDER/settings.json"
assert_exit "a drifted runtime home is fail-closed" 3 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/lock.sh'
           source '$ROOT/lib/state/links.sh'; source '$ROOT/lib/state/runtime.sh'
           IHAR_STATE='$STATE' IHAR_STORE='$IHAR_STORE' ihar_runtime_materialise claude '$h1' '$RENDER'"
printf '{"rendered":true}\n' > "$RENDER/settings.json"

# A render the existing home lacks entirely is the same defect.
printf 'x\n' > "$RENDER/extra.json"
assert_exit "a missing rendered file is fail-closed" 3 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/lock.sh'
           source '$ROOT/lib/state/links.sh'; source '$ROOT/lib/state/runtime.sh'
           IHAR_STATE='$STATE' IHAR_STORE='$IHAR_STORE' ihar_runtime_materialise claude '$h1' '$RENDER'"
rm -f "$RENDER/extra.json"

writable="$(ihar_runtime_materialise codex "$h3" "$RENDER" writable)"
assert_eq "a writable runtime file stays owner-only" "600" \
  "$(stat -c '%a' "$writable/settings.json")"

# The seal covers what ihar rendered, and nothing else. Sealing runs an app-server
# against the published home and Codex initialises its own sqlite state there; a
# blanket chmod made that read-only and the next launch aborted with "failed to
# initialize sqlite state runtime", so hook verification could never pass.
ihar_seal_runtime() { printf 'vendor state\n' > "$2/logs_2.sqlite"; }
sealed="$(ihar_runtime_materialise claude "$(ihar_config_hash s e a l e d 1 2 mcp)" "$RENDER")"
unset -f ihar_seal_runtime
assert_eq "the seal covers the rendered files" "444" \
  "$(stat -c '%a' "$sealed/settings.json")"
# Writability, not an exact mode: the umask decides the group and other bits.
assert_exit "and leaves vendor-written state writable" 0 test -w "$sealed/logs_2.sqlite"

# --- links -------------------------------------------------------------------------

rt2_hash="$(ihar_config_hash a b c d e f g h mcp)"
rt2="$(ihar_runtime_materialise claude "$rt2_hash" "$RENDER")"
assert_exit "a present store entry is linked" 0 test -L "$rt2/skills"
assert_exit "an absent store entry is skipped" 1 test -e "$rt2/router.json"
assert_eq "Claude auth links to the global store" \
  "$IHAR_STORE/auth/claude/.credentials.json" "$(readlink "$rt2/.credentials.json")"
assert_eq "Claude plugins link to the global store" \
  "$IHAR_STORE/plugins/claude" "$(readlink "$rt2/plugins")"
assert_exit "vendor state is linked out of the runtime home" 0 test -L "$rt2/projects"
assert_eq "vendor state resolves into st/" "$STATE/st/claude/projects" \
  "$(readlink "$rt2/projects")"

rm "$rt2/projects"
rmdir "$STATE/st/claude/projects"
ln -s "$STATE/st/claude/projects" "$rt2/projects"
ihar_runtime_materialise claude "$rt2_hash" "$RENDER" >/dev/null
assert_exit "runtime reuse creates the source for a correct dangling directory link" 0 \
  test -d "$STATE/st/claude/projects"
assert_eq "runtime reuse keeps the correct directory link" \
  "$STATE/st/claude/projects" "$(readlink "$rt2/projects")"
mkdir -p "$STATE/st/claude/projects"

# Reusing an already-published runtime verifies rendered files first, then verifies
# every manifest-derived state link. Missing links are created; unsafe entries are
# preserved and rejected, so canonical state is never populated from a runtime fork.
printf 'canonical directory\n' > "$STATE/st/claude/projects/canonical"
rm "$rt2/projects"
ihar_runtime_materialise claude "$rt2_hash" "$RENDER" >/dev/null
assert_eq "runtime reuse restores a missing state directory link" \
  "$STATE/st/claude/projects" "$(readlink "$rt2/projects")"

printf 'canonical file\n' > "$STATE/st/claude/history.jsonl"
WRONG_STATE_TARGET="$IHAR_TEST_TMP/wrong-state-target"
printf 'wrong target stays intact\n' > "$WRONG_STATE_TARGET"
ln -sfn "$WRONG_STATE_TARGET" "$rt2/history.jsonl"
wrong_state_status=0
wrong_state_out="$(ihar_runtime_materialise claude "$rt2_hash" "$RENDER" 2>&1)" \
  || wrong_state_status=$?
assert_eq "runtime reuse rejects a wrong state symlink" "3" "$wrong_state_status"
assert_contains "wrong state link diagnostics give an explicit recovery step" \
  "$wrong_state_out" "remove or recover the wrong link"
assert_eq "runtime reuse preserves the wrong state symlink target" \
  "$WRONG_STATE_TARGET" "$(readlink "$rt2/history.jsonl")"
assert_eq "rejecting a wrong state link preserves its referent" "wrong target stays intact" \
  "$(cat "$WRONG_STATE_TARGET")"
rm -f "$rt2/history.jsonl"
ln -s "$STATE/st/claude/history.jsonl" "$rt2/history.jsonl"

printf 'canonical dotfile\n' > "$STATE/st/claude/.claude.json"
rm "$rt2/.claude.json"
printf 'materialised runtime file\n' > "$rt2/.claude.json"
materialised_file_before="$(sha256sum "$rt2/.claude.json" | cut -d' ' -f1)"
materialised_file_status=0
materialised_file_out="$(ihar_runtime_materialise claude "$rt2_hash" "$RENDER" 2>&1)" \
  || materialised_file_status=$?
assert_eq "runtime reuse rejects a materialised state file" "3" "$materialised_file_status"
assert_contains "materialised state diagnostics give an explicit recovery step" \
  "$materialised_file_out" "move it to a recovery location"
assert_exit "a rejected materialised state file remains a regular file" 0 \
  test -f "$rt2/.claude.json"
assert_exit "a rejected materialised state file is not replaced by a link" 1 \
  test -L "$rt2/.claude.json"
assert_eq "a rejected materialised state file stays byte-identical" \
  "$materialised_file_before" "$(sha256sum "$rt2/.claude.json" 2>/dev/null | cut -d' ' -f1)"
assert_eq "materialised-file rejection preserves canonical state" "canonical dotfile" \
  "$(cat "$STATE/st/claude/.claude.json")"
rm -f "$rt2/.claude.json"
ln -s "$STATE/st/claude/.claude.json" "$rt2/.claude.json"

printf 'canonical session\n' > "$STATE/st/claude/sessions/canonical"
rm "$rt2/sessions"
mkdir "$rt2/sessions"
printf 'forked runtime state\n' > "$rt2/sessions/forked"
materialised_dir_status=0
materialised_dir_out="$(ihar_runtime_materialise claude "$rt2_hash" "$RENDER" 2>&1)" \
  || materialised_dir_status=$?
assert_eq "runtime reuse rejects a materialised state directory" "3" "$materialised_dir_status"
assert_contains "materialised directory diagnostics identify the preserved entry" \
  "$materialised_dir_out" "$rt2/sessions"
assert_exit "a rejected materialised state directory remains a directory" 0 \
  test -d "$rt2/sessions"
assert_exit "a rejected materialised state directory is not replaced by a link" 1 \
  test -L "$rt2/sessions"
assert_eq "a rejected materialised state directory stays byte-identical" \
  "forked runtime state" "$(cat "$rt2/sessions/forked")"
assert_eq "materialised-directory rejection preserves canonical content" "canonical session" \
  "$(cat "$STATE/st/claude/sessions/canonical")"
assert_exit "rejected runtime-fork content never reaches canonical state" 1 \
  test -e "$STATE/st/claude/sessions/forked"
rm -rf "$rt2/sessions"
ln -s "$STATE/st/claude/sessions" "$rt2/sessions"

# Runtime reuse verifies every manifest-derived store link before it reconciles
# persistent state. Hooks are required security assets: absence, a wrong target, or
# a materialised copy must abort without repairing either asset or state paths.
rm "$rt2/hooks" "$rt2/projects"
missing_hook_status=0
missing_hook_out="$(ihar_runtime_materialise claude "$rt2_hash" "$RENDER" 2>&1)" \
  || missing_hook_status=$?
assert_eq "runtime reuse rejects a missing required hooks link" "3" "$missing_hook_status"
assert_contains "missing required hooks are diagnosed" "$missing_hook_out" \
  "required runtime asset link is missing"
assert_exit "a rejected missing hooks link is not repaired" 1 test -e "$rt2/hooks"
assert_exit "asset rejection happens before state link restoration" 1 test -L "$rt2/projects"
ln -s "$IHAR_STORE/hooks" "$rt2/hooks"
ln -s "$STATE/st/claude/projects" "$rt2/projects"

# Mutable auth and plugin links preserve one machine-global owner across runtime
# reuse and profile changes. Missing links are repaired, but existing runtime data
# is never replaced because it may be the only copy from an older layout.
rm "$rt2/.credentials.json"
ihar_runtime_materialise claude "$rt2_hash" "$RENDER" >/dev/null
assert_eq "runtime reuse restores a missing mutable auth link" \
  "$IHAR_STORE/auth/claude/.credentials.json" "$(readlink "$rt2/.credentials.json")"

rm "$rt2/.credentials.json"
printf 'runtime-only auth\n' > "$rt2/.credentials.json"
mutable_auth_status=0
mutable_auth_out="$(ihar_runtime_materialise claude "$rt2_hash" "$RENDER" 2>&1)" \
  || mutable_auth_status=$?
assert_eq "runtime reuse rejects materialised mutable auth" "3" "$mutable_auth_status"
assert_contains "materialised mutable auth gives a recovery instruction" \
  "$mutable_auth_out" "move it to a recovery location"
assert_eq "materialised mutable auth is preserved" "runtime-only auth" \
  "$(cat "$rt2/.credentials.json")"
assert_eq "canonical mutable auth is preserved" "claude auth" \
  "$(cat "$IHAR_STORE/auth/claude/.credentials.json")"
rm "$rt2/.credentials.json"
ln -s "$IHAR_STORE/auth/claude/.credentials.json" "$rt2/.credentials.json"

profile_runtime="$(ihar_runtime_materialise claude \
  "$(ihar_config_hash mutable links cross profile a b c d mcp)" "$RENDER")"
assert_eq "another profile shares the same mutable auth owner" \
  "$IHAR_STORE/auth/claude/.credentials.json" \
  "$(readlink "$profile_runtime/.credentials.json")"
assert_eq "another profile shares the same plugin owner" \
  "$IHAR_STORE/plugins/claude" "$(readlink "$profile_runtime/plugins")"
assert_eq "auth written through one profile reaches the other" "profile update" \
  "$(printf 'profile update\n' > "$rt2/.credentials.json"; cat "$profile_runtime/.credentials.json")"

codex_mutable_runtime="$(ihar_runtime_materialise codex \
  "$(ihar_config_hash mutable links codex inventory a b c d mcp)" "$RENDER")"
assert_eq "Codex auth links to the global store" "$IHAR_STORE/auth/codex/auth.json" \
  "$(readlink "$codex_mutable_runtime/auth.json")"
assert_eq "Codex plugins link to the global store" "$IHAR_STORE/plugins/codex" \
  "$(readlink "$codex_mutable_runtime/plugins")"

INVALID_MUTABLE_ROOT="$IHAR_TEST_TMP/invalid-mutable-root"
INVALID_MUTABLE_RUNTIME="$IHAR_TEST_TMP/invalid-mutable-runtime"
mkdir -p "$INVALID_MUTABLE_ROOT/manifests" "$INVALID_MUTABLE_RUNTIME"
ln -s "$ROOT/lib" "$INVALID_MUTABLE_ROOT/lib"
cp "$ROOT/manifests/assets.json" "$INVALID_MUTABLE_ROOT/manifests/assets.json"
cp "$ROOT/manifests/state.json" "$INVALID_MUTABLE_ROOT/manifests/state.json"
printf 'not valid JSON\n' > "$INVALID_MUTABLE_ROOT/manifests/mutable-links.json"
printf 'runtime auth stays\n' > "$INVALID_MUTABLE_RUNTIME/auth.json"
invalid_mutable_status=0
invalid_mutable_out="$(IHAR_ROOT="$INVALID_MUTABLE_ROOT" \
  ihar_link_runtime codex "$INVALID_MUTABLE_RUNTIME" "$STATE" 2>&1)" \
  || invalid_mutable_status=$?
assert_eq "an invalid mutable inventory aborts linking" "3" "$invalid_mutable_status"
assert_contains "an invalid mutable inventory is diagnosed" "$invalid_mutable_out" \
  "cannot read mutable-link inventory"
assert_eq "an invalid mutable inventory preserves runtime auth" "runtime auth stays" \
  "$(cat "$INVALID_MUTABLE_RUNTIME/auth.json")"

runtime_mutable_tree_fingerprint() { # <root>
  local root="$1"
  {
    find "$root" -mindepth 1 -printf '%P\t%y\t%m\t%l\n' | sort
    find "$root" -type f -print0 | sort -z | xargs -0 -r sha256sum
  } | sha256sum | cut -d' ' -f1
}

write_noncanonical_runtime_manifest() { # <path> <case>
  local path="$1" case_name="$2"
  case "$case_name" in
    auth-dot)
      printf '%s\n' '{"schema":1,"entries":[{"vendor":"claude","source":"auth/claude/.","target":".credentials.json","kind":"file"}]}' > "$path"
      ;;
    duplicate-plugin-target)
      printf '%s\n' '{"schema":1,"entries":[{"vendor":"claude","source":"auth/claude/one","target":"plugins","kind":"file"},{"vendor":"claude","source":"auth/claude/two","target":"plugins/.","kind":"file"}]}' > "$path"
      ;;
    repeated-separator)
      printf '%s\n' '{"schema":1,"entries":[{"vendor":"claude","source":"auth//claude/.credentials.json","target":".credentials.json","kind":"file"}]}' > "$path"
      ;;
    trailing-separator)
      printf '%s\n' '{"schema":1,"entries":[{"vendor":"claude","source":"auth/claude/.credentials.json","target":"plugins/","kind":"file"}]}' > "$path"
      ;;
  esac
}

assert_runtime_rejects_noncanonical_mutable_path() { # <case>
  local case_name="$1" case_root store runtime state store_before runtime_before status=0
  case_root="$IHAR_TEST_TMP/runtime-mutable-path-$case_name"
  store="$case_root/store"
  runtime="$case_root/runtime"
  state="$case_root/state"
  mkdir -p "$case_root/root/manifests" "$store" "$runtime" "$state"
  ln -s "$ROOT/lib" "$case_root/root/lib"
  cp "$ROOT/manifests/assets.json" "$case_root/root/manifests/assets.json"
  cp "$ROOT/manifests/state.json" "$case_root/root/manifests/state.json"
  write_noncanonical_runtime_manifest \
    "$case_root/root/manifests/mutable-links.json" "$case_name"
  ihar_asset_install "$store" >/dev/null
  printf 'store stays\n' > "$store/sentinel"
  printf 'runtime stays\n' > "$runtime/sentinel"

  store_before="$(runtime_mutable_tree_fingerprint "$store")"
  runtime_before="$(runtime_mutable_tree_fingerprint "$runtime")"
  (IHAR_ROOT="$case_root/root" IHAR_STORE="$store" \
    ihar_link_runtime claude "$runtime" "$state") >/dev/null 2>&1 || status=$?
  assert_eq "$case_name mutable path aborts runtime linking" "3" "$status"
  assert_eq "$case_name mutable path leaves the store unchanged" \
    "$store_before" "$(runtime_mutable_tree_fingerprint "$store")"
  assert_eq "$case_name mutable path leaves the runtime unchanged" \
    "$runtime_before" "$(runtime_mutable_tree_fingerprint "$runtime")"
}

for case_name in auth-dot duplicate-plugin-target repeated-separator trailing-separator; do
  assert_runtime_rejects_noncanonical_mutable_path "$case_name"
done

assert_runtime_rejects_invalid_mutable_source() { # <topology>
  local topology="$1" case_root store outside runtime state outside_before status=0
  case_root="$IHAR_TEST_TMP/runtime-mutable-$topology"
  store="$case_root/store"
  outside="$case_root/outside"
  runtime="$case_root/runtime"
  state="$case_root/state"
  mkdir -p "$store" "$outside" "$runtime" "$state"
  ihar_asset_install "$store" >/dev/null
  printf 'outside stays\n' > "$outside/sentinel"

  case "$topology" in
    auth-parent-symlink)
      ln -s "$outside" "$store/auth"
      ;;
    auth-leaf-symlink)
      mkdir -p "$store/auth/claude"
      ln -s "$outside/sentinel" "$store/auth/claude/.credentials.json"
      ;;
    credentials-directory)
      mkdir -p "$store/auth/claude/.credentials.json"
      ;;
    plugin-file)
      mkdir -p "$store/plugins"
      printf 'plugin file stays\n' > "$store/plugins/claude"
      ;;
  esac

  outside_before="$(runtime_mutable_tree_fingerprint "$outside")"
  (IHAR_STORE="$store" ihar_link_runtime claude "$runtime" "$state") \
    >/dev/null 2>&1 || status=$?
  assert_eq "$topology mutable source aborts runtime linking" "3" "$status"
  assert_eq "$topology failure creates no runtime link" "0" \
    "$(find "$runtime" -mindepth 1 | wc -l)"
  assert_eq "$topology runtime failure leaves outside unchanged" \
    "$outside_before" "$(runtime_mutable_tree_fingerprint "$outside")"
}

for topology in auth-parent-symlink auth-leaf-symlink credentials-directory plugin-file; do
  assert_runtime_rejects_invalid_mutable_source "$topology"
done

EXPECTED_RUNTIME_ASSETS="$(cat <<'ASSETS'
claude	hooks	hooks	directory	true
claude	skills	skills	directory	true
claude	manifests/config/claude/CLAUDE.md	CLAUDE.md	file	true
claude	manifests/config/claude/commands	commands	directory	false
claude	manifests/config/claude/agents	agents	directory	false
claude	manifests/config/claude/scripts	scripts	directory	false
codex	hooks	hooks	directory	true
codex	skills	skills	directory	true
codex	manifests/config/codex/AGENTS.md	AGENTS.md	file	true
codex	manifests/config/codex/rules	rules	directory	false
codex	manifests/config/codex/agents	agents	directory	false
codex	manifests/config/codex/profiles	profiles	directory	false
ASSETS
)"

# The mutation matrix is a reviewed expectation, not output from the production
# inventory query. Direct JSON comparison makes a manifest addition fail until its
# reuse-tampering cases are added here.
manifest_runtime_assets="$(python3 - "$ROOT/manifests/assets.json" <<'PY'
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in document["entries"]:
    if not entry["runtime"]:
        continue
    vendors = ("claude", "codex") if entry["vendor"] == "common" else (entry["vendor"],)
    for vendor in vendors:
        print("\t".join((vendor, entry["source"], entry["target"], entry["kind"],
                         str(entry["required"]).lower())))
PY
)"
assert_eq "the independent reuse matrix covers every runtime asset" \
  "$(sort <<< "$EXPECTED_RUNTIME_ASSETS")" "$(sort <<< "$manifest_runtime_assets")"

asset_codex_hash="$(ihar_config_hash asset reuse codex matrix a b c d mcp)"
asset_codex_runtime="$(ihar_runtime_materialise codex "$asset_codex_hash" "$RENDER")"
WRONG_STORE_TARGET="$IHAR_TEST_TMP/wrong-store-target"
mkdir -p "$WRONG_STORE_TARGET"
printf 'store target stays intact\n' > "$WRONG_STORE_TARGET/sentinel"

while IFS=$'\t' read -r asset_vendor asset_source asset_target asset_kind asset_required; do
  [[ -n "$asset_vendor" ]] || continue
  if [[ "$asset_vendor" == claude ]]; then
    asset_runtime="$rt2"
    asset_hash="$rt2_hash"
  else
    asset_runtime="$asset_codex_runtime"
    asset_hash="$asset_codex_hash"
  fi
  asset_source_path="$IHAR_STORE/$asset_source"
  asset_target_path="$asset_runtime/$asset_target"

  if [[ "$asset_required" == false ]]; then
    case "$asset_kind" in
      directory) mkdir -p "$asset_source_path" ;;
      file) mkdir -p "$(dirname "$asset_source_path")"; : > "$asset_source_path" ;;
    esac
    assert_exit "$asset_vendor optional $asset_target may be absent on reuse" 0 \
      ihar_runtime_materialise "$asset_vendor" "$asset_hash" "$RENDER"
  fi

  rm -rf -- "$asset_target_path"
  ln -s "$WRONG_STORE_TARGET" "$asset_target_path"
  wrong_asset_status=0
  wrong_asset_out="$(ihar_runtime_materialise "$asset_vendor" "$asset_hash" "$RENDER" 2>&1)" \
    || wrong_asset_status=$?
  assert_eq "$asset_vendor $asset_target wrong runtime asset link is rejected" \
    "3" "$wrong_asset_status"
  assert_contains "$asset_vendor $asset_target wrong-link diagnostic identifies target" \
    "$wrong_asset_out" "$asset_target_path"
  assert_eq "$asset_vendor $asset_target wrong link is preserved" \
    "$WRONG_STORE_TARGET" "$(readlink "$asset_target_path")"
  assert_eq "$asset_vendor $asset_target wrong-link referent is preserved" \
    "store target stays intact" "$(cat "$WRONG_STORE_TARGET/sentinel")"

  rm "$asset_target_path"
  materialised_asset_text="materialised $asset_vendor $asset_target stays intact"
  if [[ "$asset_kind" == directory ]]; then
    mkdir "$asset_target_path"
    materialised_asset_sentinel="$asset_target_path/sentinel"
  else
    materialised_asset_sentinel="$asset_target_path"
  fi
  printf '%s\n' "$materialised_asset_text" > "$materialised_asset_sentinel"
  materialised_asset_status=0
  materialised_asset_out="$(ihar_runtime_materialise "$asset_vendor" "$asset_hash" "$RENDER" 2>&1)" \
    || materialised_asset_status=$?
  assert_eq "$asset_vendor $asset_target materialised runtime asset is rejected" \
    "3" "$materialised_asset_status"
  assert_contains "$asset_vendor $asset_target materialised diagnostic identifies target" \
    "$materialised_asset_out" "$asset_target_path"
  assert_exit "$asset_vendor $asset_target materialised entry is not replaced" \
    1 test -L "$asset_target_path"
  assert_eq "$asset_vendor $asset_target materialised bytes are preserved" \
    "$materialised_asset_text" "$(cat "$materialised_asset_sentinel")"

  rm -rf -- "$asset_target_path"
  ln -s "$asset_source_path" "$asset_target_path"
done <<< "$EXPECTED_RUNTIME_ASSETS"

mv "$IHAR_STORE/hooks" "$IHAR_STORE/hooks.saved"
missing_hook_source_status=0
missing_hook_source_out="$(ihar_runtime_materialise claude "$rt2_hash" "$RENDER" 2>&1)" \
  || missing_hook_source_status=$?
assert_eq "runtime reuse rejects a missing required hooks source" \
  "3" "$missing_hook_source_status"
assert_contains "missing required hooks source is diagnosed" \
  "$missing_hook_source_out" "required runtime asset is missing from the store"
assert_eq "a dangling required hooks link is preserved" \
  "$IHAR_STORE/hooks" "$(readlink "$rt2/hooks")"
mv "$IHAR_STORE/hooks.saved" "$IHAR_STORE/hooks"

while IFS=$'\t' read -r asset_vendor asset_source asset_target asset_kind asset_required; do
  [[ "$asset_required" == false ]] || continue
  if [[ "$asset_vendor" == claude ]]; then
    asset_runtime="$rt2"
  else
    asset_runtime="$asset_codex_runtime"
  fi
  rm -rf -- "$asset_runtime/$asset_target" "$IHAR_STORE/$asset_source"
done <<< "$EXPECTED_RUNTIME_ASSETS"

# A materialised copy where a link belongs means the entry stopped following the
# store; the repair replaces it.
rm "$rt2/skills"; mkdir "$rt2/skills"; touch "$rt2/skills/stale"
ihar_link_runtime claude "$rt2" "$STATE" 2>/dev/null
assert_exit "a materialised copy is replaced by a link" 0 test -L "$rt2/skills"

ln -sfn /nowhere "$rt2/hooks"
ihar_link_runtime claude "$rt2" "$STATE" 2>/dev/null
assert_eq "a wrong link is repointed" "$IHAR_STORE/hooks" "$(readlink "$rt2/hooks")"

# Runtime links are a projection of the installed tracked-asset inventory: every
# runtime entry must be present, while a store pathname absent from that inventory
# is never linked merely because it happens to exist.
mkdir -p "$IHAR_STORE/undeclared"
printf 'not portable\n' > "$IHAR_STORE/undeclared/data"
rt_assets="$(ihar_runtime_materialise codex "$(ihar_config_hash asset inventory runtime links a b c d mcp)" "$RENDER")"
while IFS=$'\t' read -r asset_vendor asset_source asset_target asset_kind asset_required; do
  [[ "$asset_vendor" == codex ]] || continue
  [[ -e "$IHAR_STORE/$asset_source" ]] || continue
  assert_exit "runtime asset $asset_target is linked" 0 test -L "$rt_assets/$asset_target"
done <<< "$EXPECTED_RUNTIME_ASSETS"
assert_exit "an undeclared store entry is never linked" 1 test -e "$rt_assets/undeclared"

# The complete asset inventory is read and validated before the linker touches a
# runtime target. A malformed manifest must therefore preserve an existing target
# byte-for-byte instead of silently falling through to state linking.
INVALID_ASSET_ROOT="$IHAR_TEST_TMP/invalid-asset-root"
INVALID_ASSET_RUNTIME="$IHAR_TEST_TMP/invalid-asset-runtime"
INVALID_ASSET_STATE="$IHAR_TEST_TMP/invalid-asset-state"
mkdir -p "$INVALID_ASSET_ROOT/manifests" "$INVALID_ASSET_RUNTIME/hooks" "$INVALID_ASSET_STATE"
ln -s "$ROOT/lib" "$INVALID_ASSET_ROOT/lib"
printf 'not valid JSON\n' > "$INVALID_ASSET_ROOT/manifests/assets.json"
printf '{"schema":1,"entries":[]}\n' > "$INVALID_ASSET_ROOT/manifests/state.json"
printf 'runtime target must remain\n' > "$INVALID_ASSET_RUNTIME/hooks/sentinel"
invalid_asset_fingerprint="$(find "$INVALID_ASSET_RUNTIME" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
invalid_asset_status=0
invalid_asset_out="$(IHAR_ROOT="$INVALID_ASSET_ROOT" ihar_link_runtime claude "$INVALID_ASSET_RUNTIME" "$INVALID_ASSET_STATE" 2>&1)" \
  || invalid_asset_status=$?
assert_eq "an invalid asset inventory aborts linking" "3" "$invalid_asset_status"
assert_contains "an invalid asset inventory is diagnosed" "$invalid_asset_out" \
  "cannot read tracked asset inventory"
assert_eq "an invalid asset inventory leaves runtime targets unchanged" \
  "$invalid_asset_fingerprint" \
  "$(find "$INVALID_ASSET_RUNTIME" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"

# Both runtime linking and migration consume one validated inventory. This fixture
# is intentionally outside the repository so adding an entry proves neither path
# depends on a second hard-coded Bash list.
MANIFEST_PARENT="$IHAR_TEST_TMP/manifest-parent"
MANIFEST_ROOT="$MANIFEST_PARENT/ihar"
MANIFEST_PROJECT="$IHAR_TEST_TMP/manifest-project"
MANIFEST_HASH="$(printf '%s' "$MANIFEST_PROJECT" | sha256sum | cut -c1-12)"
MANIFEST_LEGACY="$MANIFEST_PARENT/icodex/.codex-homes/fixture-$MANIFEST_HASH"
MANIFEST_LINK_STATE="$IHAR_TEST_TMP/manifest-link-state"
MANIFEST_MIGRATE_STATE="$IHAR_TEST_TMP/manifest-migrate-state"
MANIFEST_RUNTIME="$IHAR_TEST_TMP/manifest-runtime"
mkdir -p "$MANIFEST_ROOT/manifests" "$MANIFEST_LEGACY/data" \
  "$MANIFEST_LINK_STATE/st/codex" "$MANIFEST_MIGRATE_STATE/st/codex" \
  "$MANIFEST_LINK_STATE/r" "$MANIFEST_RUNTIME" "$MANIFEST_PROJECT"
ln -s "$ROOT/lib" "$MANIFEST_ROOT/lib"
cat > "$MANIFEST_ROOT/manifests/state.json" <<'JSON'
{
  "schema": 1,
  "entries": [
    {"vendor":"codex","path":"data","kind":"directory"},
    {"vendor":"codex","path":"future.jsonl","kind":"file"},
    {"vendor":"codex","path":"state.sqlite","kind":"sqlite-family"}
  ]
}
JSON
printf '{"schema":1,"entries":[]}\n' > "$MANIFEST_ROOT/manifests/assets.json"
printf '{"schema":1,"entries":[]}\n' > "$MANIFEST_ROOT/manifests/mutable-links.json"
printf 'db\n' > "$MANIFEST_LEGACY/state.sqlite"
printf 'wal\n' > "$MANIFEST_LEGACY/state.sqlite-wal"
printf 'shm\n' > "$MANIFEST_LEGACY/state.sqlite-shm"
printf 'nested\n' > "$MANIFEST_LEGACY/data/record"

SAVED_IHAR_ROOT="$IHAR_ROOT"
IHAR_ROOT="$MANIFEST_ROOT"
state_inventory() { ihar_state_inventory "$1"; }
migration_inventory() { ihar_migration_inventory "$1"; }
assert_exit "link inventory query succeeds" 0 ihar_state_inventory codex
assert_exit "migration inventory query succeeds" 0 ihar_migration_inventory codex
assert_eq "linker and migration read the same entries" \
  "$(state_inventory codex)" "$(migration_inventory codex)"
ihar_link_runtime codex "$MANIFEST_RUNTIME" "$MANIFEST_LINK_STATE" 2>/dev/null
assert_exit "a declared directory is linked" 0 test -L "$MANIFEST_RUNTIME/data"
assert_exit "a declared directory source is created" 0 \
  test -d "$MANIFEST_LINK_STATE/st/codex/data"
assert_exit "a declared absent file gets a dangling link" 0 test -L "$MANIFEST_RUNTIME/future.jsonl"
assert_exit "a SQLite base is linked" 0 test -L "$MANIFEST_RUNTIME/state.sqlite"
assert_exit "a SQLite WAL is linked" 0 test -L "$MANIFEST_RUNTIME/state.sqlite-wal"
assert_exit "a SQLite SHM is linked" 0 test -L "$MANIFEST_RUNTIME/state.sqlite-shm"

SAVED_IHAR_STATE="$IHAR_STATE"
SAVED_IHAR_RUNTIME="${IHAR_RUNTIME:-}"
IHAR_STATE="$MANIFEST_LINK_STATE"
manifest_runtime_hash="$(ihar_config_hash manifest reuse state links a b c d mcp)"
ihar_runtime_materialise codex "$manifest_runtime_hash" "$RENDER" >/dev/null
MANIFEST_REUSE_RUNTIME="$IHAR_RUNTIME"
rm "$MANIFEST_REUSE_RUNTIME/state.sqlite-wal"
ihar_runtime_materialise codex "$manifest_runtime_hash" "$RENDER" >/dev/null
assert_eq "runtime reuse restores a missing SQLite WAL link" \
  "$MANIFEST_LINK_STATE/st/codex/state.sqlite-wal" \
  "$(readlink "$MANIFEST_REUSE_RUNTIME/state.sqlite-wal")"

ihar_migrate_vendor codex "$MANIFEST_MIGRATE_STATE" "$MANIFEST_PROJECT" >/dev/null
assert_exit "migration copies a manifest directory" 0 \
  test -f "$MANIFEST_MIGRATE_STATE/st/codex/data/record"
assert_exit "migration copies a SQLite base" 0 \
  test -f "$MANIFEST_MIGRATE_STATE/st/codex/state.sqlite"
assert_exit "migration keeps the SQLite WAL" 0 \
  test -f "$MANIFEST_MIGRATE_STATE/st/codex/state.sqlite-wal"
assert_exit "migration keeps the SQLite SHM" 0 \
  test -f "$MANIFEST_MIGRATE_STATE/st/codex/state.sqlite-shm"

python3 - "$MANIFEST_ROOT/manifests/state.json" <<'PY'
import json, sys
path = sys.argv[1]
manifest = json.load(open(path, encoding="utf-8"))
manifest["entries"].append({"vendor": "codex", "path": "added.jsonl", "kind": "file"})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
printf 'added\n' > "$MANIFEST_LEGACY/added.jsonl"
manifest_runtime_hash_added="$(ihar_config_hash manifest reuse state links a b c d mcp)"
assert_exit "a state-manifest change selects a new runtime generation" 1 \
  test "$manifest_runtime_hash" = "$manifest_runtime_hash_added"
MANIFEST_LINK_STATE_ADDED="$IHAR_TEST_TMP/manifest-link-state-added"
MANIFEST_MIGRATE_STATE_ADDED="$IHAR_TEST_TMP/manifest-migrate-state-added"
MANIFEST_RUNTIME_ADDED="$IHAR_TEST_TMP/manifest-runtime-added"
mkdir -p "$MANIFEST_LINK_STATE_ADDED/st/codex" \
  "$MANIFEST_MIGRATE_STATE_ADDED/st/codex" "$MANIFEST_RUNTIME_ADDED"
assert_eq "manifest additions reach linker and migration without Bash array edits" \
  "$(state_inventory codex)" "$(migration_inventory codex)"
ihar_runtime_materialise codex "$manifest_runtime_hash_added" "$RENDER" >/dev/null
MANIFEST_REUSE_RUNTIME_ADDED="$IHAR_RUNTIME"
assert_exit "an incompatible state inventory does not reuse the old runtime" 1 \
  test "$MANIFEST_REUSE_RUNTIME" = "$MANIFEST_REUSE_RUNTIME_ADDED"
assert_eq "the new runtime generation links the added entry" \
  "$MANIFEST_LINK_STATE/st/codex/added.jsonl" \
  "$(readlink "$MANIFEST_REUSE_RUNTIME_ADDED/added.jsonl")"
ihar_link_runtime codex "$MANIFEST_RUNTIME_ADDED" "$MANIFEST_LINK_STATE_ADDED" 2>/dev/null
assert_exit "the added file is linked" 0 test -L "$MANIFEST_RUNTIME_ADDED/added.jsonl"
ihar_migrate_vendor codex "$MANIFEST_MIGRATE_STATE_ADDED" "$MANIFEST_PROJECT" >/dev/null
assert_exit "the added file is migrated" 0 \
  test -f "$MANIFEST_MIGRATE_STATE_ADDED/st/codex/added.jsonl"

# A pre-manifest runtime may own vendor state as real files/directories. Creating a
# generation keyed by the current manifest migrates exactly one old owner, keeps a
# private recovery copy, and links both old and new runtimes to canonical st/.
UPGRADE_STATE="$IHAR_TEST_TMP/runtime-upgrade-state"
UPGRADE_OLD="$UPGRADE_STATE/r/11111111/codex"
mkdir -p "$UPGRADE_STATE/st/codex" "$UPGRADE_OLD/data"
printf 'old runtime record\n' > "$UPGRADE_OLD/data/record"
printf 'old runtime db\n' > "$UPGRADE_OLD/state.sqlite"
printf 'old runtime wal\n' > "$UPGRADE_OLD/state.sqlite-wal"
printf 'old runtime shm\n' > "$UPGRADE_OLD/state.sqlite-shm"
IHAR_STATE="$UPGRADE_STATE"
upgrade_hash="$(ihar_config_hash runtime upgrade manifest identity a b c d mcp)"
ihar_runtime_materialise codex "$upgrade_hash" "$RENDER" >/dev/null
UPGRADE_NEW="$IHAR_RUNTIME"
assert_eq "runtime upgrade publishes materialized directory state" "old runtime record" \
  "$(cat "$UPGRADE_STATE/st/codex/data/record")"
assert_eq "runtime upgrade publishes the SQLite WAL" "old runtime wal" \
  "$(cat "$UPGRADE_STATE/st/codex/state.sqlite-wal")"
assert_eq "runtime upgrade replaces the old directory with a canonical link" \
  "$UPGRADE_STATE/st/codex/data" "$(readlink "$UPGRADE_OLD/data")"
assert_eq "the new runtime links the migrated directory" \
  "$UPGRADE_STATE/st/codex/data" "$(readlink "$UPGRADE_NEW/data")"
upgrade_recovery="$(find "$UPGRADE_STATE/recovery/runtime-state/codex" \
  -mindepth 1 -maxdepth 1 -type d -name '11111111-*' -print -quit)"
assert_eq "runtime upgrade preserves the original recovery bytes" "old runtime record" \
  "$(cat "$upgrade_recovery/data/record")"
recovery_count_before="$(find "$UPGRADE_STATE/recovery/runtime-state/codex" \
  -mindepth 1 -maxdepth 1 -type d | wc -l)"
ihar_runtime_materialise codex "$upgrade_hash" "$RENDER" >/dev/null
assert_eq "runtime upgrade is idempotent" "$recovery_count_before" \
  "$(find "$UPGRADE_STATE/recovery/runtime-state/codex" \
    -mindepth 1 -maxdepth 1 -type d | wc -l)"
IHAR_STATE="$SAVED_IHAR_STATE"
IHAR_RUNTIME="$SAVED_IHAR_RUNTIME"
IHAR_ROOT="$SAVED_IHAR_ROOT"

# --- migration from a legacy home ----------------------------------------------------

LEGACY="$IHAR_TEST_TMP/parent/iclaude/.claude-homes/whatever-$(printf '%s' "$PROJECT" | sha256sum | cut -c1-12)"
mkdir -p "$LEGACY/projects" "$LEGACY/sessions"
printf 'transcript\n' > "$LEGACY/projects/one.jsonl"
printf '{"schema":1,"project_root":"%s","created":"2026-01-01T00:00:00Z"}\n' "$PROJECT" \
  > "$LEGACY/home.json"
ln -s /etc/passwd "$LEGACY/.credentials.json"

# Legacy homes are discovered relative to the checkout, so the test needs a fake one;
# it links the real lib/ so the marker reader is the real reader.
IHAR_ROOT="$IHAR_TEST_TMP/parent/ihar"
mkdir -p "$IHAR_ROOT"
ln -sfn "$ROOT/lib" "$IHAR_ROOT/lib"
ln -sfn "$ROOT/manifests" "$IHAR_ROOT/manifests"
FRESH="$IHAR_TEST_TMP/fresh-state"
mkdir -p "$FRESH/st/claude"
ihar_migrate_vendor claude "$FRESH" "$PROJECT" >/dev/null
assert_exit "legacy transcripts are copied" 0 test -f "$FRESH/st/claude/projects/one.jsonl"
assert_exit "the legacy home is left in place" 0 test -f "$LEGACY/projects/one.jsonl"
assert_exit "a legacy symlink into the old store is not followed" 1 \
  test -e "$FRESH/st/claude/.credentials.json"

# A second run must not overwrite live state.
printf 'live\n' > "$FRESH/st/claude/projects/one.jsonl"
ihar_migrate_vendor claude "$FRESH" "$PROJECT" >/dev/null
assert_eq "a populated state is not migrated over" "live" \
  "$(cat "$FRESH/st/claude/projects/one.jsonl")"

# A marker naming another project is not this project's history.
OTHER="$IHAR_TEST_TMP/other-state"
mkdir -p "$OTHER/st/claude"
printf '{"schema":1,"project_root":"/elsewhere","created":"2026-01-01T00:00:00Z"}\n' \
  > "$LEGACY/home.json"
ihar_migrate_vendor claude "$OTHER" "$PROJECT" >/dev/null 2>&1
assert_exit "a legacy home recording another project is skipped" 1 \
  test -f "$OTHER/st/claude/projects/one.jsonl"

# A marker that exists but cannot be read is evidence we failed to check, not
# evidence there was nothing to check. Copying another project's transcripts in is
# not something the user can undo.
UNREADABLE="$IHAR_TEST_TMP/unreadable-state"
mkdir -p "$UNREADABLE/st/claude"
printf 'not json at all\n' > "$LEGACY/home.json"
ihar_migrate_vendor claude "$UNREADABLE" "$PROJECT" >/dev/null 2>&1
assert_exit "a legacy home with an unreadable marker is skipped" 1 \
  test -f "$UNREADABLE/st/claude/projects/one.jsonl"

# Claude requires its marker; hash-only attribution is reserved for Codex.
NOMARK="$IHAR_TEST_TMP/nomark-state"
mkdir -p "$NOMARK/st/claude"
rm -f "$LEGACY/home.json"
ihar_migrate_vendor claude "$NOMARK" "$PROJECT" >/dev/null 2>&1
assert_exit "a Claude legacy home with no marker is skipped" 1 \
  test -f "$NOMARK/st/claude/projects/one.jsonl"

# A failed copy must leave the target empty and return failure, or the next attempt
# would mistake partial data for live state and never retry.
FAIL_PROJECT="$IHAR_TEST_TMP/fail-project"
FAIL_HASH="$(printf '%s' "$FAIL_PROJECT" | sha256sum | cut -c1-12)"
FAIL_LEGACY="$IHAR_TEST_TMP/parent/iclaude/.claude-homes/fail-$FAIL_HASH"
FAIL_STATE="$IHAR_TEST_TMP/fail-state"
mkdir -p "$FAIL_PROJECT" "$FAIL_LEGACY/projects" "$FAIL_STATE/st/claude"
printf '{"schema":1,"project_root":"%s","created":"2026-01-01T00:00:00Z"}\n' \
  "$FAIL_PROJECT" > "$FAIL_LEGACY/home.json"
printf 'unreadable\n' > "$FAIL_LEGACY/projects/session.jsonl"
chmod 000 "$FAIL_LEGACY/projects/session.jsonl"
copy_status=0
copy_out="$(ihar_migrate_vendor claude "$FAIL_STATE" "$FAIL_PROJECT" 2>/dev/null)" \
  || copy_status=$?
assert_eq "a failed migration returns failure" "1" "$copy_status"
assert_eq "a failed migration reports no source" "" "$copy_out"
assert_eq "a failed migration leaves the target empty" "0" \
  "$(find "$FAIL_STATE/st/claude" -mindepth 1 -maxdepth 1 | wc -l)"
chmod 600 "$FAIL_LEGACY/projects/session.jsonl"

# The operator command migrates both vendors in one locked operation and records
# the sources. Removing the `migrate` branch, either vendor call, or marker update
# must break an observable assertion below.
QUIET_PROJECT="$IHAR_TEST_TMP/quiescence-project"
QUIET_STATE_ROOT="$IHAR_TEST_TMP/quiescence-state"
QUIET_HASH="$(printf '%s' "$QUIET_PROJECT" | sha256sum | cut -c1-12)"
QUIET_CLAUDE="$IHAR_TEST_TMP/parent/iclaude/.claude-homes/quiescence-$QUIET_HASH"
QUIET_CODEX="$IHAR_TEST_TMP/parent/icodex/.codex-homes/quiescence-$QUIET_HASH"
mkdir -p "$QUIET_PROJECT" "$QUIET_CLAUDE/projects" "$QUIET_CODEX"
printf 'claude-active\n' > "$QUIET_CLAUDE/projects/session.jsonl"
printf 'codex-active\n' > "$QUIET_CODEX/state_5.sqlite"
printf '{"schema":1,"project_root":"%s","created":"2026-01-01T00:00:00Z"}\n' \
  "$QUIET_PROJECT" > "$QUIET_CLAUDE/home.json"
CODEX_HOME="$QUIET_CODEX" sleep 30 &
writer_pid=$!
quiet_status=0
quiet_out="$(cd "$QUIET_PROJECT" && IHAR_ROOT="$IHAR_TEST_TMP/parent/ihar" \
  IHAR_STATE_ROOT="$QUIET_STATE_ROOT" IHAR_STORE="$IHAR_STORE" \
  "$ROOT/ihar.sh" homes migrate 2>&1)" || quiet_status=$?
kill "$writer_pid" 2>/dev/null || true
wait "$writer_pid" 2>/dev/null || true
QUIET_STATE="$QUIET_STATE_ROOT/$(printf '%s' "$QUIET_PROJECT" | sha256sum | cut -c1-8)"
assert_eq "an active legacy writer refuses the whole migration" "1" "$quiet_status"
assert_contains "the refusal identifies the active Codex home" "$quiet_out" "$QUIET_CODEX"
assert_eq "an active Codex writer prevents Claude copying too" "0" \
  "$(find "$QUIET_STATE/st/claude" -mindepth 1 -maxdepth 1 | wc -l)"
assert_eq "an active writer leaves Codex state empty" "0" \
  "$(find "$QUIET_STATE/st/codex" -mindepth 1 -maxdepth 1 | wc -l)"

lock_ready="$IHAR_TEST_TMP/lifecycle-lock-ready"
bash -c 'exec {fd}>"$1.ihar-lifecycle.lock"; flock -s "$fd"; : > "$2"; sleep 30' _ \
  "$QUIET_CODEX" "$lock_ready" &
lock_writer_pid=$!
while [[ ! -e "$lock_ready" ]]; do :; done
lock_status=0
(cd "$QUIET_PROJECT" && IHAR_ROOT="$IHAR_TEST_TMP/parent/ihar" \
  IHAR_STATE_ROOT="$QUIET_STATE_ROOT" IHAR_STORE="$IHAR_STORE" \
  IHAR_MIGRATION_LOCK_TIMEOUT=1 "$ROOT/ihar.sh" homes migrate) >/dev/null 2>&1 \
  || lock_status=$?
kill "$lock_writer_pid" 2>/dev/null || true
wait "$lock_writer_pid" 2>/dev/null || true
assert_eq "a wrapper lifecycle lock refuses migration" "3" "$lock_status"
assert_eq "a lifecycle-lock refusal copies neither vendor" "0" \
  "$(find "$QUIET_STATE/st/claude" "$QUIET_STATE/st/codex" -mindepth 1 -maxdepth 1 | wc -l)"

# Environment detection is vendor-specific, and a process that no longer exposes
# the vendor variable must still be caught through an open descriptor.
CLAUDE_CONFIG_DIR="$QUIET_CLAUDE" sleep 30 &
claude_writer_pid=$!
assert_eq "a Claude environment identifies its writer" "$claude_writer_pid" \
  "$(_ihar_legacy_writer_pid claude "$QUIET_CLAUDE")"
kill "$claude_writer_pid" 2>/dev/null || true
wait "$claude_writer_pid" 2>/dev/null || true

fd_ready="$IHAR_TEST_TMP/fd-writer-ready"
bash -c 'exec 9<"$1"; : > "$2"; sleep 30' _ \
  "$QUIET_CODEX/state_5.sqlite" "$fd_ready" &
fd_writer_pid=$!
while [[ ! -e "$fd_ready" ]]; do :; done
assert_eq "an open legacy descriptor identifies its writer" "$fd_writer_pid" \
  "$(_ihar_legacy_writer_pid codex "$QUIET_CODEX")"
kill "$fd_writer_pid" 2>/dev/null || true
wait "$fd_writer_pid" 2>/dev/null || true

# A transient process can mutate the source during rsync and exit before the next
# process scan. The staged bytes must still be rejected as an unstable snapshot.
RACE_PROJECT="$IHAR_TEST_TMP/race-project"
RACE_HASH="$(printf '%s' "$RACE_PROJECT" | sha256sum | cut -c1-12)"
RACE_LEGACY="$IHAR_TEST_TMP/parent/icodex/.codex-homes/race-$RACE_HASH"
RACE_STATE="$IHAR_TEST_TMP/race-state"
RACE_BIN="$IHAR_TEST_TMP/race-bin"
mkdir -p "$RACE_PROJECT" "$RACE_LEGACY" "$RACE_STATE/st/codex" "$RACE_BIN"
printf 'before\n' > "$RACE_LEGACY/state_5.sqlite"
cat > "$RACE_BIN/rsync" <<'EOF'
#!/usr/bin/env bash
/usr/bin/rsync "$@" || exit
if [[ ! -e "$IHAR_TEST_RACE_DONE" ]]; then
  : > "$IHAR_TEST_RACE_DONE"
  printf 'during-copy\n' >> "$IHAR_TEST_RACE_SOURCE/state_5.sqlite"
fi
EOF
chmod +x "$RACE_BIN/rsync"
race_status=0
PATH="$RACE_BIN:$PATH" IHAR_TEST_RACE_SOURCE="$RACE_LEGACY" \
  IHAR_TEST_RACE_DONE="$IHAR_TEST_TMP/race-done" \
  ihar_migrate_vendor codex "$RACE_STATE" "$RACE_PROJECT" >/dev/null 2>&1 \
  || race_status=$?
assert_eq "a transient writer makes the migration fail" "1" "$race_status"
assert_eq "an unstable snapshot is discarded" "0" \
  "$(find "$RACE_STATE/st/codex" -mindepth 1 -maxdepth 1 | wc -l)"

CLI_PROJECT="$IHAR_TEST_TMP/real-project"
CLI_STATE_ROOT="$IHAR_TEST_TMP/real-state"
CLI_HASH="$(printf '%s' "$CLI_PROJECT" | sha256sum | cut -c1-12)"
CLI_CLAUDE="$IHAR_TEST_TMP/parent/iclaude/.claude-homes/real-$CLI_HASH"
CLI_CODEX="$IHAR_TEST_TMP/parent/icodex/.codex-homes/real-$CLI_HASH"
mkdir -p "$CLI_PROJECT" "$CLI_CLAUDE/projects" "$CLI_CODEX"
printf 'claude-history\n' > "$CLI_CLAUDE/projects/session.jsonl"
ln -s /etc/passwd "$CLI_CLAUDE/projects/nested-link"
mkfifo "$CLI_CLAUDE/projects/nested-fifo"
printf 'codex-history\n' > "$CLI_CODEX/state_5.sqlite"
printf 'codex-wal\n' > "$CLI_CODEX/state_5.sqlite-wal"
printf 'codex-shm\n' > "$CLI_CODEX/state_5.sqlite-shm"
for family in goals_1.sqlite memories_1.sqlite logs_2.sqlite; do
  printf '%s\n' "$family" > "$CLI_CODEX/$family"
  printf '%s wal\n' "$family" > "$CLI_CODEX/$family-wal"
  printf '%s shm\n' "$family" > "$CLI_CODEX/$family-shm"
done
printf '{"schema":1,"project_root":"%s","created":"2026-01-01T00:00:00Z"}\n' \
  "$CLI_PROJECT" > "$CLI_CLAUDE/home.json"

LOCK_PROBE_BIN="$IHAR_TEST_TMP/lock-probe-bin"
LOCK_PROBE_GAP="$IHAR_TEST_TMP/lock-probe-gap"
mkdir -p "$LOCK_PROBE_BIN"
cat > "$LOCK_PROBE_BIN/rsync" <<'EOF'
#!/usr/bin/env bash
source_path="${*: -2:1}"
legacy="$(dirname "$source_path")"
if flock -s -n "$legacy.ihar-lifecycle.lock" true 2>/dev/null; then
  : > "$IHAR_TEST_LOCK_PROBE_GAP"
fi
exec /usr/bin/rsync "$@"
EOF
chmod +x "$LOCK_PROBE_BIN/rsync"
migrate_out="$(cd "$CLI_PROJECT" && PATH="$LOCK_PROBE_BIN:$PATH" \
  IHAR_TEST_LOCK_PROBE_GAP="$LOCK_PROBE_GAP" IHAR_ROOT="$IHAR_TEST_TMP/parent/ihar" \
  IHAR_STATE_ROOT="$CLI_STATE_ROOT" IHAR_STORE="$IHAR_STORE" "$ROOT/ihar.sh" homes migrate 2>&1)"
CLI_STATE="$CLI_STATE_ROOT/$(printf '%s' "$CLI_PROJECT" | sha256sum | cut -c1-8)"
assert_contains "homes migrate reports the Claude source" "$migrate_out" "$CLI_CLAUDE"
assert_contains "homes migrate reports the Codex source" "$migrate_out" "$CLI_CODEX"
assert_exit "homes migrate copies Claude state" 0 \
  test -f "$CLI_STATE/st/claude/projects/session.jsonl"
assert_exit "homes migrate copies Codex state" 0 \
  test -f "$CLI_STATE/st/codex/state_5.sqlite"
assert_exit "homes migrate copies the Codex WAL with its database" 0 \
  test -f "$CLI_STATE/st/codex/state_5.sqlite-wal"
assert_exit "homes migrate copies the Codex SHM with its database" 0 \
  test -f "$CLI_STATE/st/codex/state_5.sqlite-shm"
for family in goals_1.sqlite memories_1.sqlite logs_2.sqlite; do
  assert_exit "homes migrate copies $family" 0 \
    test -f "$CLI_STATE/st/codex/$family"
  assert_exit "homes migrate copies $family WAL" 0 \
    test -f "$CLI_STATE/st/codex/$family-wal"
  assert_exit "homes migrate copies $family SHM" 0 \
    test -f "$CLI_STATE/st/codex/$family-shm"
done
assert_exit "homes migrate skips nested legacy symlinks" 1 \
  test -e "$CLI_STATE/st/claude/projects/nested-link"
assert_exit "homes migrate skips nested special files" 1 \
  test -e "$CLI_STATE/st/claude/projects/nested-fifo"
assert_exit "migration holds exclusive locks throughout rsync" 1 \
  test -e "$LOCK_PROBE_GAP"
assert_exit "homes migrate leaves Claude legacy state" 0 test -f "$CLI_CLAUDE/projects/session.jsonl"
assert_exit "homes migrate leaves Codex legacy state" 0 test -f "$CLI_CODEX/state_5.sqlite"
assert_eq "homes migrate records both sources" \
  "$CLI_CLAUDE|$CLI_CODEX" \
  "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["migrated_from"]; print(d["claude"]+"|"+d["codex"])' "$CLI_STATE/home.json")"

printf 'live\n' > "$CLI_STATE/st/claude/projects/session.jsonl"
(cd "$CLI_PROJECT" && IHAR_ROOT="$IHAR_TEST_TMP/parent/ihar" \
  IHAR_STATE_ROOT="$CLI_STATE_ROOT" IHAR_STORE="$IHAR_STORE" "$ROOT/ihar.sh" homes migrate) \
  >/dev/null 2>&1
assert_eq "homes migrate never overwrites populated state" "live" \
  "$(cat "$CLI_STATE/st/claude/projects/session.jsonl")"

# A marker-write failure rolls that vendor back but must not prevent the other
# vendor from completing and being recorded.
MARK_PROJECT="$IHAR_TEST_TMP/marker-fail-project"
MARK_STATE_ROOT="$IHAR_TEST_TMP/marker-fail-state"
MARK_HASH="$(printf '%s' "$MARK_PROJECT" | sha256sum | cut -c1-12)"
MARK_CLAUDE="$IHAR_TEST_TMP/parent/iclaude/.claude-homes/marker-$MARK_HASH"
MARK_CODEX="$IHAR_TEST_TMP/parent/icodex/.codex-homes/marker-$MARK_HASH"
mkdir -p "$MARK_PROJECT" "$MARK_CLAUDE/projects" "$MARK_CODEX/sessions"
printf 'claude\n' > "$MARK_CLAUDE/projects/session.jsonl"
printf 'codex\n' > "$MARK_CODEX/sessions/session.jsonl"
printf '{"schema":1,"project_root":"%s","created":"2026-01-01T00:00:00Z"}\n' \
  "$MARK_PROJECT" > "$MARK_CLAUDE/home.json"
cat > "$IHAR_TEST_TMP/python-marker-fail" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--record-migration"*" claude "* ]]; then exit 1; fi
exec python3 "$@"
EOF
chmod +x "$IHAR_TEST_TMP/python-marker-fail"
assert_exit "one marker failure makes the command fail" 1 \
  bash -c "cd '$MARK_PROJECT' && IHAR_ROOT='$IHAR_TEST_TMP/parent/ihar' \
    IHAR_STATE_ROOT='$MARK_STATE_ROOT' IHAR_STORE='$IHAR_STORE' \
    IHAR_PY='$IHAR_TEST_TMP/python-marker-fail' '$ROOT/ihar.sh' homes migrate"
MARK_STATE="$MARK_STATE_ROOT/$(printf '%s' "$MARK_PROJECT" | sha256sum | cut -c1-8)"
assert_eq "a marker failure rolls its copied state back" "0" \
  "$(find "$MARK_STATE/st/claude" -mindepth 1 -maxdepth 1 | wc -l)"
assert_exit "a Claude marker failure does not block Codex migration" 0 \
  test -f "$MARK_STATE/st/codex/sessions/session.jsonl"
assert_eq "the successful Codex source is still recorded" "$MARK_CODEX" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["migrated_from"]["codex"])' "$MARK_STATE/home.json")"

IHAR_ROOT="$ROOT"

# --- garbage collection ---------------------------------------------------------------

listing="$(ihar_state_list)"
assert_contains "the listing names the project" "$listing" "$PROJECT"

GONE="$IHAR_TEST_TMP/gone"
mkdir -p "$GONE"
gone_state="$(ihar_state_setup "$GONE")"
rmdir "$GONE"
assert_contains "a removed project is marked orphan" "$(ihar_state_list)" "orphan"
IHAR_ASSUME_YES=1 ihar_state_clean_orphans >/dev/null
assert_exit "the orphan state is removed" 1 test -d "$gone_state"
assert_exit "the live state is kept" 0 test -d "$STATE"

# Operator cleanup is runtime-only. No-id resolves current state; an id selects only
# that exact marked state. Orphans and all persistent st/ content survive.
CURRENT_STATE="$STATE"
NAMED_PROJECT="$IHAR_TEST_TMP/named-project"
mkdir -p "$NAMED_PROJECT"
NAMED_STATE="$(ihar_state_setup "$NAMED_PROJECT")"
NAMED_ID="$(basename "$NAMED_STATE")"
ORPHAN_STATE="$IHAR_STATE_ROOT/orphan-kept"
CURRENT_OLD=aaaaaaaa
NAMED_OLD=bbbbbbbb
ACTIVE_OLD=cccccccc
RECENT_RUNTIME=dddddddd
REUSE_RUNTIME=eeeeeeee
mkdir -p "$CURRENT_STATE/r/$CURRENT_OLD/claude" "$CURRENT_STATE/st/claude" \
  "$NAMED_STATE/r/$NAMED_OLD/codex" "$NAMED_STATE/st/codex" \
  "$CURRENT_STATE/r/$ACTIVE_OLD/claude" "$CURRENT_STATE/r/$RECENT_RUNTIME/codex" \
  "$CURRENT_STATE/r/$REUSE_RUNTIME/claude" "$ORPHAN_STATE/r/ffffffff/claude"
# The reused fixture represents a published runtime, so it carries the required
# manifest-derived links that reuse now verifies.
ihar_link_runtime claude "$CURRENT_STATE/r/$REUSE_RUNTIME/claude" "$CURRENT_STATE" \
  >/dev/null 2>&1
touch -d '60 days ago' "$CURRENT_STATE/r/$RECENT_RUNTIME"
python3 - "$CURRENT_STATE/home.json" "$NAMED_STATE/home.json" <<'PY'
import json, sys
old = "2020-01-01T00:00:00Z"
recent = "2099-01-01T00:00:00Z"
for path, records in (
    (sys.argv[1], {"aaaaaaaa": old, "cccccccc": old, "dddddddd": recent, "eeeeeeee": old}),
    (sys.argv[2], {"bbbbbbbb": old}),
):
    marker = json.load(open(path, encoding="utf-8"))
    for runtime_hash, used in records.items():
        marker["runtimes"][runtime_hash] = {"profile": "standard", "created": old, "last_used": used}
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(marker, handle)
PY
printf 'current\n' > "$CURRENT_STATE/st/claude/sentinel"
printf 'named\n' > "$NAMED_STATE/st/codex/sentinel"

IHAR_STATE="$CURRENT_STATE"
reuse_before="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runtimes"]["eeeeeeee"]["last_used"])' "$CURRENT_STATE/home.json")"
ihar_runtime_materialise claude "$REUSE_RUNTIME" "" writable >/dev/null
reuse_after="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runtimes"]["eeeeeeee"]["last_used"])' "$CURRENT_STATE/home.json")"
assert_exit "runtime reuse refreshes authoritative last_used" 1 test "$reuse_before" = "$reuse_after"

IHAR_RUNTIME="$CURRENT_STATE/r/$ACTIVE_OLD/claude" sleep 30 &
active_runtime_pid=$!
assert_exit "clean current runtimes" 0 \
  bash -c "cd '$PROJECT'; IHAR_ROOT='$ROOT' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' IHAR_STORE='$IHAR_STORE' '$ROOT/ihar.sh' homes clean"
kill "$active_runtime_pid" 2>/dev/null || true
wait "$active_runtime_pid" 2>/dev/null || true
assert_exit "clean exact state runtimes" 0 \
  bash -c "cd '$PROJECT'; IHAR_ROOT='$ROOT' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' IHAR_STORE='$IHAR_STORE' '$ROOT/ihar.sh' homes clean '$NAMED_ID'"
assert_exit "unknown state id is usage" 2 \
  bash -c "cd '$PROJECT'; IHAR_ROOT='$ROOT' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' IHAR_STORE='$IHAR_STORE' '$ROOT/ihar.sh' homes clean missing"
assert_exit "current persistent state survives" 0 test -f "$CURRENT_STATE/st/claude/sentinel"
assert_exit "named persistent state survives" 0 test -f "$NAMED_STATE/st/codex/sentinel"
assert_exit "orphan state survives" 0 test -d "$ORPHAN_STATE"
assert_exit "current expired runtime is removed by marker age" 1 test -d "$CURRENT_STATE/r/$CURRENT_OLD"
assert_exit "named expired runtime is removed by marker age" 1 test -d "$NAMED_STATE/r/$NAMED_OLD"
assert_exit "active expired runtime survives" 0 test -d "$CURRENT_STATE/r/$ACTIVE_OLD"
assert_exit "recent marker runtime survives old directory mtime" 0 test -d "$CURRENT_STATE/r/$RECENT_RUNTIME"
assert_eq "deleted runtime is removed from marker" "False" \
  "$(python3 -c 'import json,sys; print("aaaaaaaa" in json.load(open(sys.argv[1]))["runtimes"])' "$CURRENT_STATE/home.json")"

record_expired_runtime() { # <marker> <hashes...>
  python3 - "$@" <<'PY'
import json, sys
path, *hashes = sys.argv[1:]
old = "2020-01-01T00:00:00Z"
marker = json.load(open(path, encoding="utf-8"))
for runtime_hash in hashes:
    marker["runtimes"][runtime_hash] = {
        "profile": "standard", "created": old, "last_used": old,
    }
with open(path, "w", encoding="utf-8") as handle:
    json.dump(marker, handle)
PY
}

# Cleanup must upgrade an expired pre-manifest owner before removing its runtime.
# History and every SQLite family member are independent loss-sensitive bytes.
CLEAN_UPGRADE_PROJECT="$IHAR_TEST_TMP/clean-upgrade-project"
mkdir -p "$CLEAN_UPGRADE_PROJECT"
CLEAN_UPGRADE_STATE="$(ihar_state_setup "$CLEAN_UPGRADE_PROJECT")"
CLEAN_UPGRADE_ID="$(basename "$CLEAN_UPGRADE_STATE")"
CLEAN_UPGRADE_HASH=12121212
CLEAN_UPGRADE_RUNTIME="$CLEAN_UPGRADE_STATE/r/$CLEAN_UPGRADE_HASH/codex"
mkdir -p "$CLEAN_UPGRADE_RUNTIME"
printf 'expired history\n' > "$CLEAN_UPGRADE_RUNTIME/history.jsonl"
printf 'expired sqlite\n' > "$CLEAN_UPGRADE_RUNTIME/state_5.sqlite"
printf 'expired wal\n' > "$CLEAN_UPGRADE_RUNTIME/state_5.sqlite-wal"
printf 'expired shm\n' > "$CLEAN_UPGRADE_RUNTIME/state_5.sqlite-shm"
record_expired_runtime "$CLEAN_UPGRADE_STATE/home.json" "$CLEAN_UPGRADE_HASH"
assert_exit "cleanup upgrades expired materialized state before deletion" 0 \
  bash -c "cd '$PROJECT'; IHAR_ROOT='$ROOT' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' IHAR_STORE='$IHAR_STORE' '$ROOT/ihar.sh' homes clean '$CLEAN_UPGRADE_ID'"
assert_exit "upgraded expired runtime is removed" 1 test -d "$CLEAN_UPGRADE_STATE/r/$CLEAN_UPGRADE_HASH"
assert_eq "cleanup preserves expired history canonically" "expired history" \
  "$(cat "$CLEAN_UPGRADE_STATE/st/codex/history.jsonl")"
assert_eq "cleanup preserves expired SQLite canonically" "expired sqlite" \
  "$(cat "$CLEAN_UPGRADE_STATE/st/codex/state_5.sqlite")"
assert_eq "cleanup preserves expired SQLite WAL canonically" "expired wal" \
  "$(cat "$CLEAN_UPGRADE_STATE/st/codex/state_5.sqlite-wal")"
assert_eq "cleanup preserves expired SQLite SHM canonically" "expired shm" \
  "$(cat "$CLEAN_UPGRADE_STATE/st/codex/state_5.sqlite-shm")"

# Two possible materialized owners cannot be merged or guessed. Cleanup fails closed
# and leaves both candidates available for operator recovery.
CLEAN_AMBIG_PROJECT="$IHAR_TEST_TMP/clean-ambiguous-project"
mkdir -p "$CLEAN_AMBIG_PROJECT"
CLEAN_AMBIG_STATE="$(ihar_state_setup "$CLEAN_AMBIG_PROJECT")"
CLEAN_AMBIG_ID="$(basename "$CLEAN_AMBIG_STATE")"
mkdir -p "$CLEAN_AMBIG_STATE/r/13131313/codex" \
  "$CLEAN_AMBIG_STATE/r/14141414/codex/sessions"
printf 'first owner\n' > "$CLEAN_AMBIG_STATE/r/13131313/codex/history.jsonl"
printf 'second owner\n' > "$CLEAN_AMBIG_STATE/r/14141414/codex/sessions/session.jsonl"
record_expired_runtime "$CLEAN_AMBIG_STATE/home.json" 13131313 14141414
assert_exit "cleanup fails closed on ambiguous materialized owners" 3 \
  bash -c "cd '$PROJECT'; IHAR_ROOT='$ROOT' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' IHAR_STORE='$IHAR_STORE' '$ROOT/ihar.sh' homes clean '$CLEAN_AMBIG_ID'"
assert_eq "ambiguous history owner survives cleanup" "first owner" \
  "$(cat "$CLEAN_AMBIG_STATE/r/13131313/codex/history.jsonl")"
assert_eq "ambiguous session owner survives cleanup" "second owner" \
  "$(cat "$CLEAN_AMBIG_STATE/r/14141414/codex/sessions/session.jsonl")"

# An opaque active vendor candidate makes quiescence unknowable. The transactional
# upgrade refuses it, so cleanup must preserve the only history copy.
CLEAN_OPAQUE_PROJECT="$IHAR_TEST_TMP/clean-opaque-project"
mkdir -p "$CLEAN_OPAQUE_PROJECT"
CLEAN_OPAQUE_STATE="$(ihar_state_setup "$CLEAN_OPAQUE_PROJECT")"
CLEAN_OPAQUE_ID="$(basename "$CLEAN_OPAQUE_STATE")"
CLEAN_OPAQUE_HASH=15151515
mkdir -p "$CLEAN_OPAQUE_STATE/r/$CLEAN_OPAQUE_HASH/codex"
printf 'opaque owner\n' > "$CLEAN_OPAQUE_STATE/r/$CLEAN_OPAQUE_HASH/codex/history.jsonl"
record_expired_runtime "$CLEAN_OPAQUE_STATE/home.json" "$CLEAN_OPAQUE_HASH"
opaque_ready="$IHAR_TEST_TMP/clean-opaque-ready"
bash -c 'exec -a codex python3 -c '\''import ctypes,pathlib,sys,time; assert ctypes.CDLL(None).prctl(4,0,0,0,0) == 0; pathlib.Path(sys.argv[1]).touch(); time.sleep(30)'\'' "$1"' _ \
  "$opaque_ready" &
opaque_pid=$!
while [[ ! -e "$opaque_ready" ]]; do :; done
assert_exit "cleanup fails closed on an opaque active vendor candidate" 3 \
  bash -c "cd '$PROJECT'; IHAR_ROOT='$ROOT' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' IHAR_STORE='$IHAR_STORE' '$ROOT/ihar.sh' homes clean '$CLEAN_OPAQUE_ID'"
kill "$opaque_pid" 2>/dev/null || true
wait "$opaque_pid" 2>/dev/null || true
assert_eq "opaque active materialized history survives cleanup" "opaque owner" \
  "$(cat "$CLEAN_OPAQUE_STATE/r/$CLEAN_OPAQUE_HASH/codex/history.jsonl")"
assert_exit "opaque cleanup failure publishes no canonical state" 1 \
  test -e "$CLEAN_OPAQUE_STATE/st/codex/history.jsonl"

# Link-only runtimes still contain configuration bytes and can be selected by a
# live vendor. Unreadable process evidence is uncertainty, not permission to delete.
CLEAN_LINK_ONLY_PROJECT="$IHAR_TEST_TMP/clean-link-only-project"
mkdir -p "$CLEAN_LINK_ONLY_PROJECT"
CLEAN_LINK_ONLY_STATE="$(ihar_state_setup "$CLEAN_LINK_ONLY_PROJECT")"
CLEAN_LINK_ONLY_ID="$(basename "$CLEAN_LINK_ONLY_STATE")"
CLEAN_LINK_ONLY_HASH=16161616
CLEAN_LINK_ONLY_RUNTIME="$CLEAN_LINK_ONLY_STATE/r/$CLEAN_LINK_ONLY_HASH/codex"
mkdir -p "$CLEAN_LINK_ONLY_RUNTIME"
printf 'runtime config stays\n' > "$CLEAN_LINK_ONLY_RUNTIME/config.toml"
ihar_link_runtime codex "$CLEAN_LINK_ONLY_RUNTIME" "$CLEAN_LINK_ONLY_STATE" >/dev/null 2>&1
record_expired_runtime "$CLEAN_LINK_ONLY_STATE/home.json" "$CLEAN_LINK_ONLY_HASH"
link_only_ready="$IHAR_TEST_TMP/clean-link-only-ready"
bash -c 'cd "$1" && exec -a codex python3 -c '\''import ctypes,pathlib,sys,time; assert ctypes.CDLL(None).prctl(4,0,0,0,0) == 0; pathlib.Path(sys.argv[1]).touch(); time.sleep(30)'\'' "$2"' _ \
  "$CLEAN_LINK_ONLY_RUNTIME" "$link_only_ready" &
link_only_pid=$!
while [[ ! -e "$link_only_ready" ]]; do :; done
assert_exit "cleanup fails closed on an opaque active link-only runtime" 3 \
  bash -c "cd '$PROJECT'; IHAR_ROOT='$ROOT' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' IHAR_STORE='$IHAR_STORE' '$ROOT/ihar.sh' homes clean '$CLEAN_LINK_ONLY_ID'"
kill "$link_only_pid" 2>/dev/null || true
wait "$link_only_pid" 2>/dev/null || true
assert_eq "opaque active link-only runtime bytes survive cleanup" "runtime config stays" \
  "$(cat "$CLEAN_LINK_ONLY_RUNTIME/config.toml")"

LOCKED_PROJECT="$IHAR_TEST_TMP/locked-clean-project"
mkdir -p "$LOCKED_PROJECT"
LOCKED_STATE="$(ihar_state_setup "$LOCKED_PROJECT")"
LOCKED_ID="$(basename "$LOCKED_STATE")"
lock_ready="$IHAR_TEST_TMP/clean-lock-ready"
bash -c 'exec {fd}>"$1/.ihar.lock"; flock -x "$fd"; : > "$2"; sleep 30' _ \
  "$LOCKED_STATE" "$lock_ready" &
clean_lock_pid=$!
while [[ ! -e "$lock_ready" ]]; do :; done
assert_exit "runtime cleanup requires the state lock" 3 \
  bash -c "cd '$PROJECT'; IHAR_CLEAN_LOCK_TIMEOUT=1 IHAR_ROOT='$ROOT' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' IHAR_STORE='$IHAR_STORE' '$ROOT/ihar.sh' homes clean '$LOCKED_ID'"
kill "$clean_lock_pid" 2>/dev/null || true
wait "$clean_lock_pid" 2>/dev/null || true

COLLISION_PROJECT="$IHAR_TEST_TMP/collision-project"
mkdir -p "$COLLISION_PROJECT"
COLLISION_ID="$(ihar_home_id "$COLLISION_PROJECT")"
COLLISION_STATE="$IHAR_STATE_ROOT/$COLLISION_ID"
mkdir -p "$COLLISION_STATE/r/11111111/claude"
python3 - "$COLLISION_STATE/home.json" <<'PY'
import json, sys
json.dump({"schema":3,"project_root":"/different/project","created":"2020-01-01T00:00:00Z","vendors":[],"runtimes":{"11111111":{"profile":"standard","created":"2020-01-01T00:00:00Z","last_used":"2020-01-01T00:00:00Z"}},"migrated_from":{}}, open(sys.argv[1], "w", encoding="utf-8"))
PY
assert_exit "current cleanup rejects a colliding project marker" 2 \
  bash -c "cd '$COLLISION_PROJECT'; IHAR_ROOT='$ROOT' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' IHAR_STORE='$IHAR_STORE' '$ROOT/ihar.sh' homes clean"
assert_exit "collision rejection preserves its runtime" 0 test -d "$COLLISION_STATE/r/11111111"

MOVED_PROJECT="$IHAR_TEST_TMP/moved-marker-project"
mkdir -p "$MOVED_PROJECT"
MOVED_ID=44444444
MOVED_STATE="$IHAR_STATE_ROOT/$MOVED_ID"
mkdir -p "$MOVED_STATE/r/55555555/claude"
python3 - "$MOVED_STATE/home.json" "$MOVED_PROJECT" <<'PY'
import json, sys
old = "2020-01-01T00:00:00Z"
json.dump({"schema":3,"project_root":sys.argv[2],"created":old,"vendors":["claude"],"runtimes":{"55555555":{"profile":"standard","created":old,"last_used":old}},"migrated_from":{}}, open(sys.argv[1], "w", encoding="utf-8"))
PY
assert_exit "named cleanup rejects a valid marker moved under the wrong id" 2 \
  bash -c "cd '$PROJECT'; IHAR_ROOT='$ROOT' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' IHAR_STORE='$IHAR_STORE' '$ROOT/ihar.sh' homes clean '$MOVED_ID'"
assert_exit "moved marker rejection preserves its runtime" 0 \
  test -d "$MOVED_STATE/r/55555555"

MALFORMED_ID=22222222
MALFORMED_STATE="$IHAR_STATE_ROOT/$MALFORMED_ID"
mkdir -p "$MALFORMED_STATE/r/33333333/claude"
printf 'broken\n' > "$MALFORMED_STATE/home.json"
assert_exit "named cleanup rejects a malformed marker" 2 \
  bash -c "cd '$PROJECT'; IHAR_ROOT='$ROOT' IHAR_STATE_ROOT='$IHAR_STATE_ROOT' IHAR_STORE='$IHAR_STORE' '$ROOT/ihar.sh' homes clean '$MALFORMED_ID'"
assert_exit "malformed marker rejection preserves its runtime" 0 test -d "$MALFORMED_STATE/r/33333333"

# A state without a readable marker is unattributable, not unwanted.
NOMARKER="$IHAR_STATE_ROOT/no-marker-000000000000"
mkdir -p "$NOMARKER"
IHAR_ASSUME_YES=1 ihar_state_clean_orphans >/dev/null
assert_exit "a markerless state is never auto-pruned" 0 test -d "$NOMARKER"

finish
