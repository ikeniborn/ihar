#!/usr/bin/env bash
# Validated repository-owned portable assets (LLD 2.5).
#
# Failure class: fail-closed (3) for a missing required source. Optional sources
# are reported on stdout for later collection and do not prevent installation.

# ihar_asset_inventory <vendor|all> — print source, target, kind, required and
# runtime as tab-separated fields from the canonical asset manifest. Exit 3 on an
# unreadable or invalid manifest.
ihar_asset_inventory() {
  local vendor="$1"
  ihar_python ihar.inventory assets "$IHAR_ROOT/manifests/assets.json" "$vendor" \
    || { ihar_error "cannot read tracked asset inventory"; return 3; }
}

# ihar_mutable_inventory <vendor|all> — print canonical store source, runtime
# target and kind from the separate mutable-link inventory.
ihar_mutable_inventory() {
  local vendor="$1"
  ihar_python ihar.inventory mutable-links \
    "$IHAR_ROOT/manifests/mutable-links.json" "$vendor" \
    || { ihar_error "cannot read mutable-link inventory"; return 3; }
}

# ihar_prepare_mutable_store <store> — create canonical owners, never their file
# payloads. Vendors create missing auth files through dangling runtime links.
# Existing auth and plugin bytes are never copied, removed or replaced.
ihar_prepare_mutable_store() {
  local store="$1" inventory source target kind path
  inventory="$(ihar_mutable_inventory all)" || return 3
  while IFS=$'\t' read -r source target kind; do
    [[ -n "$source" ]] || continue
    path="$store/$source"
    case "$kind" in
      directory)
        (umask 077; mkdir -p -- "$path") \
          || { ihar_error "cannot create mutable store directory $path"; return 3; }
        ;;
      file)
        (umask 077; mkdir -p -- "$(dirname "$path")") \
          || { ihar_error "cannot create mutable store parent for $path"; return 3; }
        ;;
    esac
  done <<< "$inventory"
  [[ ! -d "$store/auth" ]] || chmod 700 "$store/auth" \
    || { ihar_error "cannot protect mutable auth root $store/auth"; return 3; }
}

# ihar_asset_validate <manifest> — verify every required repository source exists
# before a store stage is created or changed. Exit 3 on failure.
ihar_asset_validate() {
  local manifest="$1" inventory source target kind required runtime path
  inventory="$(ihar_python ihar.inventory assets "$manifest" all)" || {
    ihar_error "cannot read tracked asset inventory"
    return 3
  }
  while IFS=$'\t' read -r source target kind required runtime; do
    [[ -n "$source" ]] || continue
    [[ "$required" == true ]] || continue
    path="$IHAR_ROOT/$source"
    case "$kind" in
      directory) [[ -d "$path" ]] ;;
      file) [[ -f "$path" ]] ;;
      *) false ;;
    esac || { ihar_error "required tracked asset is missing: $source"; return 3; }
  done <<< "$inventory"
}

# ihar_asset_diagnostics — print one stable diagnostic per declared source:
# required|optional<TAB>present|missing<TAB>source<TAB>target.
ihar_asset_diagnostics() {
  local inventory source target kind required runtime path presence
  inventory="$(ihar_asset_inventory all)" || return 3
  while IFS=$'\t' read -r source target kind required runtime; do
    [[ -n "$source" ]] || continue
    path="$IHAR_ROOT/$source"
    if [[ "$kind" == directory && -d "$path" ]] || [[ "$kind" == file && -f "$path" ]]; then
      presence=present
    else
      presence=missing
    fi
    if [[ "$required" == true ]]; then required=required; else required=optional; fi
    printf '%s\t%s\t%s\t%s\n' "$required" "$presence" "$source" "$target"
  done <<< "$inventory"
}

# ihar_asset_store_roots — repository-owned top-level store paths, once each.
ihar_asset_store_roots() {
  ihar_asset_inventory all | awk -F '\t' '{split($1, path, "/"); if (!seen[path[1]]++) print path[1]}'
}

# ihar_asset_install <stage> — copy declared portable sources into a store stage.
# Required sources are validated before this function changes the stage. Exit 3 for
# a missing required source; optional missing sources remain absent and diagnosed.
ihar_asset_install() {
  local stage="$1" inventory source target kind required runtime path destination
  ihar_asset_validate "$IHAR_ROOT/manifests/assets.json" || return 3
  inventory="$(ihar_asset_inventory all)" || return 3
  while IFS=$'\t' read -r source target kind required runtime; do
    [[ -n "$source" ]] || continue
    path="$IHAR_ROOT/$source"
    destination="$stage/$source"
    case "$kind" in
      directory)
        [[ -d "$path" ]] || continue
        rm -rf -- "$destination"
        mkdir -p "$(dirname "$destination")" || return 1
        cp -R -- "$path" "$destination" || return 1
        ;;
      file)
        [[ -f "$path" ]] || continue
        mkdir -p "$(dirname "$destination")" || return 1
        cp -- "$path" "$destination" || return 1
        ;;
    esac
  done <<< "$inventory"
  ihar_asset_diagnostics
}
