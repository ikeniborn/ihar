#!/usr/bin/env bash
# Copy eligible contract-owned data from legacy wrapper stores. Never delete source.

IHAR_STORE_MIGRATION_LOCK_FDS=()

_ihar_store_legacy_sources() {
  if [[ -n "${IHAR_LEGACY_STORE:-}" ]]; then
    tr ':' '\n' <<<"$IHAR_LEGACY_STORE"
    return 0
  fi
  local parent
  parent="$(dirname "$IHAR_ROOT")"
  [[ -d "$parent/iclaude/.claude-isolated" ]] && printf '%s\n' "$parent/iclaude/.claude-isolated"
  [[ -d "$parent/icodex/.codex-isolated" ]] && printf '%s\n' "$parent/icodex/.codex-isolated"
}

ihar_store_migration_move() {
  command mv -- "$@"
}

_ihar_store_migration_entries() {
  ihar_asset_store_roots
  printf 'install-receipt.json\n'
}

_ihar_store_full_fingerprint() { # <root> <entry>...
  local root="$1" entry regular metadata; shift
  regular="$(ihar_python ihar.migration_fingerprint "$root" "$@")" || return 1
  metadata="$(
    set -o pipefail
    cd "$root" || exit 1
    {
      for entry in "$@"; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        find -P "$entry" -printf '%y\0%m\0%s\0%T@\0%p\0%l\0'
      done
    } | sort -z | sha256sum | cut -d' ' -f1
  )" || return 1
  printf '%s\0%s\n' "$regular" "$metadata" | sha256sum | cut -d' ' -f1
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
  local stage="$1" backup name status=0 rollback_status=0 index published_index
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
      ihar_store_migration_move "$IHAR_STORE/$name" "$backup/$name" \
        || { status=$?; break; }
      had_old[index]=1
    fi
    published+=("$index")
    ihar_store_migration_move "$stage/$name" "$IHAR_STORE/$name" \
      || { status=$?; break; }
  done
  if (( status != 0 )); then
    for ((index=${#published[@]} - 1; index >= 0; index--)); do
      published_index="${published[$index]}"
      name="${names[$published_index]}"
      rm -rf -- "$IHAR_STORE/$name" || rollback_status=3
      if [[ "${had_old[$published_index]}" == 1 ]]; then
        mkdir -p "$(dirname "$IHAR_STORE/$name")"
        ihar_store_migration_move "$backup/$name" "$IHAR_STORE/$name" \
          || rollback_status=3
      fi
    done
    if (( rollback_status != 0 )); then
      ihar_warn "store migration rollback incomplete; recovery backup retained at $backup"
      return 3
    fi
  fi
  rm -rf -- "$backup"
  return "$status"
}

_ihar_store_stage_locked() { # <combined-stage>; caller releases source locks
  local combined="$1" source source_stage source_before source_after source_copy staged writer status=0 entry
  local source_path target_path
  local -a sources=() entries=() source_stages=() source_fingerprints=()
  while IFS= read -r source; do [[ -n "$source" && -d "$source" ]] && sources+=("$source"); done \
    < <(_ihar_store_legacy_sources)
  (( ${#sources[@]} )) || return 0
  while IFS= read -r entry; do [[ -n "$entry" ]] && entries+=("$entry"); done \
    < <(_ihar_store_migration_entries)
  _ihar_store_acquire_source_locks "${sources[@]}" || return $?
  for source in "${sources[@]}"; do
    (( status == 0 )) || break
    if writer="$(_ihar_store_source_writer_pid "$source")"; then
      ihar_warn "legacy store $source is active in process $writer"
      status=3
      break
    fi
    source_before="$(_ihar_store_full_fingerprint "$source" "${entries[@]}")" \
      || { status=3; break; }
    source_fingerprints+=("$source_before")
    source_stage="$(mktemp -d "$(dirname "$IHAR_STORE")/.ihar-store-source-stage-XXXXXX")" \
      || { status=1; break; }
    source_stages+=("$source_stage")
    for entry in "${entries[@]}"; do
      [[ -e "$source/$entry" && ! -L "$source/$entry" ]] || continue
      mkdir -p "$(dirname "$source_stage/$entry")"
      source_path="$source/$entry"
      target_path="$source_stage/$entry"
      if [[ -d "$source_path" ]]; then
        mkdir -p "$target_path"
        source_path="$source_path/"
        target_path="$target_path/"
      fi
      if ! rsync -a --no-links --no-specials --no-devices \
        "$source_path" "$target_path" >/dev/null 2>&1; then status=3; break; fi
    done
    source_after="$(_ihar_store_full_fingerprint "$source" "${entries[@]}")" \
      || status=3
    source_copy="$(ihar_python ihar.migration_fingerprint "$source" "${entries[@]}")" \
      || status=3
    staged="$(ihar_python ihar.migration_fingerprint "$source_stage" "${entries[@]}")" \
      || status=3
    if (( status != 0 )) || [[ "$source_before" != "$source_after" || "$source_copy" != "$staged" ]]; then
      ihar_warn "legacy store $source changed during migration; staged copy discarded"
      status=3
      break
    fi
    if writer="$(_ihar_store_source_writer_pid "$source")"; then
      ihar_warn "legacy store $source became active in process $writer; staged copy discarded"
      status=3
      break
    fi
    if [[ -f "$source_stage/install-receipt.json" ]]; then
      ihar_python ihar.check_result validate-receipt "$source_stage/install-receipt.json" \
        || { status=3; break; }
    fi
  done
  if (( status == 0 )); then
    local index final_fingerprint
    for index in "${!sources[@]}"; do
      source="${sources[$index]}"
      final_fingerprint="$(_ihar_store_full_fingerprint "$source" "${entries[@]}")" \
        || { status=3; break; }
      if [[ "$final_fingerprint" != "${source_fingerprints[$index]}" ]]; then
        ihar_warn "legacy store $source changed after staging; all staged copies discarded"
        status=3
        break
      fi
      if writer="$(_ihar_store_source_writer_pid "$source")"; then
        ihar_warn "legacy store $source became active in process $writer; all staged copies discarded"
        status=3
        break
      fi
    done
  fi
  if (( status == 0 )); then
    for source_stage in "${source_stages[@]}"; do
      rsync -a --no-links --no-specials --no-devices "$source_stage/" "$combined/" \
        >/dev/null 2>&1 || { status=3; break; }
    done
  fi
  rm -rf -- "${source_stages[@]}"
  return "$status"
}

_ihar_store_migrate_locked() {
  local stage status=0
  stage="$(mktemp -d "$(dirname "$IHAR_STORE")/.ihar-store-migrate-stage-XXXXXX")" \
    || return 1
  _ihar_store_stage_locked "$stage" || status=$?
  if (( status == 0 )); then
    _ihar_store_publish_stage "$stage" || status=$?
  fi
  rm -rf -- "$stage"
  _ihar_store_release_source_locks
  return "$status"
}

# ihar_store_migrate — public locked operation.
ihar_store_migrate() {
  ihar_with_lock --required "$IHAR_STORE/.ihar-store.lock" 900 _ihar_store_migrate_locked
}
