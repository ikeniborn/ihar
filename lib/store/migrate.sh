#!/usr/bin/env bash
# Copy eligible contract-owned data from legacy wrapper stores. Never delete source.

IHAR_STORE_MIGRATION_LOCK_FDS=()

_ihar_store_legacy_sources() {
  if [[ -n "${IHAR_LEGACY_STORE:-}" ]]; then
    printf '%s\n' "$IHAR_LEGACY_STORE"
    return 0
  fi
  local parent
  parent="$(dirname "$IHAR_ROOT")"
  [[ -d "$parent/iclaude/.claude-isolated" ]] && printf '%s\n' "$parent/iclaude/.claude-isolated"
  [[ -d "$parent/icodex/.codex-isolated" ]] && printf '%s\n' "$parent/icodex/.codex-isolated"
}

_ihar_store_migration_entries() {
  ihar_asset_store_roots
  printf 'install-receipt.json\n'
}

_ihar_store_source_writer_pid() { # <source>
  local source="$1" fd_path pid
  fd_path="$(find /proc/[0-9]*/fd \( -lname "$source" -o -lname "$source/*" \) \
    -print -quit 2>/dev/null)"
  [[ -n "$fd_path" ]] || return 1
  pid="${fd_path#/proc/}"
  printf '%s\n' "${pid%%/*}"
}

_ihar_store_release_source_locks() {
  local fd
  for fd in ${IHAR_STORE_MIGRATION_LOCK_FDS[@]+"${IHAR_STORE_MIGRATION_LOCK_FDS[@]}"}; do
    eval "exec ${fd}>&-" 2>/dev/null || true
  done
  IHAR_STORE_MIGRATION_LOCK_FDS=()
}

_ihar_store_acquire_source_locks() { # sources...
  local source lockfile fd timeout="${IHAR_STORE_MIGRATION_LOCK_TIMEOUT:-30}"
  command -v flock >/dev/null 2>&1 \
    || { ihar_warn "flock is required for fail-closed store migration"; return 3; }
  for source in "$@"; do
    lockfile="${source}.ihar-lifecycle.lock"
    if ! { exec {fd}>"$lockfile"; } 2>/dev/null; then
      _ihar_store_release_source_locks
      ihar_warn "cannot open required store migration lock $lockfile"
      return 3
    fi
    if ! flock -x -w "$timeout" "$fd"; then
      exec {fd}>&-
      _ihar_store_release_source_locks
      ihar_warn "legacy store $source is active; stop its wrapper before migration"
      return 3
    fi
    IHAR_STORE_MIGRATION_LOCK_FDS+=("$fd")
  done
}

_ihar_store_publish_stage() { # <stage>
  local stage="$1" backup name status=0 index
  local -a names=() published=() had_old=()
  backup="$(mktemp -d "$(dirname "$IHAR_STORE")/.ihar-store-migrate-backup-XXXXXX")" || return 1
  while IFS= read -r name; do
    [[ -e "$stage/$name" || -L "$stage/$name" ]] && names+=("$name")
  done < <(_ihar_store_migration_entries)
  mkdir -p "$IHAR_STORE"
  for index in "${!names[@]}"; do
    name="${names[$index]}"
    mkdir -p "$(dirname "$backup/$name")" "$(dirname "$IHAR_STORE/$name")"
    had_old+=(0)
    if [[ -e "$IHAR_STORE/$name" || -L "$IHAR_STORE/$name" ]]; then
      mv -- "$IHAR_STORE/$name" "$backup/$name" || { status=$?; break; }
      had_old[index]=1
    fi
    published+=("$index")
    mv -- "$stage/$name" "$IHAR_STORE/$name" || { status=$?; break; }
  done
  if (( status != 0 )); then
    for ((index=${#published[@]} - 1; index >= 0; index--)); do
      name="${names[${published[$index]}]}"
      rm -rf -- "$IHAR_STORE/$name"
      if [[ "${had_old[${published[$index]}]}" == 1 ]]; then
        mkdir -p "$(dirname "$IHAR_STORE/$name")"
        mv -- "$backup/$name" "$IHAR_STORE/$name" || status=3
      fi
    done
  fi
  rm -rf -- "$backup"
  return "$status"
}

_ihar_store_migrate_locked() {
  local source stage source_before source_after staged writer status=0 entry
  local -a sources=() entries=()
  while IFS= read -r source; do [[ -n "$source" && -d "$source" ]] && sources+=("$source"); done \
    < <(_ihar_store_legacy_sources)
  (( ${#sources[@]} )) || return 0
  while IFS= read -r entry; do [[ -n "$entry" ]] && entries+=("$entry"); done \
    < <(_ihar_store_migration_entries)
  _ihar_store_acquire_source_locks "${sources[@]}" || return $?
  for source in "${sources[@]}"; do
    if writer="$(_ihar_store_source_writer_pid "$source")"; then
      ihar_warn "legacy store $source is active in process $writer"
      status=3
      break
    fi
    source_before="$(ihar_python ihar.migration_fingerprint "$source" "${entries[@]}")" \
      || { status=3; break; }
    stage="$(mktemp -d "$(dirname "$IHAR_STORE")/.ihar-store-migrate-stage-XXXXXX")" \
      || { status=1; break; }
    local source_path target_path
    for entry in "${entries[@]}"; do
      [[ -e "$source/$entry" && ! -L "$source/$entry" ]] || continue
      mkdir -p "$(dirname "$stage/$entry")"
      source_path="$source/$entry"
      target_path="$stage/$entry"
      if [[ -d "$source_path" ]]; then
        mkdir -p "$target_path"
        source_path="$source_path/"
        target_path="$target_path/"
      fi
      if ! rsync -a --no-links --no-specials --no-devices \
        "$source_path" "$target_path" >/dev/null 2>&1; then status=3; break; fi
    done
    source_after="$(ihar_python ihar.migration_fingerprint "$source" "${entries[@]}")" \
      || status=3
    staged="$(ihar_python ihar.migration_fingerprint "$stage" "${entries[@]}")" \
      || status=3
    if (( status != 0 )) || [[ "$source_before" != "$source_after" || "$source_after" != "$staged" ]]; then
      rm -rf -- "$stage"
      ihar_warn "legacy store $source changed during migration; staged copy discarded"
      status=3
      break
    fi
    if writer="$(_ihar_store_source_writer_pid "$source")"; then
      rm -rf -- "$stage"
      ihar_warn "legacy store $source became active in process $writer; staged copy discarded"
      status=3
      break
    fi
    if [[ -f "$stage/install-receipt.json" ]]; then
      ihar_python ihar.check_result validate-receipt "$stage/install-receipt.json" \
        || { rm -rf -- "$stage"; status=3; break; }
    fi
    _ihar_store_publish_stage "$stage" || status=$?
    rm -rf -- "$stage"
    (( status == 0 )) || break
  done
  _ihar_store_release_source_locks
  return "$status"
}

# ihar_store_migrate — public locked operation.
ihar_store_migrate() {
  ihar_with_lock --required "$IHAR_STORE/.ihar-store.lock" 900 _ihar_store_migrate_locked
}
