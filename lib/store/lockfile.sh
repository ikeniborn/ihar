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

# ihar_store_verify [vendor binary verify-receipt] — lockfile drift, hook integrity,
# native-binary receipt, and conformance. Exit 3 for an enforced receipt failure;
# standard warns and returns zero so the vendor may still start. Dry-run passes
# `false` because it executes neither the native binary nor an adapter that delegates
# to it; a real ACP launch verifies the native executable selected for that vendor.
ihar_store_verify() {
  local vendor="${1:-${IHAR_VENDOR:-}}" binary="${2:-}" verify_receipt="${3:-true}"
  local strict=true
  if [[ "${IHAR_PROFILE:-standard}" == "standard" ]]; then strict=false; fi

  if [[ -z "$binary" && -n "$vendor" ]]; then
    case "$vendor" in
      claude) binary="$IHAR_CLAUDE_BIN" ;;
      codex)  binary="$IHAR_CODEX_BIN" ;;
    esac
  fi

  if [[ ! -f "$IHAR_LOCKFILE" ]]; then
    # Nothing is pinned yet, so nothing can be verified. Under an enforced profile
    # that is not a neutral state: the profile claims a pinned configuration.
    if [[ "$strict" == true ]]; then
      ihar_die 3 "profile '$IHAR_PROFILE' requires pinned components but $IHAR_LOCKFILE is absent
run 'ihar install' first"
    fi
    if [[ "$verify_receipt" == true ]]; then
      ihar_store_verify_binaries false "$vendor" "$binary"
    fi
    return 0
  fi

  local recorded current="$(ihar_lockfile_hash)"
  local marker="$IHAR_STORE/.last-lockfile-hash"
  recorded="$(cat "$marker" 2>/dev/null || true)"
  if [[ -n "$recorded" && "$recorded" != "$current" ]]; then
    ihar_warn "the lockfile changed since the last install; run 'ihar install'"
  fi

  ihar_store_verify_hooks "$strict"
  if [[ "$verify_receipt" == true ]]; then
    ihar_store_verify_binaries "$strict" "$vendor" "$binary"
  fi
  ihar_store_verify_conformance "$strict"
}

# ihar_store_verify_conformance <strict> — a profile that claims hook enforcement
# must be able to point at evidence that this vendor, at this version, honours a hook
# decision (LLD 6.6).
#
# Rendering a hook is not evidence the vendor fired it. Without this, `hooks:
# enforced` would be a claim about a file rather than about behaviour.
ihar_store_verify_conformance() {
  local strict="$1"
  [[ "$strict" == true ]] || return 0
  [[ "${IHAR_PROFILE_HOOKS:-best-effort}" == "enforced" ]] || return 0

  local vendor="${IHAR_VENDOR:-}" binary version record verification marker
  [[ -n "$vendor" ]] || return 0
  case "$vendor" in
    claude) binary="$IHAR_CLAUDE_BIN" ;;
    codex)  binary="$IHAR_CODEX_BIN" ;;
  esac
  [[ -x "$binary" ]] || ihar_die 3 "profile '$IHAR_PROFILE' enforces hooks but the $vendor binary is absent"

  verification="$IHAR_STORE/verification"
  marker="$verification/.recheck-$vendor"
  [[ -d "$verification" && ! -L "$verification" ]] \
    || ihar_die 3 "hook enforcement is unproven for $vendor: verification store unavailable"
  [[ ! -e "$marker" && ! -L "$marker" ]] \
    || ihar_die 3 "hook enforcement is unproven for $vendor: conformance recheck incomplete"

  version="$(ihar_version_slug "$binary")"
  record="$IHAR_STORE/verification/$vendor-$version.json"
  [[ -f "$record" ]] || ihar_die 3 "hook enforcement is unproven for $vendor $version
run 'ihar check --conformance'"

  local stale
  stale="$(ihar_python ihar.conformance.check "$record" "$binary" "$IHAR_ROOT/manifests/hooks.json" 2>&1)" \
    || ihar_die 3 "the conformance record for $vendor $version does not hold: ${stale:-no detail}"
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
run 'ihar install'" ;;
      *) ihar_die 3 "cannot verify $key integrity: ${out:-no output}" ;;
    esac
  done
}

# ihar_receipt_binary_status <vendor> <binary> — exactly one public receipt state:
# `verified`, `mismatched`, or `missing receipt`. Malformed and unreadable evidence
# is missing evidence, never a fourth state callers could accidentally tolerate.
ihar_receipt_binary_status() {
  local vendor="$1" binary="$2" raw status=0
  [[ -f "$IHAR_STORE/install-receipt.json" && -r "$IHAR_STORE/install-receipt.json" ]] \
    || { printf 'missing receipt\n'; return 0; }
  raw="$(ihar_python ihar.check_result receipt "$IHAR_STORE/install-receipt.json" \
    "$IHAR_LOCKFILE" "$vendor" "$binary" 2>/dev/null)" || status=$?
  if (( status != 0 )); then
    printf 'missing receipt\n'
    return 0
  fi
  case "$raw" in
    valid) printf 'verified\n' ;;
    stale|not-installed) printf 'mismatched\n' ;;
    missing|invalid|*) printf 'missing receipt\n' ;;
  esac
}

# ihar_store_verify_binaries <strict> [vendor binary]
ihar_store_verify_binaries() {
  local strict="$1" vendor="${2:-${IHAR_VENDOR:-}}" binary="${3:-}" receipt_status
  [[ -n "$vendor" ]] || return 0
  if [[ -z "$binary" ]]; then
    case "$vendor" in
      claude) binary="$IHAR_CLAUDE_BIN" ;;
      codex)  binary="$IHAR_CODEX_BIN" ;;
    esac
  fi
  receipt_status="$(ihar_receipt_binary_status "$vendor" "$binary")"
  [[ "$receipt_status" == verified ]] && return 0
  if [[ "$strict" == true ]]; then
    ihar_die 3 "the $vendor executable is $receipt_status in $IHAR_STORE/install-receipt.json; profile '$IHAR_PROFILE' requires verified install receipt evidence"
  fi
  ihar_warn "the $vendor executable is $receipt_status in the install receipt; continuing under standard"
}

# ihar_store_verify_acp <vendor> — version and installed-byte pin for ACP exec.
ihar_store_verify_acp() {
  local vendor="$1" key binary line pinned_version installed_version pinned_digest actual
  case "$vendor" in
    claude) key=claude-agent-acp; binary="$IHAR_CLAUDE_ACP_BIN"; line=1 ;;
    codex) key=codex-acp; binary="$IHAR_CODEX_ACP_BIN"; line=2 ;;
  esac
  pinned_version="$(ihar_lockfile_get "acp.$key")"
  [[ -n "$pinned_version" ]] || ihar_die 3 "the lockfile does not pin $key"
  installed_version="$(sed -n "${line}p" "$IHAR_STORE/acp/.versions" 2>/dev/null || true)"
  [[ "$installed_version" == "$pinned_version" ]] \
    || ihar_die 3 "$key does not match the lockfile; run 'ihar install --acp'"
  [[ -x "$binary" ]] || ihar_die 1 "the $vendor ACP adapter is not installed at $binary"
  pinned_digest="$(awk -F '\t' -v key="$key" '$1 == key {print $2}' "$IHAR_STORE/acp/.digests" 2>/dev/null)"
  actual="$(ihar_sha256 "$binary")"
  [[ -n "$pinned_digest" && "$actual" == "$pinned_digest" ]] \
    || ihar_die 3 "$key differs from the installed pin; run 'ihar install --acp'"
}
