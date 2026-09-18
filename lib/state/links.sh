#!/usr/bin/env bash
# Whole-entry symlinks from the store and from project state into a runtime home.
#
# The repair rules are lifted from iclaude:lib/config/isolated.sh:link_shared_assets:
# a correct link is untouched, a wrong link or a materialised real copy is replaced
# with a warning, a stale link into a since-removed entry is pruned, an absent source
# is skipped, and the source is never mutated.
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

# Vendor state directories, which persist across every profile switch. Files the
# vendor seeds itself, such as .claude.json and history.jsonl, are not linked here:
# a dangling link would break the vendor, and only the adapter knows what valid
# initial content is. S4 owns that seeding.
_IHAR_STATE_DIRS_CLAUDE=(projects sessions session-env file-history)
_IHAR_STATE_DIRS_CODEX=(sessions app-server-control)

# _ihar_link <source> <target> — idempotent, self-repairing.
_ihar_link() {
  local source="$1" target="$2"

  if [[ ! -e "$source" ]]; then
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
  local vendor="$1" runtime="$2" state="$3" entry source name

  local -n store_links="_IHAR_STORE_LINKS_${vendor^^}"
  for entry in "${store_links[@]}"; do
    source="$IHAR_STORE/${entry%%:*}"
    name="${entry##*:}"
    _ihar_link "$source" "$runtime/$name"
  done

  local -n state_dirs="_IHAR_STATE_DIRS_${vendor^^}"
  for name in "${state_dirs[@]}"; do
    source="$state/st/$vendor/$name"
    mkdir -p "$source"
    _ihar_link "$source" "$runtime/$name"
  done
}
