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
source "$ROOT/lib/store/lockfile.sh"
source "$ROOT/lib/sandbox/microvm.sh"

mkdir -p "$IHAR_STORE/bin" "$IHAR_STATE_ROOT/project/r/hash/codex" \
  "$IHAR_STATE_ROOT/project/r/hash/claude" "$IHAR_STATE_ROOT/project/st"
cp "$(command -v bash)" "$IHAR_STORE/bin/firecracker"
: > "$IHAR_STORE/bin/vmlinux"
: > "$IHAR_STORE/bin/rootfs.ext4"
mkdir -p "$IHAR_STORE/microvm/current"
ssh-keygen -q -t ed25519 -N '' -f "$IHAR_STORE/microvm/current/client_key"
cp "$IHAR_STORE/microvm/current/client_key.pub" "$IHAR_STORE/microvm/current/host_key.pub"
python3 - "$IHAR_STORE/bin" "$IHAR_TEST_TMP/lockfile.json" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
digest = lambda name: hashlib.sha256((root / name).read_bytes()).hexdigest()
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "schema": 1,
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
rootfs_fixture_base="$(sha256sum "$rootfs_fixture" | cut -d' ' -f1)"
_ihar_microvm_prepare_rootfs "$rootfs_fixture" "$rootfs_fixture_base"
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
assert_contains "rootfs preparation records its pinned base digest" \
  "$(cat "${rootfs_fixture}.ihar-lineage.json")" "$rootfs_fixture_base"
assert_contains "rootfs preparation records its derived snapshot digest" \
  "$(cat "${rootfs_fixture}.ihar-lineage.json")" \
  "$(sha256sum "$rootfs_fixture" | cut -d' ' -f1)"

env_file="$session/guest-env.sh"
ihar_microvm_write_guest_env "$env_file" codex /mnt/ihar/runtime/codex
guest_env="$(cat "$env_file")"
assert_contains "Claude home is always visible" "$guest_env" "CLAUDE_CONFIG_DIR='/mnt/ihar/runtime/claude'"
assert_contains "Codex uses a writable home for atomic credential replacement" "$guest_env" \
  "CODEX_HOME='/mnt/ihar-state/.ihar-guest-codex-home'"
assert_contains "both binaries are on PATH" "$guest_env" "PATH='/mnt/ihar/bin:"
assert_contains "gateway uses host side address" "$guest_env" "http://172.31.0.1:43123"

# Credential writes must hit the separate writable state drive. Policy content
# remains immutable and contains neither a private credential copy nor a link to one.
guest_bundle="$session/guest-bundle"
guest_state="$session/guest-state"
guest_auth="$IHAR_STORE/auth/codex/auth.json"
mkdir -p "$guest_bundle/runtime/codex" "$guest_state" "$(dirname "$guest_auth")"
chmod 700 "$guest_bundle"
chmod 700 "$IHAR_STORE/auth" "$(dirname "$guest_auth")"
printf '%s' synthetic-guest-seed > "$guest_auth"
chmod 600 "$guest_auth"
ln -s "$guest_auth" "$guest_bundle/runtime/codex/auth.json"
printf '%s' managed-policy > "$guest_bundle/runtime/codex/config.toml"
_ihar_microvm_stage_guest_auth "$guest_bundle" "$guest_state" "$guest_auth"
assert_eq "Codex guest link targets writable state" "/mnt/ihar-state/.ihar-guest-codex-home/auth.json" \
  "$(readlink "$guest_bundle/runtime/codex/auth.json")"
assert_eq "writable Codex home keeps config on read-only policy" \
  "/mnt/ihar/runtime/codex/config.toml" \
  "$(readlink "$guest_state/.ihar-guest-codex-home/config.toml")"
assert_exit "writable Codex auth path is a real file" 1 \
  test -L "$guest_state/.ihar-guest-codex-home/auth.json"
assert_exit "policy image has no credential copy" 1 test -e "$guest_bundle/store/auth/codex/auth.json"
guest_policy_image="$session/guest-policy.ext4"
_ihar_microvm_make_image "$guest_policy_image" "$guest_bundle" 16
policy_before="$(sha256sum "$guest_policy_image" | cut -d' ' -f1)"
readonly_attempt="$(debugfs -R "write $guest_auth /runtime/codex/auth.json" "$guest_policy_image" 2>&1)"
assert_contains "read-only policy image refuses a credential write" \
  "$readonly_attempt" 'Filesystem opened read/only'
assert_eq "read-only policy bytes stay unchanged after write refusal" "$policy_before" \
  "$(sha256sum "$guest_policy_image" | cut -d' ' -f1)"
assert_eq "state seed holds private credential bytes" "synthetic-guest-seed" \
  "$(cat "$guest_state/.ihar-guest-codex-home/auth.json")"
assert_eq "state seed credential stays private" "600" \
  "$(stat -c %a "$guest_state/.ihar-guest-codex-home/auth.json")"
guest_state_image="$session/guest-state.ext4"
_ihar_microvm_make_image "$guest_state_image" "$guest_state" 16
assert_eq "writable guest drive contains credential" "synthetic-guest-seed" \
  "$(debugfs -R 'cat /.ihar-guest-codex-home/auth.json' "$guest_state_image" 2>/dev/null)"
assert_exit "prelaunch state image matches the private seed" 0 \
  _ihar_microvm_image_auth_matches "$guest_state_image" \
  "$guest_state/.ihar-guest-codex-home/auth.json" "$guest_bundle"
assert_exit "stopped state image yields a private candidate" 0 \
  _ihar_microvm_extract_guest_auth "$guest_state_image" "$guest_bundle"
assert_eq "extracted candidate preserves bytes" "synthetic-guest-seed" \
  "$(cat "$guest_bundle/auth.json")"
assert_eq "extracted candidate is owner-only" "600" \
  "$(stat -c %a "$guest_bundle/auth.json")"
debugfs -w -R 'rm /.ihar-guest-codex-home/auth.json' "$guest_state_image" >/dev/null 2>&1
assert_exit "missing image credential is not treated as logout" 1 \
  _ihar_microvm_extract_guest_auth "$guest_state_image" "$guest_bundle"
assert_eq "failed extraction retains earlier candidate" "synthetic-guest-seed" \
  "$(cat "$guest_bundle/auth.json")"
assert_exit "fake guest can substitute a symlink in its writable image" 0 \
  debugfs -w -R 'symlink /.ihar-guest-codex-home/auth.json /etc/passwd' "$guest_state_image"
assert_exit "symlinked image credential is rejected" 1 \
  _ihar_microvm_extract_guest_auth "$guest_state_image" "$guest_bundle"
printf '%s' synthetic-atomic-refresh > "$guest_state/.ihar-guest-codex-home/.auth-next"
chmod 600 "$guest_state/.ihar-guest-codex-home/.auth-next"
mv "$guest_state/.ihar-guest-codex-home/.auth-next" \
  "$guest_state/.ihar-guest-codex-home/auth.json"
assert_eq "writable Codex home permits atomic credential replacement" \
  "synthetic-atomic-refresh" "$(cat "$guest_state/.ihar-guest-codex-home/auth.json")"
mkdir -p "$session/persisted-state"
rsync -a --exclude='/.ihar-guest-codex-home/' "$guest_state/" "$session/persisted-state/"
assert_exit "live state transfer omits private credential view" 1 \
  test -e "$session/persisted-state/.ihar-guest-codex-home/auth.json"

early_store="$session/early-store"
early_runtime="$session/early-runtime"
mkdir -p "$early_store/auth/codex" "$early_runtime" "$session/early-state"
chmod 700 "$early_store/auth" "$early_store/auth/codex"
printf '%s' synthetic-early-owner > "$early_store/auth/codex/auth.json"
chmod 600 "$early_store/auth/codex/auth.json"
ln -s "$early_store/auth/codex/auth.json" "$early_runtime/auth.json"
early_status=0
(
  export IHAR_STORE="$early_store" IHAR_STATE_ROOT="$session/early-state-root"
  export IHAR_STATE="$session/early-state"
  source "$ROOT/lib/codex/auth.sh"
  ihar_microvm_preflight() { :; }
  ihar_gateway_release() { printf x >> "$IHAR_TEST_TMP/early-release-count"; }
  ihar_microvm_reserve_slot() {
    _ihar_microvm_early_cleanup
    ihar_die 3 'synthetic prelaunch failure'
  }
  ihar_microvm_launch codex "$early_runtime"
) > "$session/early-stdout" 2> "$session/early-stderr" || early_status=$?
assert_eq "synthetic prelaunch failure exits closed" "3" "$early_status"
assert_exit "early failure releases unregistered guest owner" 1 \
  test -e "$early_store/auth/codex/.owner.json"
assert_eq "early failure preserves canonical credential" "synthetic-early-owner" \
  "$(cat "$early_store/auth/codex/auth.json")"
assert_eq "early cleanup releases gateway only once" "x" \
  "$(cat "$IHAR_TEST_TMP/early-release-count")"

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

# Status may claim enforcement only while a live guest and its observed firewall
# boundary still match the required pinned assets. The record itself is not proof:
# mutations to the observed rules, process, or assets must remove verification.
IHAR_PROFILE_SANDBOX=microvm
IHAR_PROFILE_NETPOLICY=isolated
mkdir -p "$IHAR_STATE/.launch-guard"
: > "$IHAR_TEST_TMP/tap-active"
cat > "$IHAR_TEST_TMP/rules-active" <<'EOF'
-C IHAR_TEST -j DROP
-C FORWARD -i tap-ihar-1 -j IHAR_TEST
-C IHAR_TEST -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-C FORWARD -o tap-ihar-1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-C IHAR_TEST_IN -j DROP
-C INPUT -i tap-ihar-1 -j IHAR_TEST_IN
-C IHAR_TEST_IN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-C IHAR_TEST_IN -d 127.0.0.1 -p tcp --dport 43123 -j ACCEPT
-C IHAR_TEST -d 203.0.113.8 -p tcp --dport 443 -j ACCEPT
-C INPUT -i tap-ihar-1 -p tcp --dport 43123 -m comment --comment ihar:018f-test -j ACCEPT
-t nat -C PREROUTING -i tap-ihar-1 -d 172.31.0.1 -p tcp --dport 43123 -m comment --comment ihar:018f-test -j DNAT --to-destination 127.0.0.1:43123
-t nat -C POSTROUTING -s 172.31.0.2 -d 203.0.113.8 -p tcp --dport 443 -m comment --comment ihar:018f-test -j MASQUERADE
EOF
_ihar_microvm_link_active() { test -e "$IHAR_TEST_TMP/tap-active"; }
cat > "$IHAR_TEST_TMP/filter-IHAR_TEST" <<'EOF'
-N IHAR_TEST
-A IHAR_TEST -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A IHAR_TEST -d 203.0.113.8/32 -p tcp -m tcp --dport 443 -j ACCEPT
-A IHAR_TEST -j DROP
EOF
cat > "$IHAR_TEST_TMP/filter-IHAR_TEST_IN" <<'EOF'
-N IHAR_TEST_IN
-A IHAR_TEST_IN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A IHAR_TEST_IN -d 127.0.0.1/32 -p tcp -m tcp --dport 43123 -j ACCEPT
-A IHAR_TEST_IN -j DROP
EOF
cat > "$IHAR_TEST_TMP/filter-FORWARD" <<'EOF'
-P FORWARD ACCEPT
-A FORWARD -o tap-ihar-1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -i tap-ihar-1 -j IHAR_TEST
EOF
cat > "$IHAR_TEST_TMP/filter-INPUT" <<'EOF'
-P INPUT ACCEPT
-A INPUT -i tap-ihar-1 -j IHAR_TEST_IN
EOF
_ihar_microvm_iptables() {
  if [[ "$1" == -S ]]; then cat "$IHAR_TEST_TMP/filter-$2"; return; fi
  grep -qxF -- "$*" "$IHAR_TEST_TMP/rules-active"
}
evidence_dir="$session/evidence"
mkdir -p "$evidence_dir"
cp "$IHAR_STORE/bin/rootfs.ext4" "$evidence_dir/rootfs.ext4"
: > "$evidence_dir/policy.ext4"
: > "$evidence_dir/workspace.ext4"
: > "$evidence_dir/state.ext4"
evidence_config="$(ihar_microvm_write_config "$evidence_dir" tap-ihar-1 172.31.0.2 \
  "$evidence_dir/rootfs.ext4" "$evidence_dir/policy.ext4" \
  "$evidence_dir/workspace.ext4" "$evidence_dir/state.ext4")"
_ihar_microvm_rootfs_lineage_write "$evidence_dir/rootfs.ext4" \
  "$(ihar_lockfile_get microvm.rootfs)"
evidence_manifest="$(ihar_microvm_launch_manifest_write "$evidence_config")"
cp "$evidence_manifest" "$evidence_manifest.valid"
config_snapshot="${evidence_config}.prelaunch-config.json"
cp "$config_snapshot" "$config_snapshot.valid"
consumed_dir="$evidence_dir/consumed"
mkdir -p "$consumed_dir"
IHAR_CONSUMED_DIR="$consumed_dir" "$IHAR_STORE/bin/firecracker" -c '
config=""
while (( $# )); do
  [[ "$1" == --config-file ]] && { config="$2"; break; }
  shift
done
python3 - "$config" "$IHAR_CONSUMED_DIR" <<"PY"
import hashlib, json, pathlib, shutil, sys
config = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
data = json.loads(config.read_text())
shutil.copyfile(config, target / "config.json")
paths = {"kernel": data["boot-source"]["kernel_image_path"]}
paths.update({drive["drive_id"]: drive["path_on_host"] for drive in data["drives"]})
(target / "artifacts").write_text("".join(
    f"{name}={hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()}\n"
    for name, path in paths.items()
))
(target / "ready").touch()
PY
while :; do sleep 60; done
' -- \
  --config-file "$evidence_config" & evidence_vm_pid=$!
for _ in {1..100}; do
  [[ -e "$consumed_dir/ready" ]] && break
  sleep 0.01
done
assert_exit "fake Firecracker consumed the original config" 0 test -e "$consumed_dir/ready"
assert_exit "fake Firecracker consumed the snapshotted config bytes" 0 \
  cmp -s "$consumed_dir/config.json" "$config_snapshot"
assert_eq "fake Firecracker consumed all prelaunch artifact snapshots" "True" \
  "$(python3 - "$evidence_manifest" "$consumed_dir/artifacts" <<'PY'
import json, pathlib, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
captured = dict(line.split("=", 1) for line in pathlib.Path(sys.argv[2]).read_text().splitlines())
artifacts = manifest["artifacts"]
expected = {
    "kernel": artifacts["kernel"]["current_sha256"],
    "rootfs": artifacts["rootfs"]["launch_sha256"],
    "policy": artifacts["policy"]["launch_sha256"],
    "workspace": artifacts["workspace"]["launch_sha256"],
    "state": artifacts["state"]["launch_sha256"],
}
print(captured == expected)
PY
)"
ln "$evidence_config" "$evidence_config.original-inode"
cp "$evidence_config" "$evidence_config.swapped"
python3 - "$evidence_config.swapped" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["machine-config"]["mem_size_mib"] += 1
path.write_text(json.dumps(data))
PY
mv -f "$evidence_config.swapped" "$evidence_config"
assert_exit "an atomic config swap after consumption blocks evidence publication" 1 \
  ihar_microvm_network_evidence_write "$evidence_vm_pid" "$evidence_config" "$evidence_manifest"
rm -f "$evidence_config"
mv "$evidence_config.original-inode" "$evidence_config"
printf 'guest-rootfs-change' >> "$evidence_dir/rootfs.ext4"
printf 'guest-workspace-change' >> "$evidence_dir/workspace.ext4"
printf 'guest-state-change' >> "$evidence_dir/state.ext4"
assert_eq "mutable guest images differ from their consumed launch snapshots" "True" \
  "$(python3 - "$evidence_manifest" <<'PY'
import hashlib, json, pathlib, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
artifacts = manifest["artifacts"]
def digest(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
print(all(
    digest(artifacts[name]["path"]) != artifacts[name]["launch_sha256"]
    for name in ("rootfs", "workspace", "state")
))
PY
)"
publish_valid_evidence() {
  chmod 600 "$evidence_manifest" "$config_snapshot"
  cp "$evidence_manifest.valid" "$evidence_manifest"
  cp "$config_snapshot.valid" "$config_snapshot"
  chmod 400 "$evidence_manifest" "$config_snapshot"
  ihar_microvm_network_evidence_write "$evidence_vm_pid" "$evidence_config" "$evidence_manifest"
}
resign_evidence_record() {
  python3 - "$IHAR_STATE/.launch-guard/network-boundary" <<'PY'
import hashlib, pathlib, sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
values = dict(line.split("=", 1) for line in lines)
keys = (
    "owner_pid", "owner_start", "vm_pid", "vm_start", "tap", "chain",
    "guest_ip", "host_ip", "gateway_port", "launch_id", "egress",
    "manifest_path", "manifest_sha256", "config_path", "config_identity",
    "config_sha256", "config_canonical_sha256", "config_snapshot_path",
    "kernel_path", "kernel_identity", "kernel_current_sha256", "rootfs_path",
    "rootfs_identity", "rootfs_launch_sha256", "rootfs_base_sha256",
    "rootfs_lineage_sha256", "policy_path", "policy_identity",
    "policy_launch_sha256", "policy_current_sha256", "workspace_path",
    "workspace_identity", "workspace_launch_sha256", "state_path",
    "state_identity", "state_launch_sha256",
)
digest = hashlib.sha256(b"".join(values[key].encode() + b"\0" for key in keys) + b"deny\0").hexdigest()
lines[37] = f"launch_config_sha256={digest}"
path.write_text("\n".join(lines) + "\n")
PY
}
mutate_evidence_config() {
  chmod 600 "$config_snapshot" "$evidence_manifest"
  python3 - "$config_snapshot" "$@" <<'PY'
import json, pathlib, sys

path, mutation = pathlib.Path(sys.argv[1]), sys.argv[2]
data = json.loads(path.read_text())
if mutation == "machine-content":
    data["machine-config"]["mem_size_mib"] += 1
elif mutation == "rootfs-path":
    data["drives"][0]["path_on_host"] = sys.argv[3]
elif mutation == "policy-path":
    data["drives"][1]["path_on_host"] = sys.argv[3]
elif mutation == "rootfs-read-only":
    data["drives"][0]["is_read_only"] = True
elif mutation == "policy-writable":
    data["drives"][1]["is_read_only"] = False
elif mutation == "extra-drive":
    data["drives"].append({
        "drive_id": "secret", "path_on_host": sys.argv[3],
        "is_root_device": False, "is_read_only": False,
    })
elif mutation == "missing-drive":
    data["drives"] = [drive for drive in data["drives"] if drive["drive_id"] != "state"]
elif mutation == "wrong-drive-id":
    data["drives"][2]["drive_id"] = "work"
elif mutation == "kernel-path":
    data["boot-source"]["kernel_image_path"] = sys.argv[3]
elif mutation == "tap-missing":
    data["network-interfaces"] = []
elif mutation == "tap-wrong":
    data["network-interfaces"][0]["host_dev_name"] = "tap-ihar-2"
else:
    raise SystemExit(f"unknown mutation: {mutation}")
path.write_text(json.dumps(data))
PY
  local config_digest manifest_digest
  config_digest="$(sha256sum "$config_snapshot" | cut -d' ' -f1)"
  python3 - "$evidence_manifest" "$config_digest" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["config"]["sha256"] = sys.argv[2]
path.write_text(json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n")
PY
  chmod 400 "$config_snapshot" "$evidence_manifest"
  manifest_digest="$(sha256sum "$evidence_manifest" | cut -d' ' -f1)"
  sed -i "s/^config_sha256=.*/config_sha256=$config_digest/" \
    "$IHAR_STATE/.launch-guard/network-boundary"
  sed -i "s/^manifest_sha256=.*/manifest_sha256=$manifest_digest/" \
    "$IHAR_STATE/.launch-guard/network-boundary"
  resign_evidence_record
}
assert_not_verified() {
  local name="$1" current
  current="$(ihar_microvm_network_evidence)"
  assert_eq "$name" "True" \
    "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["configured"] and not d["verified"])' <<<"$current")"
}
ihar_microvm_network_evidence_write "$evidence_vm_pid" "$evidence_config" "$evidence_manifest"
evidence="$(ihar_microvm_network_evidence)"
assert_eq "live guest evidence verifies the configured boundary" "True" \
  "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d == {"configured":True,"available":True,"active":True,"verified":True})' <<<"$evidence")"
recorded_evidence="$(cat "$IHAR_STATE/.launch-guard/network-boundary")"
assert_contains "launch evidence records a canonical config digest" "$recorded_evidence" \
  'config_canonical_sha256='
assert_contains "launch evidence records the configured rootfs digest" "$recorded_evidence" \
  'rootfs_launch_sha256='
assert_contains "launch evidence records the pinned rootfs base digest" "$recorded_evidence" \
  "rootfs_base_sha256=$(ihar_lockfile_get microvm.rootfs)"
sed -i 's/^config_sha256=.*/config_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$IHAR_STATE/.launch-guard/network-boundary"
resign_evidence_record
assert_not_verified "a mismatched recorded config digest invalidates evidence"
publish_valid_evidence
for mutation in machine-content rootfs-read-only policy-writable tap-missing tap-wrong \
    missing-drive wrong-drive-id; do
  mutate_evidence_config "$mutation"
  assert_not_verified "$mutation config evidence is rejected"
  publish_valid_evidence
done
: > "$evidence_dir/other.ext4"
for mutation in rootfs-path policy-path extra-drive kernel-path; do
  mutate_evidence_config "$mutation" "$evidence_dir/other.ext4"
  assert_not_verified "$mutation config evidence is rejected"
  publish_valid_evidence
done
sed -i 's/^kernel_current_sha256=.*/kernel_current_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$IHAR_STATE/.launch-guard/network-boundary"
resign_evidence_record
assert_not_verified "a mismatched configured kernel digest is rejected"
publish_valid_evidence
sed -i 's/^rootfs_base_sha256=.*/rootfs_base_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$IHAR_STATE/.launch-guard/network-boundary"
resign_evidence_record
assert_not_verified "a mismatched pinned rootfs digest is rejected"
publish_valid_evidence
sed -i 's/^rootfs_launch_sha256=.*/rootfs_launch_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$IHAR_STATE/.launch-guard/network-boundary"
resign_evidence_record
assert_not_verified "a rootfs digest detached from the launched process is rejected"
publish_valid_evidence
for artifact in workspace state; do
  sed -i "s/^${artifact}_launch_sha256=.*/${artifact}_launch_sha256=0000000000000000000000000000000000000000000000000000000000000000/" \
    "$IHAR_STATE/.launch-guard/network-boundary"
  resign_evidence_record
  assert_not_verified "$artifact prelaunch provenance mismatch is rejected"
  publish_valid_evidence
done
ln "$evidence_dir/policy.ext4" "$evidence_dir/policy.ext4.original-inode"
cp "$evidence_dir/policy.ext4" "$evidence_dir/policy.ext4.mutated"
printf 'mutation' >> "$evidence_dir/policy.ext4.mutated"
mv -f "$evidence_dir/policy.ext4.mutated" "$evidence_dir/policy.ext4"
assert_not_verified "a changed read-only policy image is rejected"
rm -f "$evidence_dir/policy.ext4"
mv "$evidence_dir/policy.ext4.original-inode" "$evidence_dir/policy.ext4"
publish_valid_evidence
sed -i 's/^vm_start=.*/vm_start=1/' "$IHAR_STATE/.launch-guard/network-boundary"
resign_evidence_record
evidence="$(ihar_microvm_network_evidence)"
assert_eq "reused PID without the recorded process identity is inactive" "True" \
  "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["configured"] and d["available"] and not d["active"] and not d["verified"])' <<<"$evidence")"
ihar_microvm_network_evidence_write "$evidence_vm_pid" "$evidence_config" "$evidence_manifest"
sed -i '2i-A IHAR_TEST -j ACCEPT' "$IHAR_TEST_TMP/filter-IHAR_TEST"
evidence="$(ihar_microvm_network_evidence)"
assert_eq "an early broad ACCEPT invalidates the observed boundary" "True" \
  "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["active"] and not d["verified"])' <<<"$evidence")"
sed -i '/^-A IHAR_TEST -j ACCEPT$/d' "$IHAR_TEST_TMP/filter-IHAR_TEST"
for mutation in prerouting-missing prerouting-wrong postrouting-missing postrouting-wrong; do
  cp "$IHAR_TEST_TMP/rules-active" "$IHAR_TEST_TMP/rules-active.valid"
  case "$mutation" in
    prerouting-missing) sed -i '/nat -C PREROUTING/d' "$IHAR_TEST_TMP/rules-active" ;;
    prerouting-wrong) sed -i '/nat -C PREROUTING/s/127\.0\.0\.1:43123/127.0.0.1:43124/' "$IHAR_TEST_TMP/rules-active" ;;
    postrouting-missing) sed -i '/nat -C POSTROUTING/d' "$IHAR_TEST_TMP/rules-active" ;;
    postrouting-wrong) sed -i '/nat -C POSTROUTING/s/203\.0\.113\.8/203.0.113.9/' "$IHAR_TEST_TMP/rules-active" ;;
  esac
  assert_not_verified "$mutation firewall evidence is rejected"
  mv "$IHAR_TEST_TMP/rules-active.valid" "$IHAR_TEST_TMP/rules-active"
done
mv "$IHAR_STORE/bin/rootfs.ext4" "$IHAR_STORE/bin/rootfs.ext4.missing"
evidence="$(ihar_microvm_network_evidence)"
assert_eq "missing required asset prevents enforcement" "True" \
  "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["configured"] and not d["available"] and d["active"] and not d["verified"])' <<<"$evidence")"
mv "$IHAR_STORE/bin/rootfs.ext4.missing" "$IHAR_STORE/bin/rootfs.ext4"
sed -i '/^-C IHAR_TEST -j DROP$/d' "$IHAR_TEST_TMP/rules-active"
evidence="$(ihar_microvm_network_evidence)"
assert_eq "missing observed firewall rule prevents verification" "True" \
  "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["configured"] and d["available"] and d["active"] and not d["verified"])' <<<"$evidence")"
kill "$evidence_vm_pid"
wait "$evidence_vm_pid" 2>/dev/null || true
evidence="$(ihar_microvm_network_evidence)"
assert_eq "dead guest makes the recorded boundary inactive" "True" \
  "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["configured"] and d["available"] and not d["active"] and not d["verified"])' <<<"$evidence")"
ihar_microvm_network_evidence_remove
assert_exit "network evidence cleanup removes only the live record" 1 \
  test -e "$IHAR_STATE/.launch-guard/network-boundary"
evidence="$(ihar_microvm_network_evidence)"
assert_eq "installed assets without a live boundary remain unverified" "True" \
  "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["configured"] and d["available"] and not d["active"] and not d["verified"])' <<<"$evidence")"

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
