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
    # Verify immutable store links before state reconciliation. A bad security asset
    # must fail without creating or repairing a persistent-state path.
    ihar_verify_runtime_asset_links "$vendor" "$runtime" || return
    ihar_verify_runtime_mutable_links "$vendor" "$runtime" || return
    # State inventory may gain entries after this immutable render was published,
    # and runtime-local vendor writes may replace or remove a link. Verify rendered
    # files first so configuration drift still fails closed, then reconcile state.
    ihar_verify_runtime_state_links "$vendor" "$runtime" "$IHAR_STATE" || return
    _ihar_runtime_touch_marker "$vendor" "$hash"
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
    _ihar_runtime_touch_marker "$vendor" "$hash"
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

  _ihar_runtime_freeze "$runtime" "$render" "$mode"
  _ihar_runtime_touch_marker "$vendor" "$hash"
}

_ihar_runtime_touch_marker() {
  local vendor="$1" hash="$2"
  [[ -f "$IHAR_STATE/home.json" ]] || return 0
  ihar_python ihar.state_marker --touch-runtime \
    "$IHAR_STATE/home.json" "$hash" "${IHAR_PROFILE:-standard}" "$vendor" \
    || ihar_die 3 "cannot refresh authoritative runtime use for $hash"
}

# _ihar_runtime_freeze <runtime> <render> <mode> — seal what ihar rendered, and only
# that.
#
# Freezing the whole directory was wrong, and fail-closed about it: sealing runs an
# app-server against the published home, and Codex initialises its own sqlite state
# there — goals, logs, memories, and their -wal/-shm companions. A blanket chmod 444
# made those read-only, so the next launch's app-server aborted with "failed to
# initialize sqlite state runtime" and hook verification could never pass.
#
# The rendered files are the security assets — hooks.json, ihar-policy.json,
# config.toml, settings.json — and they are exactly the ones this seals. Vendor state
# the vendor writes itself stays writable, because the vendor cannot run otherwise.
_ihar_runtime_freeze() {
  local runtime="$1" render="$2" mode="$3" perm=600 file name
  [[ "$mode" == "immutable" ]] && perm=444
  [[ -n "$render" && -d "$render" ]] || return 0

  # Read-only to the agent as well as to us: under an enforced profile the sandbox
  # denies the directory, and this is the second layer.
  for file in "$render"/*; do
    [[ -f "$file" ]] || continue
    name="$(basename "$file")"
    [[ -f "$runtime/$name" ]] && chmod "$perm" "$runtime/$name" 2>/dev/null
  done
  # ihar's own record of what it sealed, produced after publication rather than
  # rendered, and therefore absent from the loop above.
  [[ -f "$runtime/.ihar-sealed" ]] && chmod "$perm" "$runtime/.ihar-sealed" 2>/dev/null
  return 0
}

# _ihar_rtrim_blank — stdin without its trailing blank lines.
_ihar_rtrim_blank() {
  awk '{ line[NR] = $0; if ($0 ~ /[^[:space:]]/) last = NR }
       END { for (i = 1; i <= last; i++) print line[i] }'
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
      # The block is appended after a blank-line separator, so deleting the block
      # leaves that separator behind and a byte comparison then reports a drift the
      # second launch of an unchanged configuration always has. Trimming both sides
      # makes the comparison about content rather than about the separator.
      if ! cmp -s <(_ihar_rtrim_blank < "$file") \
                  <(sed '/# ihar:hook-trust:start/,$d' "$runtime/$relative" | _ihar_rtrim_blank); then
        ihar_die 3 "runtime home $runtime has drifted at $relative; rendering into an existing home is never allowed"
      fi
      continue
    fi
    if ! cmp -s "$file" "$runtime/$relative"; then
      ihar_die 3 "runtime home $runtime has drifted at $relative; rendering into an existing home is never allowed"
    fi
  done < <(find "$render" -type f -print0)
}
