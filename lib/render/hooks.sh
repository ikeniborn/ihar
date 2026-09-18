#!/usr/bin/env bash
# Produce the files one configuration renders into a runtime home (LLD 5.5, 6.1).
#
# Failure class: fail-closed. A render that cannot be produced aborts the launch,
# because the rendered files are layers one and two.

# ihar_manifest_digest — the hook manifest's digest, an input to the configuration
# hash, so a manifest change produces a new runtime home rather than reusing one
# rendered from the previous manifest.
ihar_manifest_digest() {
  local manifest="$IHAR_ROOT/manifests/hooks.json"
  [[ -f "$manifest" ]] || { printf 'none\n'; return 0; }
  sha256sum "$manifest" | cut -c1-16
}

# ihar_render_all <vendor> <render-dir> — everything this configuration writes.
ihar_render_all() {
  local vendor="$1" render="$2"
  mkdir -p "$render"

  local manifest="$IHAR_ROOT/manifests/hooks.json"
  [[ -f "$manifest" ]] || ihar_die 3 "the hook manifest is missing at $manifest"

  local home_var block
  case "$vendor" in
    claude) home_var=CLAUDE_CONFIG_DIR ;;
    codex)  home_var=CODEX_HOME ;;
  esac

  block="$(ihar_python ihar.render.hooks "$vendor" "$IHAR_PROFILE" "$manifest" "$home_var")" \
    || ihar_die 3 "cannot render the hook manifest for $vendor"

  case "$vendor" in
    claude)
      # The hook block is one managed key of settings.json (LLD 4.3).
      printf '%s\n' "$block" > "$render/settings.json"
      ;;
    codex)
      # Codex reads one file whose whole content is the hook block.
      printf '%s\n' "$block" > "$render/hooks.json"
      # The managed regions arrive with their own slices; an empty file is what the
      # trust block is appended to after publication.
      : > "$render/config.toml"
      ;;
  esac

  ihar_render_policy "$vendor" "$render"
}

# ihar_render_policy <vendor> <render-dir> — the effective policy, next to the vendor
# configuration (LLD 6.2).
#
# Hooks read this rather than their environment. Under the Codex app-server daemon a
# hook inherits whatever environment the daemon started with, which may belong to an
# entirely different launch, so an environment variable cannot say which policy is in
# force for the session actually running.
ihar_render_policy() {
  local vendor="$1" render="$2"
  ihar_python ihar.render.policy \
    "$vendor" "$IHAR_PROFILE" "$IHAR_PROFILE_HOOKS" "$IHAR_PROFILE_MASKING_LEVEL" \
    "$IHAR_STATE" "$IHAR_STORE" "$IHAR_STATE_ROOT" \
    > "$render/ihar-policy.json" \
    || ihar_die 3 "cannot render the effective policy for $vendor"
}

# ihar_seal_runtime <vendor> <runtime> — make ihar's own hooks trusted, in place.
#
# Runs after publication and inside the materialisation lock, because the key a hook
# is trusted under embeds the absolute path of the rendered hooks.json: sealing a
# staging directory would record a path that the publish then renames away.
#
# Claude has no trust API, so there is nothing to seal there; its assurance is the
# digest pin plus the conformance record.
ihar_seal_runtime() {
  local vendor="$1" runtime="$2"
  [[ "$vendor" == codex ]] || return 0
  [[ -x "$IHAR_CODEX_BIN" ]] || return 0

  local out status=0
  out="$(ihar_python ihar.codex.hooks_trust --seal "$IHAR_CODEX_BIN" "$runtime" \
          "$IHAR_PROJECT_ROOT" 2>&1)" || status=$?
  if (( status != 0 )); then
    if [[ "$IHAR_PROFILE_HOOKS" == "enforced" ]]; then
      ihar_die 3 "cannot make the rendered hooks trusted: ${out:-no output}"
    fi
    ihar_warn "hooks are rendered but not trusted: ${out:-no output}"
    return 0
  fi
  printf '%s\n' "$out" > "$runtime/.ihar-sealed"
}

# ihar_verify_hook_trust <vendor> <runtime> — refuse a launch whose required hooks are
# not trusted (LLD 6.5).
ihar_verify_hook_trust() {
  local vendor="$1" runtime="$2"
  [[ "$IHAR_PROFILE_HOOKS" == "enforced" ]] || return 0
  [[ "$vendor" == codex ]] || return 0
  [[ -x "$IHAR_CODEX_BIN" ]] || ihar_die 3 "profile '$IHAR_PROFILE' enforces hooks but the codex binary is absent"

  local out status=0
  out="$(ihar_python ihar.codex.hooks_trust --verify "$IHAR_CODEX_BIN" "$runtime" \
          "$IHAR_PROJECT_ROOT" security-pretool.py 2>&1)" || status=$?
  (( status == 0 )) || ihar_die 3 "profile '$IHAR_PROFILE' enforces hooks, and Codex does not trust them:
${out:-no detail}"
}
