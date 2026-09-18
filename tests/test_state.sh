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

IHAR_ROOT="$ROOT"; export IHAR_ROOT
PROJECT="$IHAR_TEST_TMP/My Project"
mkdir -p "$PROJECT"

# --- home id ---------------------------------------------------------------------

id_a="$(ihar_home_id "$PROJECT")"
id_b="$(ihar_home_id "$PROJECT")"
assert_eq "the id is stable for one root" "$id_a" "$id_b"
assert_contains "the basename is sanitised" "$id_a" "my-project-"
assert_eq "the hash is twelve characters" "12" \
  "$(printf '%s' "${id_a##*-}" | wc -c | awk '{print $1-0}')"

other="$(ihar_home_id "$IHAR_TEST_TMP/other")"
assert_exit "a different root gets a different id" 1 test "$id_a" = "$other"

upper="$(ihar_home_id "$IHAR_TEST_TMP/UPPER!!Case")"
assert_contains "runs outside the safe set collapse" "$upper" "upper-case-"

# --- socket path preflight -------------------------------------------------------

assert_exit "a short state path passes the preflight" 0 \
  ihar_state_preflight "$IHAR_TEST_TMP/s"

long="$IHAR_TEST_TMP/$(printf 'x%.0s' {1..120})"
assert_exit "a state path that overflows the socket limit is refused" 2 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/state/state.sh'
           IHAR_SOCKET_PATH_MAX=100 ihar_state_preflight '$long'"

# The LLD's default state root does not fit a Codex daemon socket: measured at 112
# to 120 bytes against a usable sun_path of 107, for every project tried. The
# preflight is what keeps that from becoming a daemon that mysteriously will not
# start, and this asserts the preflight catches it. The layout itself is an open
# decision for the user, since changing it changes an LLD contract.
default_socket="$HOME/.local/state/ihar/$id_a/rt/00000000/codex/app-server-control/app-server-control.sock"
assert_exit "the documented default layout is caught by the preflight" 2 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/state/state.sh'
           ihar_state_preflight '$HOME/.local/state/ihar/$id_a'"
assert_exit "and it is indeed over the platform limit" 1 \
  test "${#default_socket}" -le 107

# --- state tree and marker -------------------------------------------------------

STATE="$(ihar_state_setup "$PROJECT")"
assert_exit "the state tree is created" 0 test -d "$STATE/st/claude"
assert_exit "the runtime parent is created" 0 test -d "$STATE/rt"
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
staging_left="$(find "$STATE/rt" -maxdepth 1 -name '.staging-*' | wc -l)"
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

# --- links -------------------------------------------------------------------------

mkdir -p "$IHAR_STORE/skills" "$IHAR_STORE/hooks"
rt2="$(ihar_runtime_materialise claude "$(ihar_config_hash a b c d e f g h)" "$RENDER")"
assert_exit "a present store entry is linked" 0 test -L "$rt2/skills"
assert_exit "an absent store entry is skipped" 1 test -e "$rt2/router.json"
assert_exit "vendor state is linked out of the runtime home" 0 test -L "$rt2/projects"
assert_eq "vendor state resolves into st/" "$STATE/st/claude/projects" \
  "$(readlink "$rt2/projects")"

# A materialised copy where a link belongs means the entry stopped following the
# store; the repair replaces it.
rm "$rt2/skills"; mkdir "$rt2/skills"; touch "$rt2/skills/stale"
ihar_link_runtime claude "$rt2" "$STATE" 2>/dev/null
assert_exit "a materialised copy is replaced by a link" 0 test -L "$rt2/skills"

ln -sfn /nowhere "$rt2/hooks"
ihar_link_runtime claude "$rt2" "$STATE" 2>/dev/null
assert_eq "a wrong link is repointed" "$IHAR_STORE/hooks" "$(readlink "$rt2/hooks")"

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

# With no marker at all, the hash match is all the evidence icodex ever provides.
NOMARK="$IHAR_TEST_TMP/nomark-state"
mkdir -p "$NOMARK/st/claude"
rm -f "$LEGACY/home.json"
ihar_migrate_vendor claude "$NOMARK" "$PROJECT" >/dev/null 2>&1
assert_exit "a legacy home with no marker migrates on the hash match" 0 \
  test -f "$NOMARK/st/claude/projects/one.jsonl"

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
