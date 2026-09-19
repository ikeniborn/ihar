#!/usr/bin/env bash
# Isolated profile: Firecracker topology and fail-closed guest network policy (LLD 9).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
export IHAR_ROOT="$ROOT"

source "$ROOT/lib/core/logging.sh"
source "$ROOT/lib/core/init.sh"
ihar_init "$ROOT/ihar.sh"
source "$ROOT/lib/sandbox/microvm.sh"

mkdir -p "$IHAR_STORE/bin" "$IHAR_STATE_ROOT/project/r/hash/codex" \
  "$IHAR_STATE_ROOT/project/r/hash/claude" "$IHAR_STATE_ROOT/project/st"
for asset in firecracker vmlinux rootfs.ext4; do
  : > "$IHAR_STORE/bin/$asset"
done
chmod +x "$IHAR_STORE/bin/firecracker"
mkdir -p "$IHAR_STORE/microvm/current"
ssh-keygen -q -t ed25519 -N '' -f "$IHAR_STORE/microvm/current/client_key"
cp "$IHAR_STORE/microvm/current/client_key.pub" "$IHAR_STORE/microvm/current/host_key.pub"
python3 - "$IHAR_STORE/bin" "$IHAR_TEST_TMP/lockfile.json" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
digest = lambda name: hashlib.sha256((root / name).read_bytes()).hexdigest()
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "schema": 1, "installedAt": "2026-09-19T00:00:00Z",
    "microvm": {"firecracker": digest("firecracker"), "kernel": digest("vmlinux"), "rootfs": digest("rootfs.ext4")}
}))
PY
IHAR_LOCKFILE="$IHAR_TEST_TMP/lockfile.json"
export IHAR_LOCKFILE
export IHAR_RUNTIME="$IHAR_STATE_ROOT/project/r/hash/codex"
export IHAR_STATE="$IHAR_STATE_ROOT/project"
export IHAR_GATEWAY_ACTIVE_PORT=43123
export IHAR_LAUNCH_ID=018f-test

# --- preflight -----------------------------------------------------------------------

IHAR_MICROVM_KVM="$IHAR_TEST_TMP/missing-kvm"
preflight() {
  bash -c 'source "$1/lib/core/logging.sh"; source "$1/lib/core/init.sh"; ihar_init "$1/ihar.sh"; source "$1/lib/store/lockfile.sh"; source "$1/lib/sandbox/microvm.sh"; ihar_microvm_preflight' -- "$ROOT"
}
export IHAR_MICROVM_KVM
assert_exit "missing KVM fails closed" 3 preflight
: > "$IHAR_TEST_TMP/kvm"
IHAR_MICROVM_KVM="$IHAR_TEST_TMP/kvm"
export IHAR_MICROVM_KVM
assert_exit "complete assets pass preflight" 0 preflight

# --- Firecracker topology -------------------------------------------------------------

session="$IHAR_TEST_TMP/session"
mkdir -p "$session"
cp "$IHAR_STORE/bin/rootfs.ext4" "$session/rootfs.ext4"
: > "$session/policy.ext4"
: > "$session/workspace.ext4"
: > "$session/state.ext4"
config="$(ihar_microvm_write_config "$session" tap-ihar-1 172.31.0.2 \
  "$session/rootfs.ext4" "$session/policy.ext4" "$session/workspace.ext4" "$session/state.ext4")"
json="$(cat "$config")"
assert_contains "rootfs is a private writable copy" "$json" '"drive_id": "rootfs"'
assert_contains "policy bundle is attached" "$json" '"drive_id": "policy"'
assert_contains "policy bundle is read-only" "$json" '"is_read_only": true'
assert_contains "workspace is attached separately" "$json" '"drive_id": "workspace"'
assert_contains "workspace is writable" "$json" '"is_read_only": false'
assert_contains "vendor state is a separate writable drive" "$json" '"drive_id": "state"'
assert_contains "tap is attached" "$json" '"host_dev_name": "tap-ihar-1"'
assert_contains "each slot uses a non-overlapping /30 route" "$json" '255.255.255.252'

rootfs_source="$session/rootfs-source"
rootfs_auth="$rootfs_source/root/.ssh/authorized_keys"
mkdir -p "$(dirname "$rootfs_auth")"
printf '%s\n' 'stale-key' > "$rootfs_auth"
mkdir -p "$rootfs_source/etc/ssh/sshd_config.d"
printf '%s\n' 'PermitRootLogin no' 'AllowUsers iclaude' > \
  "$rootfs_source/etc/ssh/sshd_config.d/iclaude.conf"
rootfs_fixture="$session/rootfs-fixture.ext4"
_ihar_microvm_make_image "$rootfs_fixture" "$rootfs_source" 16
debugfs -w -R 'set_inode_field /root/.ssh mode 040600' "$rootfs_fixture" >/dev/null 2>&1
_ihar_microvm_prepare_rootfs "$rootfs_fixture"
installed_key="$(debugfs -R 'cat /root/.ssh/authorized_keys' "$rootfs_fixture" 2>/dev/null)"
assert_eq "the launch copy trusts the installed client key" \
  "$(cat "$IHAR_STORE/microvm/current/client_key.pub")" "$installed_key"
root_ssh_mode="$(debugfs -R 'stat /root/.ssh' "$rootfs_fixture" 2>/dev/null | awk '/Mode:/ {print $6; exit}')"
assert_eq "the root SSH directory is traversable only by root" "0700" "$root_ssh_mode"
guest_sshd_policy="$(debugfs -R 'cat /etc/ssh/sshd_config.d/iclaude.conf' "$rootfs_fixture" 2>/dev/null)"
assert_contains "the launch copy permits key-only root login" "$guest_sshd_policy" \
  'PermitRootLogin prohibit-password'
assert_contains "the launch copy admits only the provisioned account" "$guest_sshd_policy" \
  'AllowUsers root'

env_file="$session/guest-env.sh"
ihar_microvm_write_guest_env "$env_file" codex /mnt/ihar/runtime/codex
guest_env="$(cat "$env_file")"
assert_contains "Claude home is always visible" "$guest_env" "CLAUDE_CONFIG_DIR='/mnt/ihar/runtime/claude'"
assert_contains "Codex home is always visible" "$guest_env" "CODEX_HOME='/mnt/ihar/runtime/codex'"
assert_contains "both binaries are on PATH" "$guest_env" "PATH='/mnt/ihar/bin:"
assert_contains "gateway uses host side address" "$guest_env" "http://172.31.0.1:43123"

# --- host-side deny-by-default policy -------------------------------------------------

FAKE_BIN="$IHAR_TEST_TMP/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/sudo" <<'SH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$IHAR_TEST_TMP/net.log"
printf '\n' >> "$IHAR_TEST_TMP/net.log"
SH
cat > "$FAKE_BIN/sysctl" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == -n ]]; then echo 0; else printf '%q ' "$@" >> "$IHAR_TEST_TMP/net.log"; printf '\n' >> "$IHAR_TEST_TMP/net.log"; fi
SH
chmod +x "$FAKE_BIN/sudo"
chmod +x "$FAKE_BIN/sysctl"
PATH="$FAKE_BIN:$PATH"
export PATH IHAR_TEST_TMP
IHAR_MICROVM_TAP=tap-ihar-1
IHAR_MICROVM_GUEST_IP=172.31.0.2
IHAR_MICROVM_HOST_IP=172.31.0.1
IHAR_MICROVM_CHAIN=IHAR_TEST
IHAR_MICROVM_MCP_EGRESS='203.0.113.8:443'
export IHAR_MICROVM_TAP IHAR_MICROVM_GUEST_IP IHAR_MICROVM_HOST_IP \
  IHAR_MICROVM_CHAIN IHAR_MICROVM_MCP_EGRESS

assert_exit "deny-by-default rules install" 0 ihar_microvm_network_apply
rules="$(cat "$IHAR_TEST_TMP/net.log")"
assert_contains "guest chain ends in DROP" "$rules" '-A IHAR_TEST -j DROP'
assert_contains "gateway is explicitly allowed" "$rules" '--dport 43123'
assert_contains "declared MCP destination is allowed" "$rules" '-d 203.0.113.8 -p tcp --dport 443 -j ACCEPT'
assert_eq "no broad outbound ACCEPT exists" "0" "$(grep -Ec -- '-i tap-ihar-1 .* -j ACCEPT$' <<<"$rules")"
assert_contains "MCP NAT is scoped to its destination" "$rules" '-d 203.0.113.8 -p tcp --dport 443'
assert_eq "no broad masquerade exists" "0" "$(grep -Ec -- '-s 172.31.0.2 -j MASQUERADE' <<<"$rules")"

: > "$IHAR_TEST_TMP/net.log"
assert_exit "network cleanup succeeds" 0 ihar_microvm_network_remove
cleanup_rules="$(cat "$IHAR_TEST_TMP/net.log")"
assert_contains "jump is removed" "$cleanup_rules" '-D FORWARD -i tap-ihar-1 -j IHAR_TEST'
assert_contains "private chain is deleted" "$cleanup_rules" '-X IHAR_TEST'
assert_contains "host-local traffic is dropped by a TAP input chain" "$rules" '-A IHAR_TEST_IN -j DROP'
assert_contains "return traffic is admitted only when established" "$rules" \
  '-I FORWARD 1 -o tap-ihar-1 -m conntrack'

saved_state_root="$IHAR_STATE_ROOT"
IHAR_STATE_ROOT="$IHAR_TEST_TMP/reservations"; export IHAR_STATE_ROOT
unset IHAR_MICROVM_SLOT IHAR_MICROVM_TAP IHAR_MICROVM_HOST_IP IHAR_MICROVM_GUEST_IP IHAR_MICROVM_CHAIN
IHAR_LAUNCH_ID=018f1234-5678-7abc-8def-0123456789ab; export IHAR_LAUNCH_ID
ihar_microvm_reserve_slot
assert_eq "the first reserved slot matches the pre-render gateway" "172.31.0.1" "$IHAR_MICROVM_HOST_IP"
assert_eq "the INPUT chain stays within iptables' 28-character limit" "28" "$(( ${#IHAR_MICROVM_CHAIN} + 3 ))"
ihar_microvm_release_slot
IHAR_STATE_ROOT="$saved_state_root"; export IHAR_STATE_ROOT

# --- launch wiring --------------------------------------------------------------------

assert_eq "isolated status no longer says unavailable" "0" \
  "$(grep -c 'unavailable until slice S13' "$ROOT/lib/cli/commands.sh")"
assert_contains "entry point loads the microVM module" "$(cat "$ROOT/ihar.sh")" \
  'source "$_IHAR_LIB/sandbox/microvm.sh"'
assert_contains "launcher delegates isolated execution" "$(cat "$ROOT/lib/cli/commands.sh")" \
  'ihar_microvm_launch "$vendor" "$runtime"'
IHAR_ARGV=(/host/bin/codex --version)
assert_eq "Codex guest boot command uses the bundled binary" \
  "exec /mnt/ihar/bin/codex --version" \
  "$(_ihar_microvm_quote_argv codex /host/runtime)"
assert_contains "the installer exposes microVM asset import" "$(cat "$ROOT/lib/cli/args.sh")" \
  '--microvm)'
assert_contains "guest setup is fail-closed" "$(cat "$ROOT/lib/sandbox/microvm.sh")" \
  'set -euo pipefail'
assert_eq "the root guest launcher does not require sudo" "0" \
  "$(grep -Ec "printf 'sudo |\\| sudo tee" "$ROOT/lib/sandbox/microvm.sh")"
assert_contains "cleanup runs while launch locals are still bound" \
  "$(cat "$ROOT/lib/sandbox/microvm.sh")" \
  '_ihar_microvm_cleanup; trap - EXIT INT TERM; return "$status"'
assert_contains "Firecracker serial output stays in the session log" \
  "$(cat "$ROOT/lib/sandbox/microvm.sh")" \
  '>> "$session/console.log" 2>&1 &'
assert_contains "guest uses pinned SSH host identity" "$(cat "$ROOT/lib/sandbox/microvm.sh")" \
  'StrictHostKeyChecking=yes'
assert_contains "Codex gateway is rendered at the guest host address" \
  "$(IHAR_PROFILE_SANDBOX=microvm IHAR_GATEWAY_MODE=explicit IHAR_GATEWAY_ACTIVE_PORT=43123 IHAR_PROJECT_ROOT="$ROOT" IHAR_STORE="$IHAR_STORE" bash -c 'source "$1/lib/core/logging.sh"; source "$1/lib/render/config.sh"; mkdir -p "$2"; _ihar_render_codex_config "$2"; cat "$2/.config-tables"' -- "$ROOT" "$session/render")" \
  'base_url = "http://172.31.0.1:43123/'

IHAR_IWIKI_REMOTE_HOST=127.0.0.1
IHAR_IWIKI_REMOTE_URL=https://127.0.0.1
IWIKI_REMOTE_TOKEN=test
export IHAR_IWIKI_REMOTE_HOST IHAR_IWIKI_REMOTE_URL IWIKI_REMOTE_TOKEN
egress="$(_ihar_microvm_collect_egress)"
assert_contains "declared MCP destinations resolve for the firewall" "$egress" \
  '127.0.0.1:443|127.0.0.1'

mkdir -p "$session/translate"
printf '%s\n' "$ROOT $IHAR_STATE $IHAR_STORE" > "$session/translate/paths"
chmod 444 "$session/translate/paths"
IHAR_PROJECT_ROOT="$ROOT" _ihar_microvm_translate_bundle_paths "$session/translate"
translated="$(cat "$session/translate/paths")"
assert_contains "project paths translate into the guest workspace" "$translated" '/workspace'
assert_contains "state paths translate into the writable state mount" "$translated" '/mnt/ihar-state'
assert_contains "store paths translate into the read-only policy mount" "$translated" '/mnt/ihar/store'

install_assets() {
  (
    local source="$IHAR_TEST_TMP/import-source"
    local original_store="$IHAR_STORE"
    export IHAR_STORE="$IHAR_TEST_TMP/import-store" IHAR_MICROVM_SOURCE_DIR="$source"
    mkdir -p "$source"
    cp "$original_store/bin/firecracker" "$source/firecracker"
    cp "$original_store/bin/vmlinux" "$source/vmlinux"
    cp "$original_store/bin/rootfs.ext4" "$source/rootfs.ext4"
    cp "$original_store/microvm/current/client_key" "$source/client_key"
    cp "$original_store/microvm/current/client_key.pub" "$source/client_key.pub"
    cp "$original_store/microvm/current/host_key.pub" "$source/host_key.pub"
    source "$ROOT/lib/store/lockfile.sh"
    source "$ROOT/lib/store/install.sh"
    ihar_install_microvm
    [[ -L "$IHAR_STORE/microvm/current" && -x "$IHAR_STORE/bin/firecracker" \
       && -f "$IHAR_STORE/microvm/current/host_key.pub" ]]
  )
}
assert_exit "pinned microVM assets activate as one version" 0 install_assets

finish
