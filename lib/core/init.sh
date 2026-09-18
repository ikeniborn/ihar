#!/usr/bin/env bash
# The three roots and the paths derived from them (LLD 2.1, 2.2).
#
# Failure class: usage. An unusable root is reported and aborts before anything is
# created; nothing here falls back to a second location, because a store that lands
# somewhere unexpected is a store an agent might be able to write.

# ihar_resolve_script_dir <path> — the directory of the entry point, following
# symlinks, so a symlinked `ihar` on PATH still finds lib/ and manifests/.
ihar_resolve_script_dir() {
  local source="$1" dir
  while [[ -L "$source" ]]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  cd -P "$(dirname "$source")" && pwd
}

# ihar_init <entry-point-path> — export the roots. Idempotent; an already-exported
# value wins, which is what lets a test point the roots at a temporary directory.
ihar_init() {
  local entry="${1:-${BASH_SOURCE[0]}}"

  : "${IHAR_ROOT:="$(ihar_resolve_script_dir "$entry")"}"

  # The store holds hook scripts, vendor credentials and the transparent-mode CA
  # key. It lives outside the checkout so that an agent running under a
  # workspace-write sandbox cannot rewrite its own enforcement (LLD 2.1).
  : "${IHAR_STORE:="${XDG_DATA_HOME:-$HOME/.local/share}/ihar"}"

  # State is short by design: the Codex daemon opens a Unix socket under a runtime
  # home, and a socket path over roughly 108 bytes fails at bind (LLD 2.2).
  : "${IHAR_STATE_ROOT:="${XDG_STATE_HOME:-$HOME/.local/state}/ihar"}"

  # The Node tree is a sibling of the store, never a child: an install rebuilds it
  # wholesale, and that must not happen inside the directory holding the CA key.
  : "${IHAR_NVM:="$(dirname "$IHAR_STORE")/ihar-nvm"}"

  : "${IHAR_PY:="$IHAR_STORE/venv/bin/python3"}"
  : "${IHAR_CLAUDE_BIN:="$IHAR_NVM/npm-global/bin/claude"}"
  : "${IHAR_CODEX_BIN:="$IHAR_STORE/bin/codex"}"
  : "${IHAR_LOCKFILE:="$IHAR_ROOT/.ihar-lockfile.json"}"

  # The platform's usable sun_path: 108 bytes including the terminating NUL on
  # Linux, so 107 characters. No headroom is subtracted, because the preflight
  # computes the exact socket path rather than an estimate; an arbitrary margin
  # would reject layouts that work.
  : "${IHAR_SOCKET_PATH_MAX:=107}"

  export IHAR_ROOT IHAR_STORE IHAR_STATE_ROOT IHAR_NVM IHAR_PY \
         IHAR_CLAUDE_BIN IHAR_CODEX_BIN IHAR_LOCKFILE IHAR_SOCKET_PATH_MAX
}

# ihar_python <module> [args...] — run a package module through the store venv,
# falling back to the system interpreter when the venv is not installed yet. The
# fallback is deliberate and bounded: the contract validator is pure stdlib, so a
# machine without a built venv can still validate, while anything needing a
# dependency fails on the import rather than silently degrading.
ihar_python() {
  local interpreter="${IHAR_PY:-}"
  [[ -x "$interpreter" ]] || interpreter="$(command -v python3 || true)"
  [[ -n "$interpreter" ]] || ihar_die 3 "python3 is required and was not found"
  PYTHONPATH="${IHAR_ROOT:?IHAR_ROOT is not set}/lib/python${PYTHONPATH:+:$PYTHONPATH}" \
    "$interpreter" -m "$@"
}

# ihar_version_slug <binary> — the filename-safe vendor version, in the same form
# ihar.conformance.run writes. `codex --version` answers "codex-cli 0.154.0", whose
# space makes a raw record path awkward to quote and easy to break.
ihar_version_slug() {
  local raw
  raw="$("$1" --version 2>/dev/null | head -1)"
  printf '%s\n' "$raw" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}
