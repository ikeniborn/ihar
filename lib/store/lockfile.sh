#!/usr/bin/env bash
# Pins and their verification (LLD 14.1, 14.2).
#
# Failure class: a hook or managed-hook mismatch is fail-closed in every profile,
# because those files are the enforcement itself. A binary mismatch warns under
# `standard` and aborts elsewhere, which is why the profile is resolved before this
# runs: the severity is the profile's decision, not this function's.

# ihar_lockfile_hash — the drift marker, over the whole file.
ihar_lockfile_hash() {
  [[ -f "$IHAR_LOCKFILE" ]] || { printf 'none\n'; return 0; }
  sha256sum "$IHAR_LOCKFILE" | cut -c1-64
}

# ihar_lockfile_get <dotted.path> — one value, or empty when the path is absent.
#
# Empty means absent, never "could not read". A caller that cannot tell the two apart
# would skip a pin check on a corrupt lockfile, so an unreadable file aborts here.
ihar_lockfile_get() {
  [[ -f "$IHAR_LOCKFILE" ]] || return 0
  local out status=0
  out="$(ihar_python ihar.lockfile --get "$1" "$IHAR_LOCKFILE" 2>&1)" || status=$?
  case "$status" in
    0) printf '%s\n' "$out" ;;
    1) ;;                       # the path is not in the lockfile
    *) ihar_die 3 "cannot read $IHAR_LOCKFILE: ${out:-no output}" ;;
  esac
}

# ihar_store_verify — lockfile drift, hook integrity, binary pins.
ihar_store_verify() {
  local strict=true
  if [[ "${IHAR_PROFILE:-standard}" == "standard" ]]; then strict=false; fi

  if [[ ! -f "$IHAR_LOCKFILE" ]]; then
    # Nothing is pinned yet, so nothing can be verified. Under an enforced profile
    # that is not a neutral state: the profile claims a pinned configuration.
    if [[ "$strict" == true ]]; then
      ihar_die 3 "profile '$IHAR_PROFILE' requires pinned components but $IHAR_LOCKFILE is absent
run 'ihar install' first"
    fi
    return 0
  fi

  local recorded current="$(ihar_lockfile_hash)"
  local marker="$IHAR_STORE/.last-lockfile-hash"
  recorded="$(cat "$marker" 2>/dev/null || true)"
  if [[ -n "$recorded" && "$recorded" != "$current" ]]; then
    ihar_warn "the lockfile changed since the last install; run 'ihar install --from-lockfile'"
  fi

  ihar_store_verify_hooks "$strict"
  ihar_store_verify_binaries "$strict"
}

# ihar_store_verify_hooks <strict> — hook scripts are the enforcement itself, so a
# mismatch aborts in every profile, strict or not. The argument is accepted for
# symmetry and deliberately unused.
#
# Being unable to verify is treated exactly like a mismatch. An earlier draft
# swallowed every failure with `|| true`, so a missing interpreter or an unreadable
# lockfile read as "nothing differs" and the launch continued with its integrity
# check silently absent.
ihar_store_verify_hooks() {
  local key
  for key in hooks managedHooks; do
    local out status=0
    out="$(ihar_python ihar.lockfile --verify-map "$key" "$IHAR_LOCKFILE" "$IHAR_STORE" 2>&1)" \
      || status=$?
    case "$status" in
      0) ;;
      1) ihar_die 3 "$out differs from the lockfile
run 'ihar install --from-lockfile'" ;;
      *) ihar_die 3 "cannot verify $key integrity: ${out:-no output}" ;;
    esac
  done
}

# ihar_store_verify_binaries <strict>
ihar_store_verify_binaries() {
  local strict="$1" pinned actual

  pinned="$(ihar_lockfile_get claude.binarySha256)"
  if [[ -n "$pinned" && -f "$IHAR_CLAUDE_BIN" ]]; then
    actual="$(sha256sum "$IHAR_CLAUDE_BIN" | cut -c1-64)"
    if [[ "$actual" != "$pinned" ]]; then
      if [[ "$strict" == true ]]; then
        ihar_die 3 "the claude binary differs from the lockfile; profile '$IHAR_PROFILE' requires a pinned binary"
      fi
      ihar_warn "the claude binary differs from the lockfile"
    fi
  fi

  pinned="$(ihar_lockfile_get codex.sha256)"
  if [[ -n "$pinned" && -f "$IHAR_CODEX_BIN" ]]; then
    # The Codex pin is the release archive's digest, not the extracted binary's, so
    # it is verified at install. Nothing to compare here yet; recorded so the next
    # slice that owns install does not mistake the silence for a missing check.
    :
  fi
}
