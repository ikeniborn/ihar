#!/usr/bin/env bash
# Project state and immutable runtime homes (LLD 2.2, 2.4, 4.1, 4.2, 4.5, 4.6).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
source "$ROOT/lib/core/logging.sh"
source "$ROOT/lib/core/init.sh"
source "$ROOT/lib/core/lock.sh"
source "$ROOT/lib/state/state.sh"
source "$ROOT/lib/state/links.sh"
source "$ROOT/lib/state/runtime.sh"
source "$ROOT/lib/state/migrate.sh"
source "$ROOT/lib/state/gc.sh"

assert_eq "legacy migration is explicit, never hidden in launch" "1" \
  "$(grep -c 'ihar_migrate_vendor ' "$ROOT/lib/cli/commands.sh")"

IHAR_ROOT="$ROOT"; export IHAR_ROOT
PROJECT="$IHAR_TEST_TMP/My Project"
mkdir -p "$PROJECT"

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

h1="$(ihar_config_hash protected standard explicit vendor true aaa bbb 2.1.274)"
h2="$(ihar_config_hash protected standard explicit vendor true aaa bbb 2.1.274)"
assert_eq "the hash is deterministic" "$h1" "$h2"
assert_eq "the hash is eight characters" "8" "$(printf '%s' "$h1" | wc -c | awk '{print $1-0}')"

h3="$(ihar_config_hash standard off off vendor-default false aaa bbb 2.1.274)"
assert_exit "a different profile yields a different hash" 1 test "$h1" = "$h3"
h4="$(ihar_config_hash protected secrets explicit vendor true aaa bbb 2.1.274)"
assert_exit "a different masking level yields a different hash" 1 test "$h1" = "$h4"
h5="$(ihar_config_hash protected standard explicit vendor true aaa bbb 2.1.999)"
assert_exit "a different vendor version yields a different hash" 1 test "$h1" = "$h5"
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
sealed="$(ihar_runtime_materialise claude "$(ihar_config_hash s e a l e d 1 2)" "$RENDER")"
unset -f ihar_seal_runtime
assert_eq "the seal covers the rendered files" "444" \
  "$(stat -c '%a' "$sealed/settings.json")"
# Writability, not an exact mode: the umask decides the group and other bits.
assert_exit "and leaves vendor-written state writable" 0 test -w "$sealed/logs_2.sqlite"

# --- links -------------------------------------------------------------------------

mkdir -p "$IHAR_STORE/skills" "$IHAR_STORE/hooks"
rt2_hash="$(ihar_config_hash a b c d e f g h)"
rt2="$(ihar_runtime_materialise claude "$rt2_hash" "$RENDER")"
assert_exit "a present store entry is linked" 0 test -L "$rt2/skills"
assert_exit "an absent store entry is skipped" 1 test -e "$rt2/router.json"
assert_exit "vendor state is linked out of the runtime home" 0 test -L "$rt2/projects"
assert_eq "vendor state resolves into st/" "$STATE/st/claude/projects" \
  "$(readlink "$rt2/projects")"

# Reusing an already-published runtime verifies rendered files first, then repairs
# every manifest-derived state link. Repair only replaces runtime entries; canonical
# state is never populated from a materialised runtime fork.
printf 'canonical directory\n' > "$STATE/st/claude/projects/canonical"
rm "$rt2/projects"
ihar_runtime_materialise claude "$rt2_hash" "$RENDER" >/dev/null
assert_eq "runtime reuse restores a missing state directory link" \
  "$STATE/st/claude/projects" "$(readlink "$rt2/projects")"

printf 'canonical file\n' > "$STATE/st/claude/history.jsonl"
ln -sfn /nowhere "$rt2/history.jsonl"
ihar_runtime_materialise claude "$rt2_hash" "$RENDER" >/dev/null 2>&1
assert_eq "runtime reuse repoints a wrong state file link" \
  "$STATE/st/claude/history.jsonl" "$(readlink "$rt2/history.jsonl")"

printf 'canonical session\n' > "$STATE/st/claude/sessions/canonical"
rm "$rt2/sessions"
mkdir "$rt2/sessions"
printf 'forked runtime state\n' > "$rt2/sessions/forked"
ihar_runtime_materialise claude "$rt2_hash" "$RENDER" >/dev/null 2>&1
assert_eq "runtime reuse replaces materialised state with its canonical link" \
  "$STATE/st/claude/sessions" "$(readlink "$rt2/sessions")"
assert_eq "state-link repair preserves canonical content" "canonical session" \
  "$(cat "$STATE/st/claude/sessions/canonical")"
assert_exit "state-link repair never copies a runtime fork into canonical state" 1 \
  test -e "$STATE/st/claude/sessions/forked"

# A materialised copy where a link belongs means the entry stopped following the
# store; the repair replaces it.
rm "$rt2/skills"; mkdir "$rt2/skills"; touch "$rt2/skills/stale"
ihar_link_runtime claude "$rt2" "$STATE" 2>/dev/null
assert_exit "a materialised copy is replaced by a link" 0 test -L "$rt2/skills"

ln -sfn /nowhere "$rt2/hooks"
ihar_link_runtime claude "$rt2" "$STATE" 2>/dev/null
assert_eq "a wrong link is repointed" "$IHAR_STORE/hooks" "$(readlink "$rt2/hooks")"

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
manifest_runtime_hash="$(ihar_config_hash manifest reuse state links a b c d)"
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
MANIFEST_LINK_STATE_ADDED="$IHAR_TEST_TMP/manifest-link-state-added"
MANIFEST_MIGRATE_STATE_ADDED="$IHAR_TEST_TMP/manifest-migrate-state-added"
MANIFEST_RUNTIME_ADDED="$IHAR_TEST_TMP/manifest-runtime-added"
mkdir -p "$MANIFEST_LINK_STATE_ADDED/st/codex" \
  "$MANIFEST_MIGRATE_STATE_ADDED/st/codex" "$MANIFEST_RUNTIME_ADDED"
assert_eq "manifest additions reach linker and migration without Bash array edits" \
  "$(state_inventory codex)" "$(migration_inventory codex)"
ihar_runtime_materialise codex "$manifest_runtime_hash" "$RENDER" >/dev/null
assert_eq "runtime reuse links an entry added after publication" \
  "$MANIFEST_LINK_STATE/st/codex/added.jsonl" \
  "$(readlink "$MANIFEST_REUSE_RUNTIME/added.jsonl")"
ihar_link_runtime codex "$MANIFEST_RUNTIME_ADDED" "$MANIFEST_LINK_STATE_ADDED" 2>/dev/null
assert_exit "the added file is linked" 0 test -L "$MANIFEST_RUNTIME_ADDED/added.jsonl"
ihar_migrate_vendor codex "$MANIFEST_MIGRATE_STATE_ADDED" "$MANIFEST_PROJECT" >/dev/null
assert_exit "the added file is migrated" 0 \
  test -f "$MANIFEST_MIGRATE_STATE_ADDED/st/codex/added.jsonl"
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

# A state without a readable marker is unattributable, not unwanted.
NOMARKER="$IHAR_STATE_ROOT/no-marker-000000000000"
mkdir -p "$NOMARKER"
IHAR_ASSUME_YES=1 ihar_state_clean_orphans >/dev/null
assert_exit "a markerless state is never auto-pruned" 0 test -d "$NOMARKER"

finish
