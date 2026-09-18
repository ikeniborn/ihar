#!/usr/bin/env bash
# Immutable, configuration-keyed runtime homes (LLD 2.4, 4.2).
#
# LLD revision 2 kept one mutable configuration per project, so two concurrent
# launches with different profiles rendered into the same files and the last writer
# won: a protected session could start against a configuration a standard launch had
# already replaced. Keying the directory by the effective configuration removes the
# window, because two different configurations are two different directories and a
# directory that already exists is never rewritten.
#
# Failure class: fail-closed. A drifted runtime home aborts the launch (exit 3).

# ihar_config_hash <profile> <masking> <gateway> <sandbox> <mcp-strict>
#                  <hooks-digest> <registry-digest> <vendor-version>
# The eight inputs that decide how the vendor behaves. Anything that changes vendor
# behaviour belongs here; anything that does not must stay out, or every launch would
# build a new home.
ihar_config_hash() {
  (( $# == 8 )) || ihar_die 2 "ihar_config_hash: expected 8 inputs, got $#"
  printf '%s\n' "$@" | sha256sum | cut -c1-8
}

# ihar_runtime_materialise <vendor> <hash> <render-dir> [immutable|writable]
#
# `render-dir` holds the files this configuration renders, laid out exactly as they
# belong in the runtime home. Absent one, the directory is still built with its links,
# which is what the earliest slices need.
ihar_runtime_materialise() {
  local vendor="$1" hash="$2" render="${3:-}" mode="${4:-immutable}"
  [[ -n "${IHAR_STATE:-}" ]] || ihar_die 1 "ihar_runtime_materialise: IHAR_STATE is not set"

  local runtime="$IHAR_STATE/r/$hash/$vendor"
  ihar_with_lock --required "$IHAR_STATE/.ihar.lock" 30 \
    _ihar_runtime_materialise "$vendor" "$hash" "$render" "$mode" "$runtime"

  IHAR_RUNTIME="$runtime"
  export IHAR_RUNTIME
  printf '%s\n' "$runtime"
}

_ihar_runtime_materialise() {
  local vendor="$1" hash="$2" render="$3" mode="$4" runtime="$5"

  if [[ -d "$runtime" ]]; then
    _ihar_runtime_verify "$runtime" "$render"
    return 0
  fi

  local staging
  staging="$(mktemp -d "$IHAR_STATE/r/.staging-XXXXXX")" \
    || ihar_die 1 "cannot stage a runtime home under $IHAR_STATE/r"

  local build="$staging/$vendor"
  mkdir -p "$build"

  if [[ -n "$render" && -d "$render" ]]; then
    cp -R "$render/." "$build/" || ihar_die 1 "cannot copy the render into $build"
  fi

  ihar_link_runtime "$vendor" "$build" "$IHAR_STATE"

  mkdir -p "$IHAR_STATE/r/$hash"
  if ! mv "$build" "$runtime" 2>/dev/null; then
    # Another launch of the same configuration won the race and published first. Its
    # content is ours by construction, so adopt it rather than failing.
    rm -rf "$staging"
    [[ -d "$runtime" ]] || ihar_die 1 "cannot publish the runtime home at $runtime"
    _ihar_runtime_verify "$runtime" "$render"
    return 0
  fi
  rm -rf "$staging"

  # Sealing happens after publication and before the files are sealed read-only. The
  # key a Codex hook is trusted under embeds the absolute path of the rendered
  # hooks.json, so a seal performed in the staging directory would record a path the
  # publish then renames away.
  if declare -F ihar_seal_runtime >/dev/null; then
    ihar_seal_runtime "$vendor" "$runtime"
  fi

  if [[ "$mode" == "immutable" ]]; then
    # Read-only to the agent as well as to us: under an enforced profile the sandbox
    # denies the directory, and this is the second layer.
    find "$runtime" -maxdepth 1 -type f -exec chmod 444 {} + 2>/dev/null || true
  else
    find "$runtime" -maxdepth 1 -type f -exec chmod 600 {} + 2>/dev/null || true
  fi
}

# _ihar_runtime_verify <runtime> <render> — an existing home must match what this
# launch would render. A difference means the configuration hash and the content
# disagree, so one of them is wrong and continuing would run under a configuration
# nobody chose.
_ihar_runtime_verify() {
  local runtime="$1" render="$2" relative
  [[ -n "$render" && -d "$render" ]] || return 0

  while IFS= read -r -d '' file; do
    relative="${file#"$render"/}"
    if [[ ! -f "$runtime/$relative" ]]; then
      ihar_die 3 "runtime home $runtime is missing $relative; it does not match its configuration hash"
    fi
    # The hook trust block is appended to config.toml after publication, from digests
    # the vendor itself reported, so it is derived state rather than rendered state.
    # Comparing it would make every sealed home look drifted.
    if [[ "$relative" == "config.toml" ]]; then
      if ! cmp -s "$file" <(sed '/# ihar:hook-trust:start/,$d' "$runtime/$relative"); then
        ihar_die 3 "runtime home $runtime has drifted at $relative; rendering into an existing home is never allowed"
      fi
      continue
    fi
    if ! cmp -s "$file" "$runtime/$relative"; then
      ihar_die 3 "runtime home $runtime has drifted at $relative; rendering into an existing home is never allowed"
    fi
  done < <(find "$render" -type f -print0)
}
