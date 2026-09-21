#!/usr/bin/env bash
# Operability over the state root (LLD 4.6).
#
# icodex accumulated fifteen gigabytes across twenty-one homes nobody could attribute
# to a project, because it wrote no marker. Every state directory here carries one,
# so an orphan is identifiable rather than merely large.
#
# Failure class: fail-soft for listing; usage for a named target that does not exist.
# Nothing is ever deleted on the launch path.

# ihar_state_list — one line per project state: id, project root, size, last use,
# and an `orphan` mark when the recorded root is gone.
ihar_state_list() {
  [[ -d "$IHAR_STATE_ROOT" ]] || return 0
  local dir id root size used mark
  for dir in "$IHAR_STATE_ROOT"/*/; do
    [[ -d "$dir" ]] || continue
    id="$(basename "$dir")"
    root="$(_ihar_state_root_of "$dir")"
    size="$(du -sh "$dir" 2>/dev/null | cut -f1)"
    used="$(date -u -r "$dir" +%Y-%m-%d 2>/dev/null || echo unknown)"
    mark=""
    if [[ "$root" != unknown && ! -d "$root" ]]; then mark=" orphan"; fi
    printf '%-40s %-10s %-12s %s%s\n' "$id" "${size:-?}" "$used" "$root" "$mark"
  done
}

_ihar_state_root_of() {
  local marker="$1/home.json"
  [[ -f "$marker" ]] || { printf 'unknown\n'; return 0; }
  ihar_python ihar.state_marker --read "$marker" 2>/dev/null || printf 'unknown\n'
}

# ihar_state_clean_orphans — remove only the states whose recorded project root is
# gone. A state without a readable marker is never auto-pruned: unattributable is not
# the same as unwanted, and deleting it would take a vendor's transcripts with it.
ihar_state_clean_orphans() {
  local dir id root removed=0
  [[ -d "$IHAR_STATE_ROOT" ]] || return 0
  for dir in "$IHAR_STATE_ROOT"/*/; do
    [[ -d "$dir" ]] || continue
    root="$(_ihar_state_root_of "$dir")"
    [[ "$root" == unknown ]] && continue
    [[ -d "$root" ]] && continue
    id="$(basename "$dir")"
    if [[ "${IHAR_ASSUME_YES:-}" != "1" ]]; then
      read -r -p "remove orphan state $id (project $root is gone)? [y/N] " answer </dev/tty || answer=n
      [[ "$answer" == [yY]* ]] || continue
    fi
    rm -rf "$dir"
    ihar_info "removed orphan state $id"
    removed=$((removed + 1))
  done
  printf '%s\n' "$removed"
}

# ihar_state_clean_runtimes <days> <state> — drop runtime homes unused for longer than the
# given age. Project state under st/ is never touched: a runtime home rebuilds from
# its configuration, a transcript does not.
ihar_state_clean_runtimes() {
  local days="${1:-30}" state="${2:-$IHAR_STATE}"
  [[ -d "$state/r" ]] || { printf '0\n'; return 0; }
  ihar_with_lock --required "$state/.ihar.lock" "${IHAR_CLEAN_LOCK_TIMEOUT:-30}" \
    _ihar_state_clean_runtimes_locked "$days" "$state"
}

_ihar_runtime_is_active() {
  local runtime="$1" process environment
  for process in /proc/[0-9]*; do
    environment="$process/environ"
    [[ -r "$environment" ]] || continue
    if grep -zFqx "IHAR_RUNTIME=$runtime/claude" "$environment" 2>/dev/null \
      || grep -zFqx "IHAR_RUNTIME=$runtime/codex" "$environment" 2>/dev/null \
      || grep -zFqx "CLAUDE_CONFIG_DIR=$runtime/claude" "$environment" 2>/dev/null \
      || grep -zFqx "CODEX_HOME=$runtime/codex" "$environment" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

_ihar_state_clean_runtimes_locked() {
  local days="$1" state="$2" hash runtime vendor expired removed=0
  local -a removed_hashes=()
  expired="$(ihar_python ihar.state_marker --expired-runtimes "$state/home.json" "$days")" \
    || ihar_die 3 "cannot determine expired runtimes for $state"
  while IFS= read -r hash; do
    [[ -n "$hash" ]] || continue
    [[ "$hash" =~ ^[0-9a-f]{8}$ ]] \
      || ihar_die 3 "state marker returned invalid runtime hash '$hash'"
    runtime="$state/r/$hash"
    if [[ -d "$runtime" ]] && _ihar_runtime_is_active "$runtime"; then
      continue
    fi
    # A pre-manifest runtime may still own the only vendor history or SQLite
    # bytes. The target-scoped transactional upgrade is a no-op for link-only
    # generations; materialized, ambiguous, changing or active state either moves
    # losslessly to st/ or aborts before rm sees the runtime.
    for vendor in claude codex; do
      [[ -d "$runtime/$vendor" ]] || continue
      ihar_upgrade_runtime_state "$vendor" "$state" "$hash" || return
    done
    if [[ -e "$runtime" ]] && ! rm -rf -- "$runtime"; then
      ihar_die 3 "cannot remove expired runtime $hash"
    fi
    removed_hashes+=("$hash")
    removed=$((removed + 1))
  done <<<"$expired"
  if (( ${#removed_hashes[@]} )); then
    ihar_python ihar.state_marker --remove-runtimes "$state/home.json" "${removed_hashes[@]}" \
      || ihar_die 3 "cannot update runtime inventory for $state"
  fi
  printf '%s\n' "$removed"
}
