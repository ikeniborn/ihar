#!/usr/bin/env bash
# Whole-entry symlinks from the store and from project state into a runtime home.
#
# The repair rules are lifted from iclaude:lib/config/isolated.sh:link_shared_assets:
# a correct link is untouched, a wrong link or a materialised real copy is replaced
# with a warning, and the source is never mutated. Absent store sources are skipped;
# declared state files intentionally retain dangling links until the vendor creates
# their canonical targets.
#
# Failure class: fail-closed for an invalid published runtime link or a declared
# required store asset; fail-soft while initially linking an absent optional asset.

ihar_state_inventory() {
  ihar_python ihar.inventory state "$IHAR_ROOT/manifests/state.json" "$1"
}

# _ihar_reconcile_runtime_mutable_links <vendor> <runtime-dir> <inventory> —
# validate every target before creating any link. A materialised or wrong target
# may contain the only auth/plugin bytes from an older layout, so preserve it and
# fail with a recovery instruction instead of repairing over it.
_ihar_reconcile_runtime_mutable_links() {
  local vendor="$1" runtime="$2" inventory="$3"
  local source name kind target

  while IFS=$'\t' read -r source name kind; do
    [[ -n "$source" ]] || continue
    source="$IHAR_STORE/$source"
    target="$runtime/$name"
    if [[ -L "$target" ]]; then
      if [[ "$(readlink "$target")" != "$source" ]]; then
        ihar_die 3 "runtime mutable link $target points to $(readlink "$target"), not $source, and was preserved; remove or recover the wrong link, then retry"
      fi
    elif [[ -e "$target" ]]; then
      ihar_die 3 "runtime mutable entry $target is materialised and was preserved; move it to a recovery location, then retry so ihar can link $source"
    fi
  done <<< "$inventory"

  ihar_prepare_mutable_store "$IHAR_STORE" "$vendor" || return 3

  while IFS=$'\t' read -r source name kind; do
    [[ -n "$source" ]] || continue
    source="$IHAR_STORE/$source"
    target="$runtime/$name"
    [[ -L "$target" ]] && continue
    mkdir -p -- "$(dirname "$target")" \
      || ihar_die 3 "cannot create runtime mutable parent for $target"
    ln -s "$source" "$target" \
      || ihar_die 3 "cannot link runtime mutable entry $target -> $source"
  done <<< "$inventory"
}

ihar_verify_runtime_mutable_links() {
  local vendor="$1" runtime="$2" inventory
  inventory="$(ihar_mutable_inventory "$vendor")" || return 3
  ihar_mutable_preflight "$IHAR_STORE" "$vendor" || return 3
  _ihar_reconcile_runtime_mutable_links "$vendor" "$runtime" "$inventory"
}

# ihar_verify_runtime_asset_links <vendor> <runtime-dir> — verify store links
# before reusing a published runtime. Reuse never repairs or removes an entry: a
# wrong or materialised path may be the only evidence of runtime tampering.
ihar_verify_runtime_asset_links() {
  local vendor="$1" runtime="$2"
  local inventory declared_source name kind required runtime_link topology source target

  inventory="$(ihar_asset_topology_inventory "$vendor")" || return 3
  while IFS=$'\t' read -r declared_source name kind required runtime_link topology; do
    [[ "$runtime_link" == true ]] || continue
    source="$IHAR_STORE/$declared_source"
    target="$runtime/$name"

    if [[ "$required" == true && "$topology" != "$kind" ]]; then
      if [[ "$topology" == absent ]]; then
        ihar_die 3 "required runtime asset is missing from the store: $source"
      fi
      ihar_die 3 "required runtime asset has topology $topology, expected $kind: $source"
    fi
  done <<< "$inventory"

  while IFS=$'\t' read -r declared_source name kind required runtime_link topology; do
    [[ "$runtime_link" == true ]] || continue
    source="$IHAR_STORE/$declared_source"
    target="$runtime/$name"

    if [[ "$topology" != "$kind" ]]; then
      if [[ -L "$target" ]]; then
        ihar_die 3 "optional runtime asset link $target has store topology $topology, expected $kind, and was preserved; remove it, then retry"
      fi
      [[ -e "$target" ]] \
        && ihar_die 3 "runtime asset entry $target is materialised and was preserved; move it to a recovery location, then retry"
      continue
    fi

    if [[ -L "$target" ]]; then
      if [[ "$(readlink "$target")" != "$source" ]]; then
        ihar_die 3 "runtime asset link $target points to $(readlink "$target"), not $source, and was preserved; remove or recover the wrong link, then retry"
      fi
    elif [[ -e "$target" ]]; then
      ihar_die 3 "runtime asset entry $target is materialised and was preserved; move it to a recovery location, then retry"
    elif [[ "$required" == true ]]; then
      ihar_die 3 "required runtime asset link is missing: $target; it was not repaired"
    fi
  done <<< "$inventory"
}

# ihar_verify_runtime_state_links <vendor> <runtime-dir> <state-dir> — reconcile
# state links when reusing a published runtime. This never removes a materialised
# runtime entry: that entry may contain the only copy of vendor state from an older
# runtime.
ihar_verify_runtime_state_links() {
  local vendor="$1" runtime="$2" state="$3"
  local name kind suffix inventory entry source target
  local -a entries=()

  inventory="$(ihar_state_inventory "$vendor")" \
    || ihar_die 3 "cannot read $vendor state inventory"
  while IFS=$'\t' read -r name kind; do
    [[ -n "$name" ]] || continue
    if [[ "$kind" == sqlite-family ]]; then
      for suffix in '' -wal -shm; do entries+=("$name$suffix"$'\t'file); done
    else
      entries+=("$name"$'\t'"$kind")
    fi
  done <<< "$inventory"

  # Validate the complete set before creating anything. A fail-closed result must
  # not leave half the runtime linked while an unsafe state entry remains.
  for entry in "${entries[@]}"; do
    name="${entry%%$'\t'*}"
    source="$state/st/$vendor/$name"
    target="$runtime/$name"
    if [[ -L "$target" ]]; then
      if [[ "$(readlink "$target")" != "$source" ]]; then
        ihar_die 3 "runtime state link $target points to $(readlink "$target"), not $source, and was preserved; remove or recover the wrong link, then retry"
      fi
    elif [[ -e "$target" ]]; then
      ihar_die 3 "runtime state entry $target is materialised and was preserved; move it to a recovery location, then retry so ihar can link $source"
    fi
  done

  for entry in "${entries[@]}"; do
    name="${entry%%$'\t'*}"
    kind="${entry#*$'\t'}"
    source="$state/st/$vendor/$name"
    target="$runtime/$name"

    if [[ "$kind" == directory ]]; then
      mkdir -p "$source" \
        || ihar_die 3 "cannot create canonical state directory $source"
    else
      mkdir -p "$(dirname "$source")" \
        || ihar_die 3 "cannot create canonical state parent for $source"
    fi

    # Recheck after validation: an active vendor may have changed the pathname.
    # Never unlink during reuse; preserving a wrong or materialised entry is safer
    # than racing a vendor write.
    if [[ -L "$target" ]]; then
      if [[ "$(readlink "$target")" != "$source" ]]; then
        ihar_die 3 "runtime state link $target points to $(readlink "$target"), not $source, and was preserved; remove or recover the wrong link, then retry"
      fi
      continue
    elif [[ -e "$target" ]]; then
      ihar_die 3 "runtime state entry $target is materialised and was preserved; move it to a recovery location, then retry so ihar can link $source"
    fi

    mkdir -p "$(dirname "$target")" \
      || ihar_die 3 "cannot create runtime state parent for $target"
    ln -s "$source" "$target" \
      || ihar_die 3 "cannot link runtime state $target -> $source"
  done
}

# _ihar_link <source> <target> — idempotent, self-repairing.
_ihar_link() {
  local source="$1" target="$2" allow_missing="${3:-false}"

  if [[ ! -e "$source" && "$allow_missing" != true ]]; then
    # A stale link into a source that has since been removed is pruned, so the
    # runtime home never carries a dangling entry.
    if [[ -L "$target" && ! -e "$target" ]]; then
      rm -f "$target"
    fi
    return 0
  fi

  if [[ -L "$target" ]]; then
    [[ "$(readlink "$target")" == "$source" ]] && return 0
    ihar_warn "repointing $target"
    rm -f "$target"
  elif [[ -e "$target" ]]; then
    # A real copy where a link belongs means the entry was de-shared: the runtime
    # would drift from the store and stop receiving updates.
    ihar_warn "replacing a materialised copy at $target with a link into the store"
    rm -rf "$target"
  fi

  ln -s "$source" "$target" 2>/dev/null || ihar_warn "cannot link $target -> $source"
}

# ihar_link_runtime <vendor> <runtime-dir> <state-dir> — wire one runtime home.
ihar_link_runtime() {
  local vendor="$1" runtime="$2" state="$3" asset_inventory mutable_inventory source name kind required runtime_link topology suffix inventory

  asset_inventory="$(ihar_asset_topology_inventory "$vendor")" || return 3
  mutable_inventory="$(ihar_mutable_inventory "$vendor")" || return 3
  ihar_mutable_preflight "$IHAR_STORE" "$vendor" || return 3
  while IFS=$'\t' read -r source name kind required runtime_link topology; do
    [[ "$runtime_link" == true ]] || continue
    if [[ "$required" == true && "$topology" != "$kind" ]]; then
      source="$IHAR_STORE/$source"
      if [[ "$topology" == absent ]]; then
        ihar_error "required runtime asset is missing from the store: $source"
        return 3
      fi
      ihar_error "required runtime asset has topology $topology, expected $kind: $source"
      return 3
    fi
  done <<< "$asset_inventory"

  while IFS=$'\t' read -r source name kind required runtime_link topology; do
    [[ "$runtime_link" == true ]] || continue
    source="$IHAR_STORE/$source"
    if [[ "$topology" != "$kind" ]]; then
      ihar_warn "optional runtime asset has topology $topology, expected $kind: $source"
      continue
    fi
    mkdir -p "$(dirname "$runtime/$name")"
    _ihar_link "$source" "$runtime/$name"
  done <<< "$asset_inventory"

  _ihar_reconcile_runtime_mutable_links "$vendor" "$runtime" "$mutable_inventory"

  inventory="$(ihar_state_inventory "$vendor")" \
    || { ihar_warn "cannot read $vendor state inventory"; return 3; }
  while IFS=$'\t' read -r name kind; do
    [[ -n "$name" ]] || continue
    case "$kind" in
      directory)
        source="$state/st/$vendor/$name"
        mkdir -p "$source" "$(dirname "$runtime/$name")"
        _ihar_link "$source" "$runtime/$name" true
        ;;
      file)
        source="$state/st/$vendor/$name"
        mkdir -p "$(dirname "$source")" "$(dirname "$runtime/$name")"
        _ihar_link "$source" "$runtime/$name" true
        ;;
      sqlite-family)
        for suffix in '' -wal -shm; do
          source="$state/st/$vendor/$name$suffix"
          mkdir -p "$(dirname "$source")" "$(dirname "$runtime/$name$suffix")"
          _ihar_link "$source" "$runtime/$name$suffix" true
        done
        ;;
    esac
  done <<< "$inventory"
}
