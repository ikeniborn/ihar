#!/usr/bin/env bash
# Install and update, entirely as the invoking user (LLD 14.3).
#
# Nothing here needs `sudo` and nothing writes outside the user's own directories.
# That is a property worth keeping rather than a coincidence: a harness that asks for
# root to install is a harness people install as root, and then everything it runs
# afterwards inherits that.
#
# Every network step goes through a seam — IHAR_DOWNLOAD, IHAR_NODE_DIST_URL,
# IHAR_CODEX_RELEASE_URL, IHAR_UV_INSTALL_URL — so the tests exercise the real logic
# against local fixtures instead of the internet.
#
# Failure class: runtime for a step that cannot complete; fail-closed for a digest
# that does not match what the lockfile pins.

IHAR_NODE_DIST_URL="${IHAR_NODE_DIST_URL:-https://nodejs.org/dist}"
IHAR_CODEX_RELEASE_URL="${IHAR_CODEX_RELEASE_URL:-https://github.com/openai/codex/releases/download}"
IHAR_NPM_PACKAGE="${IHAR_NPM_PACKAGE:-@anthropic-ai/claude-code}"

# ihar_download <url> <target> — one seam for every fetch.
ihar_download() {
  local url="$1" target="$2"
  mkdir -p "$(dirname "$target")"
  if [[ -n "${IHAR_DOWNLOAD:-}" ]]; then
    "$IHAR_DOWNLOAD" "$url" "$target"
    return $?
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 -o "$target" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$target" "$url"
  else
    ihar_die 1 "neither curl nor wget is installed, so $url cannot be fetched"
  fi
}

ihar_sha256() { sha256sum "$1" | cut -d' ' -f1; }

# --------------------------------------------------------------------------- #

# ihar_cmd_install — every component the lockfile pins, under this user, no sudo.
ihar_cmd_install() {
  ihar_with_lock --required "$IHAR_STORE/.ihar-store.lock" 900 _ihar_install_all
}

_ihar_install_all() {
  ihar_install_store
  ihar_install_command
  ihar_install_example_config
  ihar_install_python
  ihar_install_codex
  ihar_install_claude
  ihar_install_conformance
  if [[ "${IHAR_FLAG_MICROVM:-false}" == true ]]; then ihar_install_microvm; fi

  ihar_lockfile_hash > "$IHAR_STORE/.last-lockfile-hash"
  ihar_info "install complete; run 'ihar check' to see what is in force"
}

# ihar_install_microvm — import the specialised guest built by iclaude's installer.
#
# The source is explicit because the compatible rootfs contains guest-init, sshd and
# rsync; treating an arbitrary Linux ext4 image as compatible would make `install`
# report success and every launch fail later. Digests remain owned by ihar's lockfile.
ihar_install_microvm() {
  local source="${IHAR_MICROVM_SOURCE_DIR:-}"
  [[ -n "$source" ]] || ihar_die 1 "--microvm requires IHAR_MICROVM_SOURCE_DIR pointing at a compatible asset directory"
  local name key src pinned actual version stage
  local -a names=(firecracker vmlinux rootfs.ext4 client_key client_key.pub host_key.pub)
  mkdir -p "$IHAR_STORE/bin" "$IHAR_STORE/microvm/versions"
  for name in firecracker vmlinux rootfs.ext4; do
    src="$source/$name"
    [[ -f "$src" ]] || ihar_die 1 "microVM source is missing $src"
    case "$name" in
      firecracker) key=firecracker ;;
      vmlinux) key=kernel ;;
      rootfs.ext4) key=rootfs ;;
    esac
    pinned="$(ihar_lockfile_get "microvm.$key")"
    [[ -n "$pinned" ]] || ihar_die 3 "the lockfile does not pin microvm.$key"
    actual="$(ihar_sha256 "$src")"
    [[ "$actual" == "$pinned" ]] \
      || ihar_die 3 "$src does not match microvm.$key in the lockfile"
  done
  for name in client_key client_key.pub host_key.pub; do
    [[ -f "$source/$name" ]] || ihar_die 1 "microVM source is missing $source/$name"
  done
  ssh-keygen -l -f "$source/host_key.pub" >/dev/null 2>&1 \
    || ihar_die 3 "microVM source host_key.pub is not a valid SSH public key"
  local derived_public declared_public
  derived_public="$(ssh-keygen -y -f "$source/client_key" 2>/dev/null)" \
    || ihar_die 3 "microVM source client_key is not a valid SSH private key"
  declared_public="$(awk '{print $1, $2}' "$source/client_key.pub")"
  [[ "$(awk '{print $1, $2}' <<< "$derived_public")" == "$declared_public" ]] \
    || ihar_die 3 "microVM source client key pair does not match"

  version="$(printf '%s\n' "$(ihar_lockfile_get microvm.firecracker)" \
    "$(ihar_lockfile_get microvm.kernel)" "$(ihar_lockfile_get microvm.rootfs)" | sha256sum | cut -c1-16)"
  stage="$(mktemp -d "$IHAR_STORE/microvm/.stage-XXXXXX")" \
    || ihar_die 1 "cannot stage microVM assets"
  for name in "${names[@]}"; do
    cp "$source/$name" "$stage/$name" || { rm -rf "$stage"; ihar_die 1 "cannot stage $name"; }
  done
  chmod 755 "$stage/firecracker"; chmod 600 "$stage/client_key"
  if [[ ! -d "$IHAR_STORE/microvm/versions/$version" ]]; then
    mv "$stage" "$IHAR_STORE/microvm/versions/$version" || ihar_die 1 "cannot publish microVM assets"
  else
    rm -rf "$stage"
  fi
  ln -sfn "versions/$version" "$IHAR_STORE/microvm/.current-new"
  mv -Tf "$IHAR_STORE/microvm/.current-new" "$IHAR_STORE/microvm/current" \
    || ihar_die 1 "cannot activate microVM assets"
  for name in firecracker vmlinux rootfs.ext4; do
    ln -sfn "../microvm/current/$name" "$IHAR_STORE/bin/$name"
  done
  ihar_info "microVM assets installed from $source"
}

# --------------------------------------------------------------------------- #
# The store
# --------------------------------------------------------------------------- #

# ihar_install_store — the tracked trees, copied and pinned.
#
# Copied rather than symlinked into the checkout: the store is the trusted side of
# the boundary, and a link would put an agent's writable working tree back on the
# path a hook is loaded from.
ihar_install_store() {
  mkdir -p "$IHAR_STORE"/{bin,hooks,manifests,skills,auth/claude,auth/codex,plugins/claude,plugins/codex,verification,venv} \
    || ihar_die 1 "cannot create the store at $IHAR_STORE"
  chmod 700 "$IHAR_STORE/auth"

  local tree
  for tree in hooks manifests skills; do
    [[ -d "$IHAR_ROOT/$tree" ]] || continue
    rm -rf "$IHAR_STORE/$tree"
    cp -R "$IHAR_ROOT/$tree" "$IHAR_STORE/$tree" \
      || ihar_die 1 "cannot copy $tree into the store"
  done

  ihar_python ihar.lockfile --pin-tree hooks "$IHAR_LOCKFILE" "$IHAR_STORE" \
    || ihar_die 1 "cannot pin the hook scripts"
  ihar_info "store ready at $IHAR_STORE"
}

# --------------------------------------------------------------------------- #
# The command on PATH
# --------------------------------------------------------------------------- #

# ihar_install_command — a symlink in the user's own bin directory.
#
# Never over a file that is not already ours: a user who has their own `ihar` on PATH
# has it for a reason, and silently replacing it is the kind of help nobody asked for.
ihar_install_command() {
  local bin="${IHAR_BIN_DIR:-$HOME/.local/bin}"
  local link="$bin/ihar" target="$IHAR_ROOT/ihar.sh"

  mkdir -p "$bin" || { ihar_warn "cannot create $bin; skipping the ihar command"; return 0; }

  if [[ -L "$link" ]]; then
    if [[ "$(readlink "$link")" == "$target" ]]; then
      ihar_info "command already installed at $link"
    else
      ln -sfn "$target" "$link"
      ihar_info "repointed $link at this checkout"
    fi
  elif [[ -e "$link" ]]; then
    ihar_warn "$link exists and is not an ihar symlink; leaving it alone
add $IHAR_ROOT/ihar.sh to PATH yourself, or remove that file and install again"
    return 0
  else
    ln -s "$target" "$link"
    ihar_info "installed the command at $link"
  fi

  case ":$PATH:" in
    *":$bin:"*) ;;
    *) ihar_warn "$bin is not on PATH, so 'ihar' will not resolve until it is" ;;
  esac
}

# ihar_install_example_config — a commented example beside the real thing.
#
# Written into the checkout, never over an existing .ihar_config: the example is
# documentation, and overwriting a user's configuration with documentation would be
# a poor trade.
ihar_install_example_config() {
  local target="$IHAR_ROOT/.ihar_config.example"
  ihar_python ihar.config_example > "$target" \
    || ihar_die 1 "cannot write $target"
  ihar_info "example configuration at $target"
}

# --------------------------------------------------------------------------- #
# Components
# --------------------------------------------------------------------------- #

ihar_install_python() {
  local uv="$IHAR_STORE/bin/uv"
  if [[ ! -x "$uv" ]] && command -v uv >/dev/null 2>&1; then
    cp "$(command -v uv)" "$uv" 2>/dev/null || true
  fi

  local python="$IHAR_STORE/venv/bin/python3"
  if [[ -x "$python" ]]; then
    ihar_info "python environment already present"
    return 0
  fi

  if [[ -x "$uv" ]]; then
    "$uv" venv --quiet "$IHAR_STORE/venv" 2>/dev/null || true
  fi
  if [[ ! -x "$python" ]]; then
    python3 -m venv "$IHAR_STORE/venv" 2>/dev/null \
      || { ihar_warn "no python environment could be created; the regex masking engine will be used"; return 0; }
  fi

  # Presidio is optional by design. Without it the masking engine falls back to
  # regexes and says so in `ihar check`, which is a weaker promise honestly reported
  # rather than a failed install.
  if [[ -f "$IHAR_ROOT/lib/python/requirements.lock" ]]; then
    "$IHAR_STORE/venv/bin/pip" install --quiet -r "$IHAR_ROOT/lib/python/requirements.lock" \
      2>/dev/null || ihar_warn "optional python packages were not installed; the regex engine will be used"
  fi
  ihar_info "python environment ready"
}

# ihar_install_codex — download, verify, extract.
#
# Install and update are the same operation: the pinned version is compared with the
# version stamped beside the binary, so bumping the lockfile is what upgrades, and a
# second run with an unchanged lockfile does nothing.
ihar_install_codex() {
  local version asset archive actual pinned

  version="$(ihar_lockfile_get codex.version)"
  asset="$(ihar_lockfile_get codex.asset)"
  pinned="$(ihar_lockfile_get codex.sha256)"

  if [[ -z "$version" || -z "$asset" ]]; then
    ihar_warn "the lockfile pins no Codex release; skipping"
    return 0
  fi

  local stamp="$IHAR_STORE/bin/.codex-version"
  if [[ -x "$IHAR_STORE/bin/codex" && "$(cat "$stamp" 2>/dev/null)" == "$version" ]]; then
    ihar_info "codex $version already installed"
    return 0
  fi

  archive="$IHAR_STORE/bin/.$asset"
  ihar_download "$IHAR_CODEX_RELEASE_URL/$version/$asset" "$archive" \
    || ihar_die 1 "cannot download the Codex release $version"

  actual="$(ihar_sha256 "$archive")"
  if [[ -n "$pinned" && "$actual" != "$pinned" ]]; then
    rm -f "$archive"
    # Outside an explicit update a digest mismatch is tampering or a moved tag, and
    # either way installing it would defeat every later integrity check.
    ihar_die 3 "the Codex archive digest does not match the lockfile
expected $pinned
got      $actual"
  fi

  tar -xzf "$archive" -C "$IHAR_STORE/bin" 2>/dev/null \
    || ihar_die 1 "cannot extract $archive"
  rm -f "$archive"

  local extracted
  extracted="$(find "$IHAR_STORE/bin" -maxdepth 1 -name 'codex-*' -type f | head -1)"
  [[ -n "$extracted" ]] && mv -f "$extracted" "$IHAR_STORE/bin/codex"
  chmod +x "$IHAR_STORE/bin/codex" 2>/dev/null || true
  printf '%s\n' "$version" > "$stamp"
  ihar_info "codex $version installed"
}

# ihar_install_claude — an isolated Node prefix and the CLI in it, upgraded the same
# way Codex is: by comparing the pinned version with the one stamped at install time.
#
# Checking only that the binary exists was wrong — bumping claude.version in the
# lockfile then reported "already installed" and `ihar update` upgraded nothing,
# while the conformance record went on being re-earned by the old binary.
ihar_install_claude() {
  local version node_version archive stamp
  node_version="$(ihar_lockfile_get node.version)"
  version="$(ihar_lockfile_get claude.version)"

  if [[ -z "$node_version" ]]; then
    ihar_warn "the lockfile pins no Node version; skipping the Claude CLI"
    return 0
  fi

  if [[ ! -x "$IHAR_NVM/bin/node" ]]; then
    local platform="linux-x64"
    [[ "$(uname -s)" == Darwin ]] && platform="darwin-$(uname -m | sed 's/x86_64/x64/')"
    archive="$IHAR_NVM/.node.tar.gz"
    mkdir -p "$IHAR_NVM"
    ihar_download "$IHAR_NODE_DIST_URL/v$node_version/node-v$node_version-$platform.tar.gz" "$archive" \
      || ihar_die 1 "cannot download Node $node_version"
    tar -xzf "$archive" -C "$IHAR_NVM" --strip-components=1 2>/dev/null \
      || ihar_die 1 "cannot extract Node"
    rm -f "$archive"
    ihar_info "node $node_version installed"
  fi

  stamp="$IHAR_NVM/npm-global/.claude-version"
  if [[ -x "$IHAR_CLAUDE_BIN" && "$(cat "$stamp" 2>/dev/null)" == "${version:-latest}" ]]; then
    ihar_info "claude ${version:-latest} already installed"
  else
    local spec="$IHAR_NPM_PACKAGE"
    [[ -n "$version" ]] && spec="$IHAR_NPM_PACKAGE@$version"
    PATH="$IHAR_NVM/bin:$PATH" npm install --silent --prefix "$IHAR_NVM/npm-global" -g "$spec" \
      2>/dev/null || { ihar_warn "the Claude CLI was not installed"; return 0; }
    mkdir -p "$IHAR_NVM/npm-global"
    printf '%s\n' "${version:-latest}" > "$stamp"
    ihar_info "claude ${version:-latest} installed"
  fi

  if [[ -x "$IHAR_CLAUDE_BIN" ]]; then
    ihar_python ihar.lockfile --set claude.binarySha256 "$(ihar_sha256 "$IHAR_CLAUDE_BIN")" \
      "$IHAR_LOCKFILE" || ihar_warn "cannot record the claude binary digest"
  fi
}

# ihar_install_conformance — the evidence an enforced profile needs, recorded before
# anyone can select one (LLD 6.6).
ihar_install_conformance() {
  local vendor binary
  for vendor in claude codex; do
    binary="$(eval echo "\$IHAR_${vendor^^}_BIN")"
    [[ -x "$binary" ]] || continue
    ihar_python ihar.conformance.run "$vendor" "$binary" "$IHAR_STORE" \
      "$IHAR_ROOT/manifests/hooks.json" >/dev/null \
      || ihar_warn "hook conformance did not pass for $vendor; enforced profiles will refuse to launch"
  done
}

# --------------------------------------------------------------------------- #
# Update
# --------------------------------------------------------------------------- #

# ihar_cmd_update — replace pinned components, then prove the hooks still hold.
#
# A vendor upgrade invalidates the conformance record by construction, because the
# record is keyed by the binary digest. Re-running it here is what keeps an enforced
# profile from inheriting a pass that was earned by a different binary.
ihar_cmd_update() {
  ihar_with_lock --required "$IHAR_STORE/.ihar-store.lock" 900 _ihar_update_all
}

_ihar_update_all() {
  ihar_install_store
  # A running daemon holds the binary about to be replaced, and it goes on serving
  # clients from the old one until something restarts it — the version-skew class
  # LLD 5.5 names. Stopped before the replacement, and only the ones that were
  # running are put back afterwards.
  ihar_codex_daemon_stop_all
  ihar_install_codex
  ihar_install_claude
  ihar_install_conformance
  ihar_codex_daemon_start_pending
  ihar_lockfile_hash > "$IHAR_STORE/.last-lockfile-hash"
  ihar_info "update complete"
}
