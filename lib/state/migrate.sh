#!/usr/bin/env bash
# One-time migration from the legacy wrapper homes (LLD 4.5).
#
# Copy, never move. The legacy home stays exactly as it was, so the old wrapper keeps
# working and a rollback is deleting what was copied.
#
# Failure class: fail-soft. A migration that cannot run leaves a fresh state; the user
# loses history, not the ability to launch.

ihar_migration_inventory() {
  ihar_python ihar.inventory state "$IHAR_ROOT/manifests/state.json" "$1"
}

# _ihar_legacy_candidates <vendor> <hash> — legacy homes whose id ends in the same
# project hash. iclaude and icodex both key on sha256(project-root)[0:12] but sanitise
# the basename differently, so the hash is the reliable half of the id.
_ihar_legacy_candidates() {
  local vendor="$1" hash="$2" parent
  parent="$(dirname "$IHAR_ROOT")"
  case "$vendor" in
    claude) ls -d "$parent"/iclaude/.claude-homes/*-"$hash" 2>/dev/null ;;
    codex)  ls -d "$parent"/icodex/.codex-homes/*-"$hash" 2>/dev/null ;;
  esac
}

# _ihar_legacy_writer_pid <vendor> <legacy-home> — print one process that can
# still mutate the source. Vendor wrappers export the home explicitly; open file
# descriptors catch a process that dropped or rewrote that environment variable.
_ihar_legacy_writer_pid() {
  local vendor="$1" legacy="$2" key proc fd_path pid
  case "$vendor" in
    claude) key=CLAUDE_CONFIG_DIR ;;
    codex)  key=CODEX_HOME ;;
  esac

  for proc in /proc/[0-9]*; do
    if grep -zFqx -- "$key=$legacy" "$proc/environ" 2>/dev/null; then
      printf '%s\n' "${proc##*/}"
      return 0
    fi
  done

  fd_path="$(find /proc/[0-9]*/fd \( -lname "$legacy" -o -lname "$legacy/*" \) \
    -print -quit 2>/dev/null)"
  [[ -n "$fd_path" ]] || return 1
  pid="${fd_path#/proc/}"
  printf '%s\n' "${pid%%/*}"
  return 0
}

# Refuse the whole two-vendor operation before either source is copied. There is
# deliberately no force path: a fuzzy snapshot is not a successful migration.
ihar_migration_require_quiescent() {
  local root="$1" hash vendor legacy pid status=0
  hash="$(printf '%s' "$root" | sha256sum | cut -c1-12)"
  for vendor in claude codex; do
    legacy="$(_ihar_legacy_candidates "$vendor" "$hash" | head -1)"
    [[ -n "$legacy" && -d "$legacy" ]] || continue
    if pid="$(_ihar_legacy_writer_pid "$vendor" "$legacy")"; then
      ihar_warn "legacy $vendor home $legacy is active in process $pid; stop it before migration"
      status=1
    fi
  done
  return "$status"
}

IHAR_MIGRATION_LOCK_FDS=()

# Hold both legacy wrapper lifecycle locks exclusively through marker publication.
# Updated wrappers take these same adjacent files shared before touching a home.
ihar_migration_acquire_locks() {
  local root="$1" hash vendor legacy lockfile fd timeout
  hash="$(printf '%s' "$root" | sha256sum | cut -c1-12)"
  timeout="${IHAR_MIGRATION_LOCK_TIMEOUT:-30}"
  command -v flock >/dev/null 2>&1 \
    || { ihar_warn "flock is required for fail-closed migration"; return 3; }
  for vendor in claude codex; do
    legacy="$(_ihar_legacy_candidates "$vendor" "$hash" | head -1)"
    [[ -n "$legacy" && -d "$legacy" ]] || continue
    lockfile="${legacy}.ihar-lifecycle.lock"
    if ! { exec {fd}>"$lockfile"; } 2>/dev/null; then
      ihar_migration_release_locks
      ihar_warn "cannot open required migration lock $lockfile"
      return 3
    fi
    if ! flock -x -w "$timeout" "$fd"; then
      exec {fd}>&-
      ihar_migration_release_locks
      ihar_warn "legacy $vendor home $legacy is active; stop the wrapper before migration"
      return 3
    fi
    IHAR_MIGRATION_LOCK_FDS+=("$fd")
  done
}

ihar_migration_release_locks() {
  local fd
  for fd in ${IHAR_MIGRATION_LOCK_FDS[@]+"${IHAR_MIGRATION_LOCK_FDS[@]}"}; do
    eval "exec ${fd}>&-" 2>/dev/null || true
  done
  IHAR_MIGRATION_LOCK_FDS=()
}

# ihar_migrate_vendor <vendor> <state> <root> — seed st/<vendor> from a legacy home.
# Only vendor state is taken: configuration is re-rendered from the manifests, and a
# legacy settings file would carry keys this harness no longer means.
ihar_migrate_vendor() {
  local vendor="$1" state="$2" root="$3"
  local hash target legacy marker_root

  target="$state/st/$vendor"
  # Only ever seeds an empty state; a second run must not overwrite live sessions.
  [[ -z "$(ls -A "$target" 2>/dev/null)" ]] || return 0

  hash="$(printf '%s' "$root" | sha256sum | cut -c1-12)"
  legacy="$(_ihar_legacy_candidates "$vendor" "$hash" | head -1)"
  [[ -n "$legacy" && -d "$legacy" ]] || return 0

  local writer_pid
  if writer_pid="$(_ihar_legacy_writer_pid "$vendor" "$legacy")"; then
    ihar_warn "legacy $vendor home $legacy is active in process $writer_pid; skipping migration"
    return 1
  fi

  # iclaude writes a marker naming the project; require it to agree. icodex writes
  # none, so there the hash match is all the evidence available.
  #
  # A marker that exists but cannot be read is not the same as no marker: it is
  # evidence we failed to check rather than evidence there was nothing to check.
  # Copying another project's transcripts into this one is not recoverable by the
  # user, so the unreadable case skips.
  if [[ "$vendor" == claude && ! -f "$legacy/home.json" ]]; then
    ihar_warn "legacy Claude home $legacy has no project marker; skipping migration"
    return 0
  fi
  if [[ -f "$legacy/home.json" ]]; then
    marker_root="$(ihar_python ihar.state_marker --read "$legacy/home.json" 2>/dev/null || true)"
    if [[ -z "$marker_root" ]]; then
      ihar_warn "legacy home $legacy has an unreadable marker; skipping migration"
      return 0
    fi
    if [[ "$marker_root" != "$root" ]]; then
      ihar_warn "legacy home $legacy records project $marker_root, not $root; skipping migration"
      return 0
    fi
  fi

  command -v rsync >/dev/null 2>&1 \
    || { ihar_warn "rsync is required to migrate legacy state"; return 1; }

  local entry kind suffix inventory stage copied=false source_before source_after staged
  local source_path target_path
  local -a entries=()
  inventory="$(ihar_migration_inventory "$vendor")" \
    || { ihar_warn "cannot read $vendor state inventory"; return 1; }
  while IFS=$'\t' read -r entry kind; do
    [[ -n "$entry" ]] || continue
    if [[ "$kind" == sqlite-family ]]; then
      for suffix in '' -wal -shm; do entries+=("$entry$suffix"); done
    else
      entries+=("$entry")
    fi
  done <<< "$inventory"

  source_before="$(ihar_python ihar.migration_fingerprint "$legacy" "${entries[@]}")" \
    || { ihar_warn "cannot fingerprint $vendor migration source $legacy"; return 1; }
  stage="$(mktemp -d "$state/st/.${vendor}-migrate-XXXXXX")" \
    || { ihar_warn "cannot stage $vendor migration"; return 1; }
  for entry in "${entries[@]}"; do
    [[ -e "$legacy/$entry" ]] || continue
    # Never follow a legacy symlink: it points into the old store, which this
    # harness does not own and will not copy.
    [[ -L "$legacy/$entry" ]] && continue
    mkdir -p "$(dirname "$stage/$entry")"
    if [[ -d "$legacy/$entry" ]]; then mkdir -p "$stage/$entry"; fi
    source_path="$legacy/$entry"
    target_path="$stage/$entry"
    if [[ -d "$source_path" ]]; then source_path="$source_path/"; target_path="$target_path/"; fi
    if ! rsync -a --no-links --no-specials --no-devices \
      "$source_path" "$target_path" >/dev/null 2>&1; then
      rm -rf "$stage"
      ihar_warn "cannot migrate $entry from $legacy"
      return 1
    fi
    copied=true
  done

  if [[ "$copied" != true ]]; then rm -rf "$stage"; return 0; fi
  source_after="$(ihar_python ihar.migration_fingerprint "$legacy" "${entries[@]}")" \
    || { rm -rf "$stage"; ihar_warn "cannot verify $vendor migration source $legacy"; return 1; }
  staged="$(ihar_python ihar.migration_fingerprint "$stage" "${entries[@]}")" \
    || { rm -rf "$stage"; ihar_warn "cannot verify staged $vendor migration"; return 1; }
  if [[ "$source_before" != "$source_after" || "$source_after" != "$staged" ]]; then
    rm -rf "$stage"
    ihar_warn "legacy $vendor home $legacy changed during migration; staged copy discarded"
    return 1
  fi
  if writer_pid="$(_ihar_legacy_writer_pid "$vendor" "$legacy")"; then
    rm -rf "$stage"
    ihar_warn "legacy $vendor home $legacy became active in process $writer_pid; migration discarded"
    return 1
  fi
  if ! rmdir "$target" 2>/dev/null || ! mv "$stage" "$target"; then
    mkdir -p "$target"
    rm -rf "$stage"
    ihar_warn "cannot publish $vendor migration from $legacy"
    return 1
  fi

  ihar_info "migrated $vendor state from $legacy"
  printf '%s\n' "$legacy"
}
