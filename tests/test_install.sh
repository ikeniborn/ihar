#!/usr/bin/env bash
# Install and update (LLD 14.3).
#
# The network is stubbed through the IHAR_DOWNLOAD seam so the real verification,
# extraction and pinning logic runs against local fixtures. What is asserted is the
# part that matters: nothing needs privilege, a digest mismatch is refused, and a
# user's own file on PATH is never replaced.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
export IHAR_ROOT="$ROOT" PYTHONPATH="$ROOT/lib/python"
export IHAR_BIN_DIR="$IHAR_TEST_TMP/bin"
export IHAR_LOCKFILE="$IHAR_TEST_TMP/.ihar-lockfile.json"
export IHAR_NVM="$IHAR_TEST_TMP/nvm"

source "$ROOT/lib/core/logging.sh"
source "$ROOT/lib/core/init.sh"
source "$ROOT/lib/core/lock.sh"
source "$ROOT/lib/store/lockfile.sh"
source "$ROOT/lib/store/assets.sh"
source "$ROOT/lib/store/migrate.sh"
source "$ROOT/lib/store/install.sh"

export IHAR_CLAUDE_BIN="$IHAR_NVM/npm-global/bin/claude"
export IHAR_CODEX_BIN="$IHAR_STORE/bin/codex"
export IHAR_CLAUDE_ACP_BIN="$IHAR_STORE/acp/bin/claude-agent-acp"
export IHAR_CODEX_ACP_BIN="$IHAR_STORE/acp/bin/codex-acp"

# --- copy-only legacy store migration -----------------------------------------------

LEGACY_STORE="$IHAR_TEST_TMP/legacy-store"
mkdir -p "$LEGACY_STORE/hooks" "$LEGACY_STORE/skills" "$LEGACY_STORE/config" "$LEGACY_STORE/state"
printf 'old hook\n' > "$LEGACY_STORE/hooks/old"
printf 'old skill\n' > "$LEGACY_STORE/skills/old"
printf 'do not copy\n' > "$LEGACY_STORE/config/settings.json"
printf 'do not copy\n' > "$LEGACY_STORE/state/session.jsonl"
printf '{"schema":1,"release_lock_sha256":"%064d","installed_at":"2026-09-20T00:00:00Z","components":{}}\n' 0 > "$LEGACY_STORE/install-receipt.json"
legacy_before="$(find "$LEGACY_STORE" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"

lock_ready="$IHAR_TEST_TMP/store-lock-ready"
bash -c 'exec {fd}>"$1.ihar-lifecycle.lock"; flock -s "$fd"; : > "$2"; sleep 30' _ \
  "$LEGACY_STORE" "$lock_ready" &
legacy_lock_pid=$!
while [[ ! -e "$lock_ready" ]]; do :; done
assert_exit "store migration refuses a held lifecycle lock" 3 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/init.sh'; source '$ROOT/lib/core/lock.sh'; source '$ROOT/lib/store/assets.sh'; source '$ROOT/lib/store/migrate.sh'; IHAR_LEGACY_STORE='$LEGACY_STORE' IHAR_ROOT='$ROOT' IHAR_STORE='$IHAR_STORE/migrated' IHAR_STORE_MIGRATION_LOCK_TIMEOUT=1 ihar_store_migrate"
kill "$legacy_lock_pid" 2>/dev/null || true
wait "$legacy_lock_pid" 2>/dev/null || true
assert_exit "lock refusal copies nothing" 1 test -e "$IHAR_STORE/migrated/hooks/old"

mkdir -p "$IHAR_STORE/migrated"
assert_exit "stable store migration succeeds" 0 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/init.sh'; source '$ROOT/lib/core/lock.sh'; source '$ROOT/lib/store/assets.sh'; source '$ROOT/lib/store/migrate.sh'; IHAR_LEGACY_STORE='$LEGACY_STORE' IHAR_ROOT='$ROOT' IHAR_STORE='$IHAR_STORE/migrated' ihar_store_migrate"
assert_exit "eligible hooks are copied" 0 test -f "$IHAR_STORE/migrated/hooks/old"
assert_exit "eligible skills are copied" 0 test -f "$IHAR_STORE/migrated/skills/old"
assert_exit "old receipt is copied" 0 test -f "$IHAR_STORE/migrated/install-receipt.json"
assert_exit "legacy configuration is excluded" 1 test -e "$IHAR_STORE/migrated/config/settings.json"
assert_exit "legacy state is excluded" 1 test -e "$IHAR_STORE/migrated/state/session.jsonl"
assert_eq "legacy source stays byte-identical" "$legacy_before" \
  "$(find "$LEGACY_STORE" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"

RACE_STORE="$IHAR_TEST_TMP/legacy-store-race"
RACE_TARGET="$IHAR_STORE/migrated-race"
RACE_BIN="$IHAR_TEST_TMP/store-race-bin"
mkdir -p "$RACE_STORE/hooks" "$RACE_BIN"
printf 'before\n' > "$RACE_STORE/hooks/old"
cat > "$RACE_BIN/rsync" <<'EOF'
#!/usr/bin/env bash
/usr/bin/rsync "$@" || exit
if [[ ! -e "$IHAR_TEST_RACE_DONE" ]]; then
  : > "$IHAR_TEST_RACE_DONE"
  printf 'during copy\n' >> "$IHAR_TEST_RACE_SOURCE/hooks/old"
fi
EOF
chmod +x "$RACE_BIN/rsync"
assert_exit "a changing legacy store discards its stage" 3 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/init.sh'; source '$ROOT/lib/core/lock.sh'; source '$ROOT/lib/store/assets.sh'; source '$ROOT/lib/store/migrate.sh'; PATH='$RACE_BIN':\"\$PATH\" IHAR_TEST_RACE_SOURCE='$RACE_STORE' IHAR_TEST_RACE_DONE='$IHAR_TEST_TMP/store-race-done' IHAR_LEGACY_STORE='$RACE_STORE' IHAR_ROOT='$ROOT' IHAR_STORE='$RACE_TARGET' ihar_store_migrate"
assert_exit "an unstable store publishes no eligible entry" 1 test -e "$RACE_TARGET/hooks/old"

FINGERPRINT_STORE="$IHAR_TEST_TMP/legacy-fingerprint"
mkdir -p "$FINGERPRINT_STORE/hooks"
ln -s first "$FINGERPRINT_STORE/hooks/link"
fingerprint_before="$(_ihar_store_full_fingerprint "$FINGERPRINT_STORE" hooks)"
ln -sfn second "$FINGERPRINT_STORE/hooks/link"
fingerprint_after="$(_ihar_store_full_fingerprint "$FINGERPRINT_STORE" hooks)"
assert_exit "full migration fingerprint includes symlink targets" 1 \
  test "$fingerprint_before" = "$fingerprint_after"

# Every source must be staged and validated before one activation. If the second
# source changes, bytes from the first source must not become active.
MULTI_A="$IHAR_TEST_TMP/legacy-multi-a"
MULTI_B="$IHAR_TEST_TMP/legacy-multi-b"
MULTI_TARGET="$IHAR_STORE/migrated-multi"
MULTI_BIN="$IHAR_TEST_TMP/store-multi-bin"
mkdir -p "$MULTI_A/hooks" "$MULTI_B/skills" "$MULTI_TARGET/hooks" "$MULTI_BIN"
printf 'new hook\n' > "$MULTI_A/hooks/entry"
printf 'new skill\n' > "$MULTI_B/skills/entry"
printf 'active hook\n' > "$MULTI_TARGET/hooks/entry"
cat > "$MULTI_BIN/rsync" <<'EOF'
#!/usr/bin/env bash
/usr/bin/rsync "$@" || exit
if [[ "$*" == *"$IHAR_TEST_MUTATE_SOURCE"* && ! -e "$IHAR_TEST_MUTATE_DONE" ]]; then
  : > "$IHAR_TEST_MUTATE_DONE"
  printf 'changed\n' >> "$IHAR_TEST_MUTATE_SOURCE/skills/entry"
fi
EOF
chmod +x "$MULTI_BIN/rsync"
assert_exit "all store sources validate before one activation" 3 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/init.sh'; source '$ROOT/lib/core/lock.sh'; source '$ROOT/lib/store/assets.sh'; source '$ROOT/lib/store/migrate.sh'; PATH='$MULTI_BIN':\"\$PATH\" IHAR_TEST_MUTATE_SOURCE='$MULTI_B' IHAR_TEST_MUTATE_DONE='$IHAR_TEST_TMP/multi-done' IHAR_LEGACY_STORE='$MULTI_A:$MULTI_B' IHAR_ROOT='$ROOT' IHAR_STORE='$MULTI_TARGET' ihar_store_migrate"
assert_eq "a late source failure leaves the active store untouched" "active hook" \
  "$(cat "$MULTI_TARGET/hooks/entry")"
assert_exit "a late source failure publishes no second-source bytes" 1 \
  test -e "$MULTI_TARGET/skills/entry"

# Activation failure rolls every published path back. A failed restore keeps the
# recovery backup and reports its location instead of destroying recoverable data.
ROLL_SOURCE="$IHAR_TEST_TMP/legacy-roll"
ROLL_TARGET="$IHAR_STORE/migrated-roll"
mkdir -p "$ROLL_SOURCE/hooks" "$ROLL_SOURCE/skills" "$ROLL_TARGET/hooks" "$ROLL_TARGET/skills"
printf 'new hook\n' > "$ROLL_SOURCE/hooks/entry"
printf 'new skill\n' > "$ROLL_SOURCE/skills/entry"
printf 'old hook\n' > "$ROLL_TARGET/hooks/entry"
printf 'old skill\n' > "$ROLL_TARGET/skills/entry"
assert_exit "store publication failure rolls back every activated path" 1 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/init.sh'; source '$ROOT/lib/core/lock.sh'; source '$ROOT/lib/store/assets.sh'; source '$ROOT/lib/store/migrate.sh'; ihar_store_migration_move() { if [[ \"\$1\" == */.ihar-store-migrate-stage-*/skills && \"\$2\" == '$ROLL_TARGET/skills' ]]; then return 1; fi; command mv -- \"\$@\"; }; IHAR_LEGACY_STORE='$ROLL_SOURCE' IHAR_ROOT='$ROOT' IHAR_STORE='$ROLL_TARGET' ihar_store_migrate"
assert_eq "publication rollback restores old hooks" "old hook" "$(cat "$ROLL_TARGET/hooks/entry")"
assert_eq "publication rollback restores old skills" "old skill" "$(cat "$ROLL_TARGET/skills/entry")"

incomplete_status=0
incomplete_out="$(bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/init.sh'; source '$ROOT/lib/core/lock.sh'; source '$ROOT/lib/store/assets.sh'; source '$ROOT/lib/store/migrate.sh'; ihar_store_migration_move() { if [[ \"\$1\" == */.ihar-store-migrate-stage-*/skills && \"\$2\" == '$ROLL_TARGET/skills' ]]; then return 1; fi; if [[ \"\$1\" == */.ihar-store-migrate-backup-*/hooks && \"\$2\" == '$ROLL_TARGET/hooks' ]]; then return 1; fi; command mv -- \"\$@\"; }; IHAR_LEGACY_STORE='$ROLL_SOURCE' IHAR_ROOT='$ROOT' IHAR_STORE='$ROLL_TARGET' ihar_store_migrate" 2>&1)" \
  || incomplete_status=$?
assert_eq "incomplete store rollback is fail-closed" "3" "$incomplete_status"
assert_contains "incomplete rollback reports retained recovery backup" \
  "$incomplete_out" "recovery backup retained at"
recovery_store_backup="$(sed -n 's/.*recovery backup retained at //p' <<<"$incomplete_out" | tail -1)"
assert_exit "incomplete rollback preserves recoverable old hooks" 0 \
  test -f "$recovery_store_backup/hooks/entry"

# --- a stub release, and a stub fetcher that serves it --------------------------------

RELEASE_DIR="$IHAR_TEST_TMP/releases"
# The npm platform package's shape, because that is what the lockfile now pins: the
# executable, the code-mode host the CLI needs beside it, and the sibling resource trees.
CODEX_PREFIX="package/vendor/x86_64-unknown-linux-musl"
mkdir -p "$RELEASE_DIR/payload/$CODEX_PREFIX/bin" \
         "$RELEASE_DIR/payload/$CODEX_PREFIX/codex-path" \
         "$RELEASE_DIR/payload/$CODEX_PREFIX/codex-resources"
printf '#!/bin/sh\necho stub codex\n' > "$RELEASE_DIR/payload/$CODEX_PREFIX/bin/codex"
printf '#!/bin/sh\necho stub host\n' > "$RELEASE_DIR/payload/$CODEX_PREFIX/bin/codex-code-mode-host"
printf 'stub\n' > "$RELEASE_DIR/payload/$CODEX_PREFIX/codex-path/rg"
printf 'stub\n' > "$RELEASE_DIR/payload/$CODEX_PREFIX/codex-resources/bwrap"
chmod +x "$RELEASE_DIR/payload/$CODEX_PREFIX/bin/"*
tar -czf "$RELEASE_DIR/codex.tar.gz" -C "$RELEASE_DIR/payload" . 2>/dev/null
RELEASE_SHA="$(sha256sum "$RELEASE_DIR/codex.tar.gz" | cut -d' ' -f1)"

cat > "$IHAR_TEST_TMP/fetch" <<EOF
#!/usr/bin/env bash
# Serves the stub release for any URL; the test is about verification, not transport.
cp "$RELEASE_DIR/codex.tar.gz" "\$2"
EOF
chmod +x "$IHAR_TEST_TMP/fetch"
export IHAR_DOWNLOAD="$IHAR_TEST_TMP/fetch"

write_lock() {
  printf '{"schema":1,%s}\n' "$1" > "$IHAR_LOCKFILE"
}

# --- the store is built, and the tracked trees are pinned --------------------------------

cp "$ROOT/.ihar-lockfile.json" "$IHAR_LOCKFILE"
before_lock="$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"
ihar_install_store >/dev/null 2>&1
ihar_prepare_mutable_store "$IHAR_STORE"
assert_exit "the store tree is created" 0 test -d "$IHAR_STORE/hooks/_shared"
assert_exit "manifests are copied in" 0 test -f "$IHAR_STORE/manifests/hooks.json"
assert_eq "the auth directory is owner-only" "700" "$(stat -c '%a' "$IHAR_STORE/auth")"
assert_exit "fresh install creates the Claude plugin owner" 0 \
  test -d "$IHAR_STORE/plugins/claude"
assert_exit "fresh install creates the Codex plugin owner" 0 \
  test -d "$IHAR_STORE/plugins/codex"
assert_exit "fresh install leaves absent Claude credentials for the vendor to create" 1 \
  test -e "$IHAR_STORE/auth/claude/.credentials.json"
assert_exit "fresh install leaves absent Codex auth for the vendor to create" 1 \
  test -e "$IHAR_STORE/auth/codex/auth.json"
assert_eq "the mutable inventory is explicit" \
  $'auth/claude/.credentials.json\t.credentials.json\tfile\nauth/codex/auth.json\tauth.json\tfile\nplugins/claude\tplugins\tdirectory\nplugins/codex\tplugins\tdirectory' \
  "$(ihar_mutable_inventory all | sort)"

printf 'preserve auth\n' > "$IHAR_STORE/auth/claude/.credentials.json"
printf 'preserve plugin\n' > "$IHAR_STORE/plugins/claude/sentinel"
ihar_prepare_mutable_store "$IHAR_STORE"
assert_eq "mutable store preparation preserves existing auth" "preserve auth" \
  "$(cat "$IHAR_STORE/auth/claude/.credentials.json")"
assert_eq "mutable store preparation preserves existing plugins" "preserve plugin" \
  "$(cat "$IHAR_STORE/plugins/claude/sentinel")"

MALFORMED_MUTABLE_ROOT="$IHAR_TEST_TMP/malformed-mutable-root"
MALFORMED_MUTABLE_STORE="$IHAR_TEST_TMP/malformed-mutable-store"
mkdir -p "$MALFORMED_MUTABLE_ROOT/manifests" "$MALFORMED_MUTABLE_STORE"
printf 'not valid JSON\n' > "$MALFORMED_MUTABLE_ROOT/manifests/mutable-links.json"
printf 'active bytes\n' > "$MALFORMED_MUTABLE_STORE/sentinel"
malformed_mutable_before="$(sha256sum "$MALFORMED_MUTABLE_STORE/sentinel" | cut -d' ' -f1)"
assert_exit "a malformed mutable inventory aborts store preparation" 3 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/init.sh'; source '$ROOT/lib/store/assets.sh'; PYTHONPATH='$ROOT/lib/python' IHAR_ROOT='$MALFORMED_MUTABLE_ROOT' ihar_prepare_mutable_store '$MALFORMED_MUTABLE_STORE'"
assert_eq "a malformed mutable inventory preserves the active store" \
  "$malformed_mutable_before" \
  "$(sha256sum "$MALFORMED_MUTABLE_STORE/sentinel" | cut -d' ' -f1)"

mutable_tree_fingerprint() { # <root>
  local root="$1"
  {
    find "$root" -mindepth 1 -printf '%P\t%y\t%m\t%l\n' | sort
    find "$root" -type f -print0 | sort -z | xargs -0 -r sha256sum
  } | sha256sum | cut -d' ' -f1
}

write_noncanonical_mutable_manifest() { # <path> <case>
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

assert_noncanonical_mutable_store_preserved() { # <case>
  local case_name="$1" case_root store store_before inventory_status=0 prepare_status=0
  case_root="$IHAR_TEST_TMP/install-mutable-path-$case_name"
  store="$case_root/store"
  mkdir -p "$case_root/manifests" "$store"
  write_noncanonical_mutable_manifest \
    "$case_root/manifests/mutable-links.json" "$case_name"
  printf 'store stays\n' > "$store/sentinel"

  store_before="$(mutable_tree_fingerprint "$store")"
  IHAR_ROOT="$case_root" ihar_mutable_inventory all >/dev/null 2>&1 \
    || inventory_status=$?
  IHAR_ROOT="$case_root" ihar_prepare_mutable_store "$store" >/dev/null 2>&1 \
    || prepare_status=$?
  assert_eq "$case_name mutable path is rejected by the inventory query" \
    "3" "$inventory_status"
  assert_eq "$case_name mutable path aborts store preparation" "3" "$prepare_status"
  assert_eq "$case_name mutable path leaves the store unchanged" \
    "$store_before" "$(mutable_tree_fingerprint "$store")"
}

for case_name in auth-dot duplicate-plugin-target repeated-separator trailing-separator; do
  assert_noncanonical_mutable_store_preserved "$case_name"
done

assert_invalid_mutable_store_preserved() { # <topology>
  local topology="$1" case_root store outside store_before outside_before status=0
  case_root="$IHAR_TEST_TMP/install-mutable-$topology"
  store="$case_root/store"
  outside="$case_root/outside"
  mkdir -p "$store" "$outside"
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

  store_before="$(mutable_tree_fingerprint "$store")"
  outside_before="$(mutable_tree_fingerprint "$outside")"
  ihar_prepare_mutable_store "$store" >/dev/null 2>&1 || status=$?
  assert_eq "$topology mutable source is rejected before preparation" "3" "$status"
  assert_eq "$topology rejection leaves the store unchanged" \
    "$store_before" "$(mutable_tree_fingerprint "$store")"
  assert_eq "$topology rejection leaves outside unchanged" \
    "$outside_before" "$(mutable_tree_fingerprint "$outside")"
}

for topology in auth-parent-symlink auth-leaf-symlink credentials-directory plugin-file; do
  assert_invalid_mutable_store_preserved "$topology"
done

pinned="$(python3 -c "
import json,sys
print(len(json.load(open(sys.argv[1])).get('hooks', {})))" "$IHAR_LOCKFILE")"
assert_exit "every hook file is pinned, not a curated list" 0 test "$pinned" -ge 5
assert_eq "install never rewrites release lock" "$before_lock" \
  "$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"

# The store is copied, never linked: a link would put the agent's writable checkout
# back on the path a hook is loaded from.
assert_exit "the store is a copy, not a link into the checkout" 1 test -L "$IHAR_STORE/hooks"

# Conformance executes staged hooks and binaries, but reads mutable authentication
# from the stable active store that owns it.
CONFORMANCE_STAGE="$IHAR_TEST_TMP/conformance-stage"
CONFORMANCE_ACTIVE="$IHAR_TEST_TMP/conformance-active"
CONFORMANCE_ARGS="$IHAR_TEST_TMP/conformance-args"
mkdir -p "$CONFORMANCE_STAGE/bin" "$CONFORMANCE_STAGE/nvm/bin" \
  "$CONFORMANCE_ACTIVE/auth/claude" "$CONFORMANCE_ACTIVE/auth/codex"
printf '#!/bin/sh\nexit 0\n' > "$CONFORMANCE_STAGE/nvm/bin/claude"
printf '#!/bin/sh\nexit 0\n' > "$CONFORMANCE_STAGE/bin/codex"
chmod +x "$CONFORMANCE_STAGE/nvm/bin/claude" "$CONFORMANCE_STAGE/bin/codex"
(
  export IHAR_STORE="$CONFORMANCE_STAGE"
  export IHAR_CLAUDE_BIN="$CONFORMANCE_STAGE/nvm/bin/claude"
  export IHAR_CODEX_BIN="$CONFORMANCE_STAGE/bin/codex"
  ihar_python() { printf '%s\n' "$*" >> "$CONFORMANCE_ARGS"; }
  ihar_install_conformance "$CONFORMANCE_ACTIVE"
)
assert_contains "install conformance keeps the staged store as its runtime source" \
  "$(cat "$CONFORMANCE_ARGS")" \
  "ihar.conformance.run claude $CONFORMANCE_STAGE/nvm/bin/claude $CONFORMANCE_STAGE"
assert_contains "install conformance reads auth from the stable active store" \
  "$(cat "$CONFORMANCE_ARGS")" "--auth-store $CONFORMANCE_ACTIVE"
assert_contains "install conformance validates the immutable release lock" \
  "$(cat "$CONFORMANCE_ARGS")" "--lockfile $IHAR_LOCKFILE"
assert_contains "install conformance protects the stable active store" \
  "$(cat "$CONFORMANCE_ARGS")" "--protected-store $CONFORMANCE_ACTIVE"
assert_exit "install conformance does not copy mutable auth into its stage" 1 \
  test -e "$CONFORMANCE_STAGE/auth"

# Required asset inputs are checked before an install transaction can touch the
# active store. Optional sources stay visible for check collection without blocking
# publication.
ASSET_ROOT="$IHAR_TEST_TMP/assets-root"
ASSET_STAGE="$IHAR_TEST_TMP/assets-stage"
mkdir -p "$ASSET_ROOT/manifests" "$ASSET_ROOT/hooks"
printf '{"schema":1,"entries":[{"vendor":"common","source":"hooks","target":"hooks","kind":"directory","required":true,"runtime":true},{"vendor":"claude","source":"extensions","target":"extensions","kind":"directory","required":false,"runtime":true}]}\n' \
  > "$ASSET_ROOT/manifests/assets.json"
printf 'active asset generation\n' > "$IHAR_STORE/asset-generation"
asset_fingerprint_before="$(sha256sum "$IHAR_STORE/asset-generation" | cut -d' ' -f1)"
rm -rf "$ASSET_ROOT/hooks"
assert_exit "a missing required asset aborts before transaction publication" 3 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/init.sh'; source '$ROOT/lib/core/lock.sh'; source '$ROOT/lib/store/assets.sh'; source '$ROOT/lib/store/install.sh'; PYTHONPATH='$ROOT/lib/python' IHAR_ROOT='$ASSET_ROOT' IHAR_STORE='$IHAR_STORE' IHAR_NVM='$IHAR_NVM' ihar_install_transaction install"
assert_eq "a missing required asset preserves the active store fingerprint" \
  "$asset_fingerprint_before" "$(sha256sum "$IHAR_STORE/asset-generation" | cut -d' ' -f1)"
mkdir -p "$ASSET_ROOT/hooks"
optional_assets="$(IHAR_ROOT="$ASSET_ROOT" ihar_asset_install "$ASSET_STAGE")"
assert_contains "a missing optional asset emits a stable diagnostic" "$optional_assets" \
  $'optional\tmissing\textensions\textensions'
assert_exit "a missing optional asset does not block asset staging" 0 test -d "$ASSET_STAGE/hooks"

# --- the command on PATH -------------------------------------------------------------------

ihar_install_command >/dev/null 2>&1
assert_exit "a symlink is created" 0 test -L "$IHAR_BIN_DIR/ihar"
assert_eq "and it points at this checkout" "$ROOT/ihar.sh" "$(readlink "$IHAR_BIN_DIR/ihar")"
assert_exit "installing twice is idempotent" 0 ihar_install_command

# A user with their own ihar on PATH has it for a reason.
rm -f "$IHAR_BIN_DIR/ihar"
printf '#!/bin/sh\necho mine\n' > "$IHAR_BIN_DIR/ihar"
out="$(ihar_install_command 2>&1)"
assert_contains "a stranger's file is left alone" "$out" "leaving it alone"
assert_exit "and it is still a regular file" 1 test -L "$IHAR_BIN_DIR/ihar"
assert_eq "with its contents intact" "#!/bin/sh" "$(head -1 "$IHAR_BIN_DIR/ihar")"
rm -f "$IHAR_BIN_DIR/ihar"

# --- nothing needs privilege -----------------------------------------------------------------
#
# A harness that asks for root to install is a harness people install as root, and
# everything it runs afterwards inherits that.

for path in "$IHAR_STORE" "$IHAR_STATE_ROOT" "$IHAR_BIN_DIR" "$IHAR_NVM"; do
  case "$path" in
    /usr/*|/etc/*|/opt/*|/var/*) FAIL=$((FAIL+1)); echo "FAIL: $path is outside the user's own directories" ;;
    *) PASS=$((PASS+1)); echo "PASS [$path is user-owned]" ;;
  esac
done
# Commands, not comments: the file says the word "sudo" while explaining why it
# never runs it, and a naive grep would count that as a violation.
assert_eq "no install step invokes sudo" "0" \
  "$(grep -cE '^[[:space:]]*[^#]*\bsudo[[:space:]]' "$ROOT/lib/store/install.sh")"

# --- a Codex release is verified before it is trusted -------------------------------------------

write_lock '"codex":{"version":"0.154.0","tarball":"https://example.invalid/codex.tgz","prefix":"'"$CODEX_PREFIX"'","sha256":"'"$RELEASE_SHA"'"}'
ihar_install_codex >/dev/null 2>&1
assert_exit "the release is extracted" 0 test -x "$IHAR_STORE/bin/codex"
assert_eq "and the version is stamped" "0.154.0" "$(cat "$IHAR_STORE/bin/.codex-version")"

rm -f "$IHAR_STORE/bin/codex" "$IHAR_STORE/bin/.codex-version"
write_lock '"codex":{"version":"0.154.0","tarball":"https://example.invalid/codex.tgz","prefix":"'"$CODEX_PREFIX"'","sha256":"'"$(printf '0%.0s' {1..64})"'"}'
assert_exit "a digest mismatch is fail-closed" 3 \
  bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/init.sh'
           source '$ROOT/lib/store/lockfile.sh'; source '$ROOT/lib/store/install.sh'
           IHAR_ROOT='$ROOT' IHAR_STORE='$IHAR_STORE' IHAR_LOCKFILE='$IHAR_LOCKFILE' \
           IHAR_DOWNLOAD='$IHAR_TEST_TMP/fetch' ihar_install_codex"
assert_exit "and nothing is left installed" 1 test -x "$IHAR_STORE/bin/codex"

out="$(bash -c "source '$ROOT/lib/core/logging.sh'; source '$ROOT/lib/core/init.sh'
       source '$ROOT/lib/store/lockfile.sh'; source '$ROOT/lib/store/install.sh'
       IHAR_ROOT='$ROOT' IHAR_STORE='$IHAR_STORE' IHAR_LOCKFILE='$IHAR_LOCKFILE' \
       IHAR_DOWNLOAD='$IHAR_TEST_TMP/fetch' ihar_install_codex" 2>&1)"
assert_contains "the refusal shows both digests" "$out" "expected"

# --- install and update are one operation, decided by the pinned version -------------------------
#
# Install used to skip on the binary merely existing, so bumping the lockfile upgraded
# nothing and `ihar update` re-earned the conformance record with the old binary.

write_lock '"codex":{"version":"0.154.0","tarball":"https://example.invalid/codex.tgz","prefix":"'"$CODEX_PREFIX"'","sha256":"'"$RELEASE_SHA"'"}'
ihar_install_codex >/dev/null 2>&1
out="$(ihar_install_codex 2>&1)"
assert_contains "an unchanged lockfile makes the run a no-op" "$out" "already installed"

write_lock '"codex":{"version":"0.155.0","tarball":"https://example.invalid/codex.tgz","prefix":"'"$CODEX_PREFIX"'","sha256":"'"$RELEASE_SHA"'"}'
out="$(ihar_install_codex 2>&1)"
assert_contains "a bumped version reinstalls" "$out" "0.155.0 installed"
assert_eq "and restamps" "0.155.0" "$(cat "$IHAR_STORE/bin/.codex-version")"

# --- ACP adapters use exactly the lockfile versions ---------------------------------------------

cat > "$IHAR_TEST_TMP/npm" <<'EOF'
#!/usr/bin/env bash
set -eu
prefix=""
spec="${!#}"
while (( $# )); do
  if [[ "$1" == --prefix ]]; then prefix="$2"; shift 2; else shift; fi
done
mkdir -p "$prefix/bin"
case "$spec" in
  @agentclientprotocol/claude-agent-acp@*) name=claude-agent-acp ;;
  github:agentclientprotocol/codex-acp#*) name=codex-acp ;;
  *) exit 9 ;;
esac
printf '#!/bin/sh\n' > "$prefix/bin/$name"
chmod +x "$prefix/bin/$name"
printf '%s\n' "$spec" >> "$IHAR_FAKE_NPM_RECORD"
EOF
chmod +x "$IHAR_TEST_TMP/npm"
export IHAR_NPM_BIN="$IHAR_TEST_TMP/npm"
export IHAR_FAKE_NPM_RECORD="$IHAR_TEST_TMP/npm-record"

write_lock '"acp":{"claude-agent-acp":"0.79.0","codex-acp":"6ec22f3"}'
ihar_install_acp >/dev/null 2>&1
assert_exit "the Claude ACP adapter is installed" 0 test -x "$IHAR_CLAUDE_ACP_BIN"
assert_exit "the Codex ACP adapter is installed" 0 test -x "$IHAR_CODEX_ACP_BIN"
assert_contains "Claude ACP uses the exact pinned version" "$(cat "$IHAR_FAKE_NPM_RECORD")" \
  "@agentclientprotocol/claude-agent-acp@0.79.0"
assert_contains "Codex ACP uses the exact pinned revision" "$(cat "$IHAR_FAKE_NPM_RECORD")" \
  "github:agentclientprotocol/codex-acp#6ec22f3"
assert_eq "ACP versions are stamped" $'0.79.0\n6ec22f3' \
  "$(cat "$IHAR_STORE/acp/.versions")"

out="$(ihar_install_acp 2>&1)"
assert_contains "unchanged ACP pins make install a no-op" "$out" "already installed"

write_lock '"acp":{"claude-agent-acp":"0.80.0","codex-acp":"6ec22f3"}'
ihar_install_acp >/dev/null 2>&1
assert_contains "a bumped ACP version reinstalls" "$(cat "$IHAR_FAKE_NPM_RECORD")" \
  "@agentclientprotocol/claude-agent-acp@0.80.0"

# The Claude CLI follows the same rule, and it is the one that did not: assert the
# stamp is what decides, without a network or an npm registry.
CLAUDE_STAMP="$IHAR_NVM/npm-global/.claude-version"
mkdir -p "$(dirname "$IHAR_CLAUDE_BIN")" "$IHAR_NVM/bin" "$IHAR_NVM/npm-global"
printf '#!/bin/sh\necho stub claude\n' > "$IHAR_CLAUDE_BIN"; chmod +x "$IHAR_CLAUDE_BIN"
printf 'x\n' > "$IHAR_NVM/bin/node"; chmod +x "$IHAR_NVM/bin/node"
printf '2.0.0\n' > "$CLAUDE_STAMP"

write_lock '"node":{"version":"22.0.0"},"claude":{"version":"2.0.0"}'
out="$(ihar_install_claude 2>&1)"
assert_contains "a matching claude stamp is a no-op" "$out" "claude 2.0.0 already installed"

write_lock '"node":{"version":"22.0.0"},"claude":{"version":"2.1.0"}'
out="$(ihar_install_claude 2>&1)"
assert_eq "a bumped claude version does not report already installed" "0" \
  "$(grep -c 'already installed' <<<"$out")"

# --- the example configuration ---------------------------------------------------------------------

# Into the sandbox, never the checkout: the installer writes beside IHAR_ROOT, and a
# test that runs it against the real root rewrites a tracked file as a side effect.
# The exported PYTHONPATH still reaches the package.
EXAMPLE_ROOT="$IHAR_TEST_TMP/example-root"
mkdir -p "$EXAMPLE_ROOT"
IHAR_ROOT="$EXAMPLE_ROOT" ihar_install_example_config >/dev/null 2>&1
EXAMPLE="$EXAMPLE_ROOT/.ihar_config.example"
assert_exit "the example is written" 0 test -f "$EXAMPLE"
assert_contains "it says the file is parsed, not sourced" "$(cat "$EXAMPLE")" "never sourced"
assert_contains "it documents the profile key" "$(cat "$EXAMPLE")" "IHAR_PROFILE=standard"
assert_contains "and the masking floor rule" "$(cat "$EXAMPLE")" "never loosen it"
assert_eq "every line is commented out" "0" \
  "$(grep -cE '^[A-Z]' "$EXAMPLE")"

# Every key the parser accepts must appear in the example. Read from the parser's own
# array rather than scraped out of the file: a regular expression over the source
# would also catch internal names and would drift the moment either list moved.
source "$ROOT/lib/core/config.sh"
example_text="$(cat "$EXAMPLE")"
for key in "${_IHAR_CONFIG_KEYS[@]}"; do
  assert_contains "the example documents $key" "$example_text" "$key"
done

rm -f "$EXAMPLE"

# --- install stages one generation and rolls every failure back ----------------------

write_lock '"node":{"version":"22.23.1"},"claude":{"version":"2.1.274"},
            "codex":{"version":"0.154.0","tarball":"https://example.invalid/codex.tgz","prefix":"'"$CODEX_PREFIX"'","sha256":"'"$RELEASE_SHA"'"}'
OLD_RECEIPT='{"schema":1,"release_lock_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","installed_at":"2026-09-19T00:00:00Z","components":{}}'
COMMAND_LEGACY_STORE="$IHAR_TEST_TMP/legacy-command-store"
mkdir -p "$COMMAND_LEGACY_STORE/hooks"
printf 'legacy hook\n' > "$COMMAND_LEGACY_STORE/hooks/security-pretool.py"
printf 'legacy stage proof\n' > "$COMMAND_LEGACY_STORE/hooks/migration-proof"
printf '{"schema":1,"release_lock_sha256":"%064d","installed_at":"2026-09-18T00:00:00Z","components":{}}\n' 0 \
  > "$COMMAND_LEGACY_STORE/install-receipt.json"
command_legacy_before="$(find "$COMMAND_LEGACY_STORE" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"

migration_stage_observation() { # <scenario>
  printf '%s/%s-migration-stage\n' "$IHAR_TEST_TMP" "$1"
}

assert_migration_stage_observed() { # <scenario>
  local scenario="$1" observation content=""
  observation="$(migration_stage_observation "$scenario")"
  assert_exit "$scenario observes migrated content in install stage" 0 test -f "$observation"
  [[ ! -f "$observation" ]] || content="$(cat "$observation")"
  assert_contains "$scenario observes legacy hook bytes before installer overwrite" \
    "$content" "legacy stage proof"
  assert_contains "$scenario observes legacy receipt before receipt publication" \
    "$content" '"release_lock_sha256":"0000000000000000000000000000000000000000000000000000000000000000"'
}

reset_active_generation() {
  mkdir -p "$IHAR_STORE/hooks" "$(dirname "$IHAR_CODEX_BIN")" "$(dirname "$IHAR_CLAUDE_BIN")"
  printf 'old hook\n' > "$IHAR_STORE/hooks/security-pretool.py"
  rm -f -- "$IHAR_CLAUDE_BIN" "$IHAR_CODEX_BIN"
  printf '#!/bin/sh\necho old claude\n' > "$IHAR_CLAUDE_BIN"
  printf '#!/bin/sh\necho old codex\n' > "$IHAR_CODEX_BIN"
  chmod +x "$IHAR_CLAUDE_BIN" "$IHAR_CODEX_BIN"
  rm -f -- "$IHAR_STORE/install-receipt.json"
  printf '%s\n' "$OLD_RECEIPT" > "$IHAR_STORE/install-receipt.json"
}

generation_fingerprint() {
  {
    find "$IHAR_STORE/hooks" -type f -print0 | sort -z | xargs -0 sha256sum
    for path in "$IHAR_CLAUDE_BIN" "$IHAR_CODEX_BIN" \
                "$IHAR_STORE/install-receipt.json"; do
      sha256sum "$path" | cut -d' ' -f1
    done
  } | sha256sum | cut -d' ' -f1
}

wait_for_install_barrier() { # <path>
  local path="$1" attempt
  for ((attempt=0; attempt<500; attempt++)); do
    [[ -e "$path" ]] && return 0
    sleep 0.01
  done
  return 1
}

run_install_scenario() ( # <scenario> [install|update]
  local scenario="$1" operation="${2:-install}" migration_observation
  export IHAR_ACTIVE_TEST_STORE="$IHAR_STORE"
  case "$scenario" in
    bootstrap-*|receipt-only|receipt-link-only|executable-only-*|executable-link-codex)
      case "$scenario" in
        bootstrap-*|executable-only-*|executable-link-codex)
          rm -f -- "$IHAR_STORE/install-receipt.json" ;;
      esac
      case "$scenario" in
        bootstrap-*|receipt-only|receipt-link-only)
          rm -f -- "$IHAR_CLAUDE_BIN" "$IHAR_CODEX_BIN" ;;
        executable-only-claude) rm -f -- "$IHAR_CODEX_BIN" ;;
        executable-only-codex) rm -f -- "$IHAR_CLAUDE_BIN" ;;
        executable-link-codex) rm -f -- "$IHAR_CLAUDE_BIN" ;;
      esac
      ;;
  esac
  if [[ "$scenario" == migration-* ]]; then
    export IHAR_FLAG_MIGRATE_STORE=true IHAR_LEGACY_STORE="$COMMAND_LEGACY_STORE"
    migration_observation="$(migration_stage_observation "$scenario")"
    rm -f -- "$migration_observation"
  else
    export IHAR_FLAG_MIGRATE_STORE=false
    unset IHAR_LEGACY_STORE
  fi
  ihar_install_command() { :; }
  ihar_install_example_config() { :; }
  ihar_install_store() {
    if [[ "$scenario" == migration-* &&
          -f "$IHAR_STORE/hooks/migration-proof" &&
          -f "$IHAR_STORE/install-receipt.json" ]]; then
      {
        cat "$IHAR_STORE/hooks/migration-proof"
        cat "$IHAR_STORE/install-receipt.json"
      } > "$migration_observation"
    fi
    mkdir -p "$IHAR_STORE/hooks"
    printf 'new hook\n' > "$IHAR_STORE/hooks/security-pretool.py"
  }
  ihar_install_python() { :; }
  ihar_install_codex() {
    mkdir -p "$(dirname "$IHAR_CODEX_BIN")"
    printf '#!/bin/sh\necho new codex\n' > "$IHAR_CODEX_BIN"
    chmod +x "$IHAR_CODEX_BIN"
  }
  ihar_install_claude() {
    mkdir -p "$(dirname "$IHAR_CLAUDE_BIN")"
    printf '#!/bin/sh\necho new claude\n' > "$IHAR_CLAUDE_BIN"
    chmod +x "$IHAR_CLAUDE_BIN"
  }
  if [[ "$scenario" == bootstrap-* || "$scenario" == existing-failed || "$scenario" == receipt-only ||
        "$scenario" == receipt-link-only || "$scenario" == executable-only-* ||
        "$scenario" == executable-link-codex ]]; then
    ihar_python() {
      if [[ "$1" == ihar.conformance.run ]]; then
        printf '%s\n' "$2" >> "$IHAR_TEST_TMP/$scenario.conformance-runs"
        [[ "$scenario" != bootstrap-prerecord ]] || return 3
        [[ "$scenario" != bootstrap-missing-record ]] || return 1
        printf 'failed deny-blocks-the-tool\n'
        python3 - "$2" "$3" "$4" "$5" <<'PY'
import hashlib
import json
import os
import sys

from ihar import jsonio
from ihar.conformance import REQUIRED_CASES
from ihar.conformance.run import version_slug

vendor, binary, store, manifest = sys.argv[1:]
with open(binary, "rb") as stream:
    binary_digest = hashlib.sha256(stream.read()).hexdigest()
with open(manifest, "rb") as stream:
    manifest_digest = hashlib.sha256(stream.read()).hexdigest()
version = f"new-{vendor}"
record_vendor = ({"claude": "codex", "codex": "claude"}[vendor]
                 if os.environ["IHAR_TEST_SCENARIO"] == "bootstrap-other-vendor" else vendor)
record = {
    "schema": 1, "vendor": record_vendor, "version": version,
    "binary_sha256": binary_digest, "manifest_digest": manifest_digest,
    "created_at": "2026-09-21T00:00:00Z",
    "cases": {
        name: {"status": "failed" if name == "deny-blocks-the-tool" else "passed",
               "detail": "SECRET-SENTINEL"}
        for name in REQUIRED_CASES[record_vendor]
    },
}
target = os.path.join(store, "verification", f"{vendor}-{version_slug(version)}.json")
os.makedirs(os.path.dirname(target), exist_ok=True)
if os.environ["IHAR_TEST_SCENARIO"] == "bootstrap-invalid-record":
    del record["cases"]["deny-blocks-the-tool"]
    with open(target, "w", encoding="utf-8") as stream:
        json.dump(record, stream)
else:
    jsonio.write("conformance", target, record)
PY
        return 1
      fi
      PYTHONPATH="$ROOT/lib/python" python3 -m "$@"
    }
  else
    ihar_install_conformance() {
      [[ "$scenario" != *conformance ]] || return 36
      grep -q 'new hook' "$IHAR_STORE/hooks/security-pretool.py" || return 40
      grep -q 'new claude' "$IHAR_CLAUDE_BIN" || return 40
      grep -q 'new codex' "$IHAR_CODEX_BIN" || return 40
      if [[ "$scenario" == migration-late-mutation ||
            "$scenario" == migration-late-consumer ]]; then
        : > "$IHAR_TEST_TMP/$scenario.conformance-entered"
        wait_for_install_barrier "$IHAR_TEST_TMP/$scenario.conformance-release" || return 43
      fi
      if [[ "$scenario" == paths ]]; then
        [[ "${1:-}" == "$IHAR_ACTIVE_TEST_STORE" ]] || return 41
        [[ "$IHAR_STORE" == */.ihar-store-stage-* ]] || return 42
        [[ "$IHAR_CLAUDE_BIN" == */.ihar-nvm-stage-*/npm-global/bin/claude ]] || return 42
        [[ "$IHAR_CODEX_BIN" == */.ihar-store-stage-*/bin/codex ]] || return 42
      fi
      if [[ "$scenario" == ownership ]]; then
        if [[ -e "$IHAR_STORE/auth/claude/concurrent" ||
              -e "$IHAR_STORE/plugins/claude/concurrent" ||
              -e "$IHAR_STORE/vendor-data/concurrent" ]]; then
          printf 'copied\n' > "$IHAR_TEST_TMP/ownership-stage-observation"
        else
          printf 'clean\n' > "$IHAR_TEST_TMP/ownership-stage-observation"
        fi
        printf 'concurrent auth\n' > "$IHAR_ACTIVE_TEST_STORE/auth/claude/concurrent"
        printf 'concurrent plugin\n' > "$IHAR_ACTIVE_TEST_STORE/plugins/claude/concurrent"
        printf 'concurrent vendor data\n' > "$IHAR_ACTIVE_TEST_STORE/vendor-data/concurrent"
      fi
    }
  fi
  export IHAR_TEST_SCENARIO="$scenario"
  ihar_publish_install_receipt() {
    [[ "$scenario" != *receipt && "$scenario" != bootstrap-receipt ]] || return 37
    ihar_python ihar.install_receipt build "$IHAR_LOCKFILE" \
      "$IHAR_STORE/install-receipt.json" "$IHAR_CLAUDE_BIN" "$IHAR_CODEX_BIN"
  }
  ihar_install_move() {
    if [[ ( "$scenario" == activation || "$scenario" == bootstrap-activation || "$scenario" == rollback ||
            "$scenario" == migration-rollback ) &&
          "$1" == */.ihar-store-stage-*/install-receipt.json &&
          "$2" == "$IHAR_ACTIVE_TEST_STORE/install-receipt.json" ]]; then
      return 39
    fi
    if [[ ( "$scenario" == rollback || "$scenario" == migration-rollback ) &&
          "$1" == */.ihar-install-backup-*/install-receipt.json &&
          "$2" == "$IHAR_ACTIVE_TEST_STORE/install-receipt.json" ]]; then
      return 41
    fi
    command mv "$@"
  }
  if [[ "$operation" == update ]]; then
    ihar_codex_daemon_stop_all() { :; }
    ihar_codex_daemon_start_pending() { :; }
    _ihar_update_all
  else
    _ihar_install_all
  fi
)

transaction_fingerprint() {
  printf '%s\n%s\n' \
    "$(mutable_tree_fingerprint "$IHAR_STORE")" \
    "$(mutable_tree_fingerprint "$IHAR_NVM")"
}

assert_bootstrap_published_nothing() { # <scenario>
  local scenario="$1"
  assert_exit "$scenario publishes no receipt" 1 test -e "$IHAR_STORE/install-receipt.json"
  assert_exit "$scenario publishes no Claude executable" 1 test -e "$IHAR_CLAUDE_BIN"
  assert_exit "$scenario publishes no Codex executable" 1 test -e "$IHAR_CODEX_BIN"
  assert_contains "$scenario preserves pre-existing hook bytes" \
    "$(cat "$IHAR_STORE/hooks/security-pretool.py")" "old hook"
  assert_exit "$scenario leaks no store stage" 1 \
    compgen -G "$(dirname "$IHAR_STORE")/.ihar-store-stage-*"
  assert_exit "$scenario leaks no NVM stage" 1 \
    compgen -G "$(dirname "$IHAR_NVM")/.ihar-nvm-stage-*"
  assert_exit "$scenario leaks no backup" 1 \
    compgen -G "$(dirname "$IHAR_STORE")/.ihar-install-backup-*"
}

reset_active_generation
bootstrap_output="$(run_install_scenario bootstrap-failed 2>&1)"
bootstrap_status=$?
assert_eq "complete failed cases permit first bootstrap" "0" "$bootstrap_status"
assert_exit "first bootstrap publishes receipt" 0 test -f "$IHAR_STORE/install-receipt.json"
assert_contains "first bootstrap activates Claude" "$(cat "$IHAR_CLAUDE_BIN")" "new claude"
assert_contains "first bootstrap activates Codex" "$(cat "$IHAR_CODEX_BIN")" "new codex"
for vendor in claude codex; do
  assert_exit "failed $vendor proof is not published" 1 \
    test -e "$IHAR_STORE/verification/$vendor-new-$vendor.json"
  assert_contains "first bootstrap names unproven $vendor" "$bootstrap_output" "$vendor"
done
assert_contains "first bootstrap directs post-auth proof" \
  "$bootstrap_output" "ihar check --conformance"
assert_contains "first bootstrap reports bounded failed case" \
  "$bootstrap_output" "failed deny-blocks-the-tool"
assert_eq "first bootstrap does not print record detail" 0 \
  "$(grep -cF 'SECRET-SENTINEL' <<<"$bootstrap_output")"

reset_active_generation
before_generation="$(transaction_fingerprint)"
existing_output="$(run_install_scenario existing-failed update 2>&1)"
existing_status=$?
assert_eq "failed existing-generation conformance aborts update" 1 "$existing_status"
assert_contains "failed update reports bounded failed case" \
  "$existing_output" "failed deny-blocks-the-tool"
assert_eq "failed update does not print record detail" 0 \
  "$(grep -cF 'SECRET-SENTINEL' <<<"$existing_output")"
assert_eq "failed update preserves previous active generation" \
  "$before_generation" "$(transaction_fingerprint)"

for scenario in receipt-only executable-only-claude executable-only-codex; do
  reset_active_generation
  case "$scenario" in
    receipt-only) rm -f -- "$IHAR_CLAUDE_BIN" "$IHAR_CODEX_BIN" ;;
    executable-only-claude) rm -f -- "$IHAR_STORE/install-receipt.json" "$IHAR_CODEX_BIN" ;;
    executable-only-codex) rm -f -- "$IHAR_STORE/install-receipt.json" "$IHAR_CLAUDE_BIN" ;;
  esac
  before_generation="$(transaction_fingerprint)"
  assert_exit "$scenario rejects failed conformance" 1 run_install_scenario "$scenario"
  assert_eq "$scenario preserves active bytes" \
    "$before_generation" "$(transaction_fingerprint)"
done

reset_active_generation
rm -f -- "$IHAR_STORE/install-receipt.json" "$IHAR_CLAUDE_BIN" "$IHAR_CODEX_BIN"
ln -s missing-codex "$IHAR_CODEX_BIN"
before_generation="$(transaction_fingerprint)"
assert_exit "dangling vendor executable path prevents bootstrap" 1 \
  run_install_scenario executable-link-codex
assert_eq "dangling executable remains unchanged" \
  "$before_generation" "$(transaction_fingerprint)"

reset_active_generation
rm -f -- "$IHAR_STORE/install-receipt.json" "$IHAR_CLAUDE_BIN" "$IHAR_CODEX_BIN"
ln -s missing-receipt.json "$IHAR_STORE/install-receipt.json"
before_generation="$(transaction_fingerprint)"
assert_exit "dangling receipt path prevents bootstrap" 1 \
  run_install_scenario receipt-link-only
assert_eq "dangling receipt remains unchanged" \
  "$before_generation" "$(transaction_fingerprint)"

reset_active_generation
printf 'malformed receipt\n' > "$IHAR_STORE/install-receipt.json"
rm -f -- "$IHAR_CLAUDE_BIN" "$IHAR_CODEX_BIN"
before_generation="$(transaction_fingerprint)"
assert_exit "malformed receipt path prevents bootstrap" 1 \
  run_install_scenario receipt-only
assert_eq "malformed receipt remains unchanged" \
  "$before_generation" "$(transaction_fingerprint)"

for scenario in bootstrap-prerecord bootstrap-missing-record bootstrap-invalid-record \
                bootstrap-other-vendor \
                bootstrap-receipt bootstrap-activation; do
  reset_active_generation
  rm -f -- "$IHAR_TEST_TMP/$scenario.conformance-runs"
  case "$scenario" in
    bootstrap-prerecord) expected_status=3 ;;
    bootstrap-missing-record|bootstrap-invalid-record|bootstrap-other-vendor)
      expected_status=1 ;;
    bootstrap-receipt) expected_status=37 ;;
    bootstrap-activation) expected_status=39 ;;
  esac
  scenario_status=0
  scenario_output="$(run_install_scenario "$scenario" 2>&1)" || scenario_status=$?
  assert_eq "$scenario aborts install" "$expected_status" "$scenario_status"
  assert_exit "$scenario prints no post-auth proof advice without activation" 1 \
    grep -qF -- "ihar check --conformance" <<< "$scenario_output"
  assert_bootstrap_published_nothing "$scenario"
  assert_eq "$scenario attempts both installed vendor suites" \
    $'claude\ncodex' "$(cat "$IHAR_TEST_TMP/$scenario.conformance-runs")"
done

before_lock="$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"
for scenario in conformance receipt activation; do
  reset_active_generation
  before_generation="$(generation_fingerprint)"
  case "$scenario" in
    conformance) expected_status=36 ;;
    receipt) expected_status=37 ;;
    activation) expected_status=39 ;;
  esac
  assert_exit "$scenario failure aborts install" "$expected_status" \
    run_install_scenario "$scenario"
  assert_eq "$scenario failure preserves exact active generation and receipt" \
    "$before_generation" "$(generation_fingerprint)"
  assert_exit "$scenario failure leaves Claude executable usable" 0 "$IHAR_CLAUDE_BIN"
  assert_exit "$scenario failure leaves Codex executable usable" 0 "$IHAR_CODEX_BIN"
done

reset_active_generation
rm -f -- "$IHAR_TEST_TMP/migration-late-mutation.conformance-"{entered,release}
late_mutation_generation="$(generation_fingerprint)"
run_install_scenario migration-late-mutation \
  >"$IHAR_TEST_TMP/migration-late-mutation.out" 2>&1 &
late_mutation_pid=$!
assert_exit "migrated install reaches paused conformance before late mutation" 0 \
  wait_for_install_barrier "$IHAR_TEST_TMP/migration-late-mutation.conformance-entered"
printf 'late mutation\n' >> "$COMMAND_LEGACY_STORE/hooks/security-pretool.py"
touch "$IHAR_TEST_TMP/migration-late-mutation.conformance-release"
late_mutation_status=0
wait "$late_mutation_pid" || late_mutation_status=$?
assert_eq "late legacy mutation aborts before activation" "3" "$late_mutation_status"
assert_eq "late legacy mutation preserves prior active generation and receipt" \
  "$late_mutation_generation" "$(generation_fingerprint)"
assert_contains "late legacy mutation remains in copy-only source evidence" \
  "$(cat "$COMMAND_LEGACY_STORE/hooks/security-pretool.py")" "late mutation"
printf 'legacy hook\n' > "$COMMAND_LEGACY_STORE/hooks/security-pretool.py"

reset_active_generation
rm -f -- "$IHAR_TEST_TMP/migration-late-consumer.conformance-"{entered,release} \
  "$IHAR_TEST_TMP/migration-late-consumer.consumer-"{ready,release}
late_consumer_generation="$(generation_fingerprint)"
run_install_scenario migration-late-consumer \
  >"$IHAR_TEST_TMP/migration-late-consumer.out" 2>&1 &
late_consumer_install_pid=$!
assert_exit "migrated install reaches paused conformance before late consumer" 0 \
  wait_for_install_barrier "$IHAR_TEST_TMP/migration-late-consumer.conformance-entered"
bash -c 'exec 9>>"$1"; : > "$2"; while [[ ! -e "$3" ]]; do sleep 0.01; done' _ \
  "$COMMAND_LEGACY_STORE/hooks/security-pretool.py" \
  "$IHAR_TEST_TMP/migration-late-consumer.consumer-ready" \
  "$IHAR_TEST_TMP/migration-late-consumer.consumer-release" &
late_consumer_pid=$!
assert_exit "late legacy consumer opens the staged source before activation" 0 \
  wait_for_install_barrier "$IHAR_TEST_TMP/migration-late-consumer.consumer-ready"
touch "$IHAR_TEST_TMP/migration-late-consumer.conformance-release"
late_consumer_status=0
wait "$late_consumer_install_pid" || late_consumer_status=$?
touch "$IHAR_TEST_TMP/migration-late-consumer.consumer-release"
wait "$late_consumer_pid"
assert_eq "late legacy consumer aborts before activation" "3" "$late_consumer_status"
assert_eq "late legacy consumer preserves prior active generation and receipt" \
  "$late_consumer_generation" "$(generation_fingerprint)"
assert_eq "late legacy consumer leaves source evidence byte-identical" \
  "$command_legacy_before" \
  "$(find "$COMMAND_LEGACY_STORE" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"

for scenario in migration-conformance migration-receipt; do
  reset_active_generation
  before_generation="$(generation_fingerprint)"
  case "$scenario" in
    migration-conformance) expected_status=36 ;;
    migration-receipt) expected_status=37 ;;
  esac
  assert_exit "$scenario failure aborts install" "$expected_status" \
    run_install_scenario "$scenario"
  assert_eq "$scenario failure preserves prior active generation and receipt" \
    "$before_generation" "$(generation_fingerprint)"
  assert_exit "$scenario failure leaves prior Claude executable usable" 0 "$IHAR_CLAUDE_BIN"
  assert_exit "$scenario failure leaves prior Codex executable usable" 0 "$IHAR_CODEX_BIN"
  assert_eq "$scenario failure leaves legacy source byte-identical" \
    "$command_legacy_before" \
    "$(find "$COMMAND_LEGACY_STORE" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
  assert_migration_stage_observed "$scenario"
done

reset_active_generation
assert_exit "conformance loads staged hooks and binaries while protecting active store" 0 \
  run_install_scenario paths

reset_active_generation
before_generation="$(generation_fingerprint)"
assert_exit "receipt failure aborts update" 37 run_install_scenario receipt update
assert_eq "receipt failure preserves exact active generation across update" \
  "$before_generation" "$(generation_fingerprint)"
assert_eq "failed installs never rewrite release lock" "$before_lock" \
  "$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"
assert_exit "failed installs leak no store stage" 1 \
  compgen -G "$(dirname "$IHAR_STORE")/.ihar-store-stage-*"
assert_exit "failed installs leak no NVM stage" 1 \
  compgen -G "$(dirname "$IHAR_NVM")/.ihar-nvm-stage-*"
assert_exit "failed installs leak no activation backup" 1 \
  compgen -G "$(dirname "$IHAR_STORE")/.ihar-install-backup-*"

reset_active_generation
mkdir -p "$IHAR_STORE/auth/claude" "$IHAR_STORE/plugins/claude" "$IHAR_STORE/vendor-data"
printf 'initial auth\n' > "$IHAR_STORE/auth/claude/concurrent"
printf 'initial plugin\n' > "$IHAR_STORE/plugins/claude/concurrent"
printf 'initial vendor data\n' > "$IHAR_STORE/vendor-data/concurrent"
printf 'stable lock\n' > "$IHAR_STORE/.ihar-store.lock"
lock_inode="$(stat -c '%i' "$IHAR_STORE/.ihar-store.lock")"
assert_exit "transaction stages only installer-owned store paths" 0 \
  run_install_scenario ownership
assert_eq "mutable store paths are not copied into the generation stage" "clean" \
  "$(cat "$IHAR_TEST_TMP/ownership-stage-observation")"
assert_eq "concurrent auth writes survive activation" "concurrent auth" \
  "$(cat "$IHAR_STORE/auth/claude/concurrent")"
assert_eq "concurrent plugin writes survive activation" "concurrent plugin" \
  "$(cat "$IHAR_STORE/plugins/claude/concurrent")"
assert_eq "concurrent vendor data writes survive activation" "concurrent vendor data" \
  "$(cat "$IHAR_STORE/vendor-data/concurrent")"
assert_eq "stable lock inode survives activation" "$lock_inode" \
  "$(stat -c '%i' "$IHAR_STORE/.ihar-store.lock")"

reset_active_generation
rollback_output="$(run_install_scenario rollback 2>&1)"
rollback_status=$?
assert_eq "incomplete rollback reports recovery failure" 3 "$rollback_status"
recovery_backup="$(compgen -G "$(dirname "$IHAR_STORE")/.ihar-install-backup-*" | head -1)"
assert_exit "incomplete rollback retains recovery backup" 0 test -n "$recovery_backup"
assert_contains "incomplete rollback reports retained backup path" "$rollback_output" \
  ".ihar-install-backup-"
assert_exit "incomplete rollback retains prior receipt for recovery" 0 \
  test -f "$recovery_backup/install-receipt.json"
assert_contains "retained recovery receipt has prior bytes" \
  "$(cat "$recovery_backup/install-receipt.json")" '"release_lock_sha256":"aaaaaaaa'
assert_contains "rollback continues restoring hooks after one restore failure" \
  "$(cat "$IHAR_STORE/hooks/security-pretool.py")" "old hook"
assert_contains "rollback continues restoring Claude after one restore failure" \
  "$(cat "$IHAR_CLAUDE_BIN")" "old claude"
assert_contains "rollback continues restoring Codex after one restore failure" \
  "$(cat "$IHAR_CODEX_BIN")" "old codex"
rm -rf -- "$recovery_backup"

reset_active_generation
migration_rollback_output="$(run_install_scenario migration-rollback 2>&1)"
migration_rollback_status=$?
assert_eq "migrated install with incomplete rollback is fail-closed" 3 \
  "$migration_rollback_status"
migration_recovery_backup="$(compgen -G "$(dirname "$IHAR_STORE")/.ihar-install-backup-*" | head -1)"
assert_exit "migrated install retains one recovery backup" 0 \
  test -n "$migration_recovery_backup"
assert_contains "migrated install reports retained recovery backup" \
  "$migration_rollback_output" ".ihar-install-backup-"
assert_contains "migrated install recovery keeps pre-command receipt" \
  "$(cat "$migration_recovery_backup/install-receipt.json")" \
  '"release_lock_sha256":"aaaaaaaa'
assert_contains "migrated install rollback restores pre-command hooks" \
  "$(cat "$IHAR_STORE/hooks/security-pretool.py")" "old hook"
assert_eq "incomplete migrated install leaves legacy source byte-identical" \
  "$command_legacy_before" \
  "$(find "$COMMAND_LEGACY_STORE" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
assert_migration_stage_observed migration-rollback

reset_active_generation
rm -rf "$IHAR_STORE/auth" "$IHAR_STORE/plugins"
run_install_scenario success >/dev/null 2>&1
assert_exit "successful transaction prepares active mutable owners" 0 \
  test -d "$IHAR_STORE/auth/claude"
assert_exit "successful transaction prepares active plugin owners" 0 \
  test -d "$IHAR_STORE/plugins/codex"
assert_contains "successful install activates staged hook bytes" \
  "$(cat "$IHAR_STORE/hooks/security-pretool.py")" "new hook"
assert_contains "successful install activates staged Claude bytes" \
  "$(cat "$IHAR_CLAUDE_BIN")" "new claude"
assert_contains "successful install activates staged Codex bytes" \
  "$(cat "$IHAR_CODEX_BIN")" "new codex"

expected_lock_sha="$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"
expected_claude_sha="$(sha256sum "$IHAR_CLAUDE_BIN" | cut -d' ' -f1)"
expected_codex_sha="$(sha256sum "$IHAR_CODEX_BIN" | cut -d' ' -f1)"
receipt_values="$(python3 - "$IHAR_STORE/install-receipt.json" <<'PY'
import sys
from ihar.install_receipt import read_receipt

receipt = read_receipt(sys.argv[1])
print(receipt["release_lock_sha256"])
print(receipt["components"]["claude"]["version"])
print(receipt["components"]["claude"]["binary_sha256"])
print(receipt["components"]["codex"]["version"])
print(receipt["components"]["codex"]["binary_sha256"])
PY
)"
assert_eq "receipt records release and executable evidence" \
  "$expected_lock_sha
2.1.274
$expected_claude_sha
0.154.0
$expected_codex_sha" "$receipt_values"
assert_eq "receipt is owner-only" "600" "$(stat -c '%a' "$IHAR_STORE/install-receipt.json")"
assert_eq "successful install preserves release lock" "$before_lock" \
  "$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"
assert_exit "successful publication leaves no temp" 1 compgen -G "$IHAR_STORE/.install-receipt-*"

chmod -x "$IHAR_CODEX_BIN"
ihar_publish_install_receipt
receipt_vendors="$(python3 - "$IHAR_STORE/install-receipt.json" <<'PY'
import json
import sys

print(" ".join(sorted(json.load(open(sys.argv[1], encoding="utf-8"))["components"])))
PY
)"
assert_eq "receipt hashes only executables that exist" "claude" "$receipt_vendors"
chmod +x "$IHAR_CODEX_BIN"

finish
