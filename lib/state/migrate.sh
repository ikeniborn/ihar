#!/usr/bin/env bash
# One-time migration from the legacy wrapper homes (LLD 4.5).
#
# Copy, never move. The legacy home stays exactly as it was, so the old wrapper keeps
# working and a rollback is deleting what was copied.
#
# Failure class: fail-soft. A migration that cannot run leaves a fresh state; the user
# loses history, not the ability to launch.

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

  # iclaude writes a marker naming the project; require it to agree. icodex writes
  # none, so there the hash match is all the evidence available.
  #
  # A marker that exists but cannot be read is not the same as no marker: it is
  # evidence we failed to check rather than evidence there was nothing to check.
  # Copying another project's transcripts into this one is not recoverable by the
  # user, so the unreadable case skips.
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

  local entry
  for entry in projects sessions session-env history.jsonl file-history \
               state_5.sqlite thread_history_1.sqlite; do
    [[ -e "$legacy/$entry" ]] || continue
    # Never follow a legacy symlink: it points into the old store, which this
    # harness does not own and will not copy.
    [[ -L "$legacy/$entry" ]] && continue
    cp -R "$legacy/$entry" "$target/$entry" 2>/dev/null \
      || ihar_warn "cannot migrate $entry from $legacy"
  done

  ihar_info "migrated $vendor state from $legacy"
  printf '%s\n' "$legacy"
}
