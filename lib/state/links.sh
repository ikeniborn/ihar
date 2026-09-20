#!/usr/bin/env bash
# Whole-entry symlinks from the store and from project state into a runtime home.
#
# The repair rules are lifted from iclaude:lib/config/isolated.sh:link_shared_assets:
# a correct link is untouched, a wrong link or a materialised real copy is replaced
# with a warning, and the source is never mutated. Absent store sources are skipped;
# declared state files intentionally retain dangling links until the vendor creates
# their canonical targets.
#
# Failure class: fail-soft for a link that cannot be made, because the vendor may not
# need that entry; a caller whose profile depends on one verifies it separately.

# Store entries, as `<store-relative source>:<runtime-relative name>`.
_IHAR_STORE_LINKS_CLAUDE=(
  "skills:skills"
  "hooks:hooks"
  "manifests/config/claude/commands:commands"
  "manifests/config/claude/agents:agents"
  "manifests/config/claude/scripts:scripts"
  "manifests/config/claude/CLAUDE.md:CLAUDE.md"
  "manifests/config/claude/router.json:router.json"
  "plugins/claude:plugins"
  "auth/claude/.credentials.json:.credentials.json"
)

_IHAR_STORE_LINKS_CODEX=(
  "skills:skills"
  "hooks:hooks"
  "manifests/config/codex/rules:rules"
  "manifests/config/codex/agents:agents"
  "manifests/config/codex/profiles:profiles"
  "plugins/codex:plugins"
  "auth/codex/auth.json:auth.json"
)

ihar_state_inventory() {
  ihar_python ihar.inventory state "$IHAR_ROOT/manifests/state.json" "$1"
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
  local vendor="$1" runtime="$2" state="$3" entry source name kind suffix inventory

  local -n store_links="_IHAR_STORE_LINKS_${vendor^^}"
  for entry in "${store_links[@]}"; do
    source="$IHAR_STORE/${entry%%:*}"
    name="${entry##*:}"
    _ihar_link "$source" "$runtime/$name"
  done

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
