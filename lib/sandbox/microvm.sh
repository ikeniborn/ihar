#!/usr/bin/env bash
# Firecracker outer sandbox for the isolated profile (LLD 9).
#
# The boot assets are installed as ordinary user files. Runtime network setup is the
# one privileged boundary: a per-launch TAP and iptables chain enforce default-deny.
# No rule is added unless passwordless sudo is available, and a partial setup is
# removed before the launch fails closed.

ihar_microvm_preflight() {
  local kvm="${IHAR_MICROVM_KVM:-/dev/kvm}"
  [[ -r "$kvm" && -w "$kvm" ]] \
    || ihar_die 3 "profile 'isolated' requires readable and writable KVM at $kvm"

  local asset
  for asset in firecracker vmlinux rootfs.ext4; do
    [[ -f "$IHAR_STORE/bin/$asset" ]] \
      || ihar_die 3 "profile 'isolated' requires $IHAR_STORE/bin/$asset
run 'ihar install --microvm'"
  done
  [[ -x "$IHAR_STORE/bin/firecracker" ]] \
    || ihar_die 3 "$IHAR_STORE/bin/firecracker is not executable"
  command -v mkfs.ext4 >/dev/null 2>&1 \
    || ihar_die 3 "profile 'isolated' requires mkfs.ext4"
  command -v debugfs >/dev/null 2>&1 \
    || ihar_die 3 "profile 'isolated' requires debugfs"
  command -v ssh >/dev/null 2>&1 \
    || ihar_die 3 "profile 'isolated' requires ssh"
  command -v setsid >/dev/null 2>&1 \
    || ihar_die 3 "profile 'isolated' requires setsid for guest quiescence"
  command -v rsync >/dev/null 2>&1 \
    || ihar_die 3 "profile 'isolated' requires rsync for workspace persistence"
  local key="${IHAR_MICROVM_SSH_KEY:-$IHAR_STORE/microvm/current/client_key}"
  [[ -f "$key" ]] || ihar_die 3 "microVM SSH key is absent at $key"
  [[ -f "$IHAR_STORE/microvm/current/host_key.pub" ]] \
    || ihar_die 3 "microVM pinned SSH host key is absent at $IHAR_STORE/microvm/current/host_key.pub"
  ssh-keygen -l -f "$IHAR_STORE/microvm/current/host_key.pub" >/dev/null 2>&1 \
    || ihar_die 3 "microVM SSH host key is invalid"
  local name pinned actual
  for name in firecracker vmlinux rootfs.ext4; do
    case "$name" in firecracker) key=firecracker;; vmlinux) key=kernel;; *) key=rootfs;; esac
    pinned="$(ihar_lockfile_get "microvm.$key")"
    [[ -n "$pinned" ]] || ihar_die 3 "the lockfile does not pin microvm.$key"
    actual="$(sha256sum "$IHAR_STORE/bin/$name" | cut -d' ' -f1)"
    [[ "$actual" == "$pinned" ]] || ihar_die 3 "$name differs from the microVM lockfile pin"
  done
  sudo -n true >/dev/null 2>&1 \
    || ihar_die 3 "profile 'isolated' requires passwordless sudo for its TAP and network policy"
}

_ihar_microvm_json_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

# ihar_microvm_write_config <dir> <tap> <guest-ip> <rootfs> <policy> <workspace> <state>
ihar_microvm_write_config() {
  local dir="$1" tap="$2" guest_ip="$3" rootfs="$4" policy="$5" workspace="$6" state="$7"
  local file="$dir/vmconfig.json" kernel="$IHAR_STORE/bin/vmlinux"
  [[ "$tap" =~ ^[A-Za-z0-9_-]{1,15}$ ]] || ihar_die 3 "invalid microVM TAP name: $tap"
  [[ "$guest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || ihar_die 3 "invalid microVM guest address: $guest_ip"
  local kernel_j rootfs_j policy_j workspace_j state_j tap_j boot_j mac_octet
  kernel_j="$(_ihar_microvm_json_string "$kernel")"
  rootfs_j="$(_ihar_microvm_json_string "$rootfs")"
  policy_j="$(_ihar_microvm_json_string "$policy")"
  workspace_j="$(_ihar_microvm_json_string "$workspace")"
  state_j="$(_ihar_microvm_json_string "$state")"
  tap_j="$(_ihar_microvm_json_string "$tap")"
  mac_octet="${tap##*-}"; [[ "$mac_octet" =~ ^[0-9]+$ ]] || mac_octet=1
  printf -v mac_octet '%02X' "$mac_octet"
  boot_j="$(_ihar_microvm_json_string "console=ttyS0 reboot=k panic=1 pci=off nomodules ip=$guest_ip::${IHAR_MICROVM_HOST_IP:-172.31.0.1}:255.255.255.252::eth0:off")"
  cat > "$file" <<JSON
{
  "boot-source": {"kernel_image_path": $kernel_j, "boot_args": $boot_j},
  "drives": [
    {"drive_id": "rootfs", "path_on_host": $rootfs_j, "is_root_device": true, "is_read_only": false},
    {"drive_id": "policy", "path_on_host": $policy_j, "is_root_device": false, "is_read_only": true},
    {"drive_id": "workspace", "path_on_host": $workspace_j, "is_root_device": false, "is_read_only": false},
    {"drive_id": "state", "path_on_host": $state_j, "is_root_device": false, "is_read_only": false}
  ],
  "machine-config": {"vcpu_count": ${IHAR_MICROVM_VCPU:-2}, "mem_size_mib": ${IHAR_MICROVM_MEM_MB:-2048}},
  "network-interfaces": [{"iface_id": "eth0", "guest_mac": "AA:FC:00:00:00:$mac_octet", "host_dev_name": $tap_j}]
}
JSON
  printf '%s\n' "$file"
}

# Both homes are exported because hooks and handoff may cross the vendor boundary.
ihar_microvm_write_guest_env() {
  local file="$1" vendor="$2" runtime="$3"
  local gateway="http://${IHAR_MICROVM_HOST_IP:-172.31.0.1}:${IHAR_GATEWAY_ACTIVE_PORT:?gateway port is absent}"
  cat > "$file" <<EOF
export IHAR_VENDOR='$vendor'
export CLAUDE_CONFIG_DIR='/mnt/ihar/runtime/claude'
export CODEX_HOME='/mnt/ihar-state/.ihar-guest-codex-home'
export PATH='/mnt/ihar/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export ANTHROPIC_BASE_URL='$gateway'
export IHAR_GATEWAY_URL='$gateway'
export IHAR_RUNTIME='$runtime'
EOF
  local assignment name value
  for assignment in "${IHAR_ENV[@]:-}"; do
    name="${assignment%%=*}"; value="${assignment#*=}"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    case "$name" in
      PATH|CLAUDE_CONFIG_DIR|CODEX_HOME|ANTHROPIC_BASE_URL|IHAR_GATEWAY_URL|IHAR_RUNTIME) continue ;;
      HOME) value=/workspace ;;
      IHAR_PROJECT_ROOT) value=/workspace ;;
      IHAR_STATE|IHAR_STATE_ROOT) value=/mnt/ihar-state ;;
      CODEX_PATH) value=/mnt/ihar/bin/codex ;;
      CLAUDE_CODE_EXECUTABLE) value=/mnt/ihar/bin/claude ;;
    esac
    printf 'export %s=%q\n' "$name" "$value" >> "$file"
  done
  chmod 600 "$file"
}

_ihar_microvm_iptables() { sudo -n iptables "$@"; }

_ihar_microvm_network_evidence_path() {
  local state="${IHAR_STATE:-}"
  if [[ -z "$state" ]] && declare -F _ihar_project_state >/dev/null; then
    state="$(_ihar_project_state)"
  fi
  [[ -n "$state" ]] || return 1
  printf '%s/.launch-guard/network-boundary\n' "$state"
}

_ihar_microvm_assets_available() {
  local kvm="${IHAR_MICROVM_KVM:-/dev/kvm}" name key pinned actual
  [[ -r "$kvm" && -w "$kvm" ]] || return 1
  for name in firecracker vmlinux rootfs.ext4; do
    [[ -f "$IHAR_STORE/bin/$name" ]] || return 1
  done
  [[ -x "$IHAR_STORE/bin/firecracker" ]] || return 1
  for name in mkfs.ext4 debugfs ssh rsync ssh-keygen sha256sum setsid; do
    command -v "$name" >/dev/null 2>&1 || return 1
  done
  local client_key="${IHAR_MICROVM_SSH_KEY:-$IHAR_STORE/microvm/current/client_key}"
  [[ -f "$client_key" && -f "$IHAR_STORE/microvm/current/host_key.pub" ]] || return 1
  ssh-keygen -l -f "$IHAR_STORE/microvm/current/host_key.pub" >/dev/null 2>&1 || return 1
  declare -F ihar_lockfile_get >/dev/null || return 1
  for name in firecracker vmlinux rootfs.ext4; do
    case "$name" in firecracker) key=firecracker;; vmlinux) key=kernel;; *) key=rootfs;; esac
    pinned="$(ihar_lockfile_get "microvm.$key" 2>/dev/null)" || return 1
    [[ -n "$pinned" ]] || return 1
    actual="$(sha256sum "$IHAR_STORE/bin/$name" | cut -d' ' -f1)" || return 1
    [[ "$actual" == "$pinned" ]] || return 1
  done
  sudo -n true >/dev/null 2>&1
}

# Published only after the guest answers through the pinned SSH identity. The file
# is a locator for observations, never proof by itself; readers recheck the PIDs,
# TAP, firewall rules and pinned assets.
_ihar_microvm_process_start_time() {
  local stat rest
  stat="$(< "/proc/$1/stat")" 2>/dev/null || return 1
  rest="${stat##*) }"
  awk '{print $20}' <<< "$rest"
}

_ihar_microvm_launch_config_digest() {
  printf '%s\0' "$@" | sha256sum | cut -d' ' -f1
}

_ihar_microvm_file_identity() {
  stat -Lc '%d:%i:%s:%Y' -- "$1"
}

_ihar_microvm_rootfs_lineage_write() { # <prepared-rootfs> <base-sha256>
  local rootfs="$1" base_sha256="$2" file temp identity prepared_sha256
  [[ -f "$rootfs" && ! -L "$rootfs" && "$base_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  identity="$(_ihar_microvm_file_identity "$rootfs")" || return 1
  prepared_sha256="$(sha256sum "$rootfs" | cut -d' ' -f1)" || return 1
  file="${rootfs}.ihar-lineage.json"
  temp="$(mktemp "${file}.XXXXXX")" || return 1
  python3 - "$temp" "$rootfs" "$identity" "$base_sha256" "$prepared_sha256" <<'PY'
import json, sys

path, rootfs, identity, base, prepared = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump({
        "schema": 1,
        "base_sha256": base,
        "prepared": {"path": rootfs, "identity": identity, "sha256": prepared},
    }, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
  chmod 400 "$temp" || { rm -f -- "$temp"; return 1; }
  mv -f -- "$temp" "$file" || { rm -f -- "$temp"; return 1; }
}

_ihar_microvm_launch_manifest_facts() { # <manifest>
  python3 - "$1" <<'PY'
import json, re, sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        data = json.load(stream)
except (OSError, TypeError, ValueError):
    raise SystemExit(1)

asset_keys = {
    "kernel": {"path", "identity", "current_sha256"},
    "rootfs": {"path", "identity", "launch_sha256", "base_sha256", "lineage_sha256"},
    "policy": {"path", "identity", "launch_sha256", "current_sha256"},
    "workspace": {"path", "identity", "launch_sha256"},
    "state": {"path", "identity", "launch_sha256"},
}
valid = (
    isinstance(data, dict)
    and set(data) == {"schema", "config", "artifacts", "network"}
    and data.get("schema") == 1
    and isinstance(data.get("config"), dict)
    and set(data["config"]) == {
        "path", "identity", "sha256", "canonical_sha256", "snapshot_path"
    }
    and isinstance(data.get("artifacts"), dict)
    and set(data["artifacts"]) == set(asset_keys)
    and all(
        isinstance(data["artifacts"].get(name), dict)
        and set(data["artifacts"][name]) == keys
        for name, keys in asset_keys.items()
    )
    and isinstance(data.get("network"), dict)
    and set(data["network"]) == {"tap", "guest_ip", "host_ip"}
)
if not valid:
    raise SystemExit(1)
sha = re.compile(r"^[0-9a-f]{64}$")
identity = re.compile(r"^[0-9]+:[0-9]+:[0-9]+:[0-9]+$")
config = data["config"]
values = [config["path"], config["snapshot_path"]]
if not all(isinstance(value, str) and value and not any(c in value for c in "\r\n\t") for value in values):
    raise SystemExit(1)
if not identity.fullmatch(config["identity"]) or not sha.fullmatch(config["sha256"]) or not sha.fullmatch(config["canonical_sha256"]):
    raise SystemExit(1)
for name, artifact in data["artifacts"].items():
    if not isinstance(artifact["path"], str) or not artifact["path"] or any(c in artifact["path"] for c in "\r\n\t"):
        raise SystemExit(1)
    if not identity.fullmatch(artifact["identity"]):
        raise SystemExit(1)
    for key, value in artifact.items():
        if key.endswith("sha256") and not sha.fullmatch(value):
            raise SystemExit(1)
network = data["network"]
print(config["path"])
print(config["identity"])
print(config["sha256"])
print(config["canonical_sha256"])
print(config["snapshot_path"])
for name in ("kernel", "rootfs", "policy", "workspace", "state"):
    artifact = data["artifacts"][name]
    print(artifact["path"])
    print(artifact["identity"])
    if name == "kernel":
        print(artifact["current_sha256"])
    elif name == "rootfs":
        print(artifact["launch_sha256"])
        print(artifact["base_sha256"])
        print(artifact["lineage_sha256"])
    elif name == "policy":
        print(artifact["launch_sha256"])
        print(artifact["current_sha256"])
    else:
        print(artifact["launch_sha256"])
print(network["tap"])
print(network["guest_ip"])
print(network["host_ip"])
PY
}

ihar_microvm_launch_manifest_write() { # <vm-config>
  local config="$1" manifest="${1}.prelaunch-manifest.json"
  local snapshot="${1}.prelaunch-config.json" temp_snapshot temp_manifest
  local before_identity after_identity config_sha256 canonical_sha256
  local kernel rootfs policy workspace state pinned actual lineage lineage_sha256
  local -a facts=()
  [[ -f "$config" && ! -L "$config" && "$config" == /* ]] || return 1
  before_identity="$(_ihar_microvm_file_identity "$config")" || return 1
  temp_snapshot="$(mktemp "${snapshot}.XXXXXX")" || return 1
  cp -- "$config" "$temp_snapshot" || { rm -f -- "$temp_snapshot"; return 1; }
  cmp -s -- "$config" "$temp_snapshot" || { rm -f -- "$temp_snapshot"; return 1; }
  after_identity="$(_ihar_microvm_file_identity "$config")" || { rm -f -- "$temp_snapshot"; return 1; }
  [[ "$before_identity" == "$after_identity" ]] || { rm -f -- "$temp_snapshot"; return 1; }
  chmod 400 "$temp_snapshot" || { rm -f -- "$temp_snapshot"; return 1; }
  mv -f -- "$temp_snapshot" "$snapshot" || { rm -f -- "$temp_snapshot"; return 1; }
  config_sha256="$(sha256sum "$snapshot" | cut -d' ' -f1)" || return 1
  mapfile -t facts < <(_ihar_microvm_config_facts "$config" "$IHAR_MICROVM_TAP" \
    "$IHAR_MICROVM_GUEST_IP" "$IHAR_MICROVM_HOST_IP")
  (( ${#facts[@]} == 6 )) || return 1
  canonical_sha256="${facts[0]}"; kernel="${facts[1]}"; rootfs="${facts[2]}"
  policy="${facts[3]}"
  workspace="${facts[4]}"; state="${facts[5]}"
  for actual in "$kernel" "$rootfs" "$policy" "$workspace" "$state"; do
    [[ -f "$actual" && ! -L "$actual" ]] || return 1
  done
  pinned="$(ihar_lockfile_get microvm.kernel 2>/dev/null)" || return 1
  [[ "$(sha256sum "$kernel" | cut -d' ' -f1)" == "$pinned" ]] || return 1
  pinned="$(ihar_lockfile_get microvm.rootfs 2>/dev/null)" || return 1
  lineage="${rootfs}.ihar-lineage.json"
  [[ -f "$lineage" && ! -L "$lineage" ]] || return 1
  lineage_sha256="$(sha256sum "$lineage" | cut -d' ' -f1)" || return 1
  python3 - "$lineage" "$rootfs" "$(_ihar_microvm_file_identity "$rootfs")" \
    "$pinned" "$(sha256sum "$rootfs" | cut -d' ' -f1)" >/dev/null <<'PY' || return 1
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
expected = {
    "schema": 1,
    "base_sha256": sys.argv[4],
    "prepared": {"path": sys.argv[2], "identity": sys.argv[3], "sha256": sys.argv[5]},
}
raise SystemExit(0 if data == expected else 1)
PY
  temp_manifest="$(mktemp "${manifest}.XXXXXX")" || return 1
  python3 - "$temp_manifest" "$config" "$before_identity" "$config_sha256" \
    "$canonical_sha256" "$snapshot" "$kernel" "$rootfs" "$pinned" \
    "$lineage_sha256" "$policy" "$workspace" "$state" "$IHAR_MICROVM_TAP" \
    "$IHAR_MICROVM_GUEST_IP" "$IHAR_MICROVM_HOST_IP" <<'PY'
import hashlib, json, os, sys

(out, config, config_identity, config_sha, canonical_sha, snapshot, kernel,
 rootfs, rootfs_base, lineage_sha, policy, workspace, state, tap, guest, host) = sys.argv[1:]
def identity(path):
    value = os.stat(path)
    return f"{value.st_dev}:{value.st_ino}:{value.st_size}:{int(value.st_mtime)}"
def digest(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()
data = {
    "schema": 1,
    "config": {"path": config, "identity": config_identity, "sha256": config_sha,
               "canonical_sha256": canonical_sha, "snapshot_path": snapshot},
    "artifacts": {
        "kernel": {"path": kernel, "identity": identity(kernel), "current_sha256": digest(kernel)},
        "rootfs": {"path": rootfs, "identity": identity(rootfs), "launch_sha256": digest(rootfs),
                   "base_sha256": rootfs_base, "lineage_sha256": lineage_sha},
        "policy": {"path": policy, "identity": identity(policy), "launch_sha256": digest(policy),
                   "current_sha256": digest(policy)},
        "workspace": {"path": workspace, "identity": identity(workspace), "launch_sha256": digest(workspace)},
        "state": {"path": state, "identity": identity(state), "launch_sha256": digest(state)},
    },
    "network": {"tap": tap, "guest_ip": guest, "host_ip": host},
}
with open(out, "w", encoding="utf-8") as stream:
    json.dump(data, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
  chmod 400 "$temp_manifest" || { rm -f -- "$temp_manifest"; return 1; }
  mv -f -- "$temp_manifest" "$manifest" || { rm -f -- "$temp_manifest"; return 1; }
  (( $( _ihar_microvm_launch_manifest_facts "$manifest" | wc -l ) == 26 )) || return 1
  printf '%s\n' "$manifest"
}

ihar_microvm_network_evidence_write() { # <firecracker-pid> <vm-config> <prelaunch-manifest>
  local vm_pid="$1" config="$2" manifest="${3:-}" record temp launch_id="${IHAR_LAUNCH_ID:-$$}"
  local destination egress="" owner_start vm_start config_sha256 actual pinned
  local config_canonical_sha256 kernel rootfs policy workspace state
  local kernel_sha256 rootfs_sha256 rootfs_base_sha256 policy_sha256 policy_current_sha256
  local launch_config_sha256 manifest_sha256 config_identity config_snapshot
  local kernel_identity rootfs_identity rootfs_lineage_sha256 policy_identity
  local workspace_identity workspace_sha256 state_identity state_sha256
  local -a manifest_facts=()
  record="$(_ihar_microvm_network_evidence_path)" || return 1
  [[ "$vm_pid" =~ ^[1-9][0-9]*$ && "${IHAR_MICROVM_TAP:-}" =~ ^[A-Za-z0-9_-]{1,15}$ \
    && "${IHAR_MICROVM_CHAIN:-}" =~ ^[A-Za-z0-9_]{1,25}$ \
    && "${IHAR_MICROVM_GUEST_IP:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ \
    && "${IHAR_MICROVM_HOST_IP:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ \
    && "${IHAR_GATEWAY_ACTIVE_PORT:-}" =~ ^[1-9][0-9]*$ \
    && "$launch_id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ -f "$config" && ! -L "$config" && -f "$manifest" && ! -L "$manifest" \
    && "$config" != *$'\n'* && "$config" != *$'\t'* ]] \
    || return 1
  mapfile -t manifest_facts < <(_ihar_microvm_launch_manifest_facts "$manifest")
  (( ${#manifest_facts[@]} == 26 )) || return 1
  [[ "${manifest_facts[0]}" == "$config" \
    && "${manifest_facts[23]}" == "$IHAR_MICROVM_TAP" \
    && "${manifest_facts[24]}" == "$IHAR_MICROVM_GUEST_IP" \
    && "${manifest_facts[25]}" == "$IHAR_MICROVM_HOST_IP" ]] || return 1
  config_identity="${manifest_facts[1]}"; config_sha256="${manifest_facts[2]}"
  config_canonical_sha256="${manifest_facts[3]}"; config_snapshot="${manifest_facts[4]}"
  kernel="${manifest_facts[5]}"; kernel_identity="${manifest_facts[6]}"
  kernel_sha256="${manifest_facts[7]}"; rootfs="${manifest_facts[8]}"
  rootfs_identity="${manifest_facts[9]}"; rootfs_sha256="${manifest_facts[10]}"
  rootfs_base_sha256="${manifest_facts[11]}"; rootfs_lineage_sha256="${manifest_facts[12]}"
  policy="${manifest_facts[13]}"; policy_identity="${manifest_facts[14]}"
  policy_sha256="${manifest_facts[15]}"; policy_current_sha256="${manifest_facts[16]}"
  workspace="${manifest_facts[17]}"
  workspace_identity="${manifest_facts[18]}"; workspace_sha256="${manifest_facts[19]}"
  state="${manifest_facts[20]}"; state_identity="${manifest_facts[21]}"
  state_sha256="${manifest_facts[22]}"
  [[ "$(_ihar_microvm_file_identity "$config")" == "$config_identity" \
    && "$(sha256sum "$config" | cut -d' ' -f1)" == "$config_sha256" \
    && -f "$config_snapshot" && ! -L "$config_snapshot" \
    && "$(sha256sum "$config_snapshot" | cut -d' ' -f1)" == "$config_sha256" ]] \
    || return 1
  cmp -s -- "$config" "$config_snapshot" || return 1
  [[ "$(_ihar_microvm_file_identity "$kernel")" == "$kernel_identity" \
    && "$(sha256sum "$kernel" | cut -d' ' -f1)" == "$kernel_sha256" \
    && "$(_ihar_microvm_file_identity "$policy")" == "$policy_identity" \
    && "$(sha256sum "$policy" | cut -d' ' -f1)" == "$policy_current_sha256" ]] \
    || return 1
  manifest_sha256="$(sha256sum "$manifest" | cut -d' ' -f1)" || return 1
  owner_start="$(_ihar_microvm_process_start_time "$$")" || return 1
  vm_start="$(_ihar_microvm_process_start_time "$vm_pid")" || return 1
  [[ "$owner_start" =~ ^[0-9]+$ && "$vm_start" =~ ^[0-9]+$ ]] || return 1
  _ihar_microvm_process_is_firecracker "$vm_pid" || return 1
  _ihar_microvm_process_uses_config "$vm_pid" "$config" || return 1
  pinned="$(ihar_lockfile_get microvm.kernel 2>/dev/null)" || return 1
  [[ -n "$pinned" && "$kernel_sha256" == "$pinned" ]] || return 1
  pinned="$(ihar_lockfile_get microvm.rootfs 2>/dev/null)" || return 1
  [[ -n "$rootfs_base_sha256" && "$rootfs_base_sha256" == "$pinned" ]] || return 1
  actual="$(sha256sum "$IHAR_STORE/bin/rootfs.ext4" | cut -d' ' -f1)" || return 1
  [[ "$actual" == "$rootfs_base_sha256" ]] || return 1
  for destination in ${IHAR_MICROVM_MCP_EGRESS:-}; do
    [[ "$destination" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[1-9][0-9]*$ ]] || return 1
    (( ${destination##*:} <= 65535 )) || return 1
    egress+="${egress:+,}$destination"
  done
  launch_config_sha256="$(_ihar_microvm_launch_config_digest \
    "$$" "$owner_start" "$vm_pid" "$vm_start" "$IHAR_MICROVM_TAP" \
    "$IHAR_MICROVM_CHAIN" "$IHAR_MICROVM_GUEST_IP" "$IHAR_MICROVM_HOST_IP" \
    "$IHAR_GATEWAY_ACTIVE_PORT" "$launch_id" "$egress" "$manifest" "$manifest_sha256" \
    "$config" "$config_identity" "$config_sha256" "$config_canonical_sha256" \
    "$config_snapshot" "$kernel" "$kernel_identity" "$kernel_sha256" "$rootfs" \
    "$rootfs_identity" "$rootfs_sha256" "$rootfs_base_sha256" "$rootfs_lineage_sha256" \
    "$policy" "$policy_identity" "$policy_sha256" "$policy_current_sha256" \
    "$workspace" "$workspace_identity" "$workspace_sha256" "$state" "$state_identity" \
    "$state_sha256" deny)" || return 1
  mkdir -p "$(dirname "$record")" || return 1
  temp="$(mktemp "${record}.XXXXXX")" || return 1
  chmod 600 "$temp" || { rm -f -- "$temp"; return 1; }
  {
    printf 'schema=3\n'
    printf 'owner_pid=%s\n' "$$"
    printf 'owner_start=%s\n' "$owner_start"
    printf 'vm_pid=%s\n' "$vm_pid"
    printf 'vm_start=%s\n' "$vm_start"
    printf 'tap=%s\n' "$IHAR_MICROVM_TAP"
    printf 'chain=%s\n' "$IHAR_MICROVM_CHAIN"
    printf 'guest_ip=%s\n' "$IHAR_MICROVM_GUEST_IP"
    printf 'host_ip=%s\n' "$IHAR_MICROVM_HOST_IP"
    printf 'gateway_port=%s\n' "$IHAR_GATEWAY_ACTIVE_PORT"
    printf 'launch_id=%s\n' "$launch_id"
    printf 'egress=%s\n' "$egress"
    printf 'manifest_path=%s\n' "$manifest"
    printf 'manifest_sha256=%s\n' "$manifest_sha256"
    printf 'config_path=%s\n' "$config"
    printf 'config_identity=%s\n' "$config_identity"
    printf 'config_sha256=%s\n' "$config_sha256"
    printf 'config_canonical_sha256=%s\n' "$config_canonical_sha256"
    printf 'config_snapshot_path=%s\n' "$config_snapshot"
    printf 'kernel_path=%s\n' "$kernel"
    printf 'kernel_identity=%s\n' "$kernel_identity"
    printf 'kernel_current_sha256=%s\n' "$kernel_sha256"
    printf 'rootfs_path=%s\n' "$rootfs"
    printf 'rootfs_identity=%s\n' "$rootfs_identity"
    printf 'rootfs_launch_sha256=%s\n' "$rootfs_sha256"
    printf 'rootfs_base_sha256=%s\n' "$rootfs_base_sha256"
    printf 'rootfs_lineage_sha256=%s\n' "$rootfs_lineage_sha256"
    printf 'policy_path=%s\n' "$policy"
    printf 'policy_identity=%s\n' "$policy_identity"
    printf 'policy_launch_sha256=%s\n' "$policy_sha256"
    printf 'policy_current_sha256=%s\n' "$policy_current_sha256"
    printf 'workspace_path=%s\n' "$workspace"
    printf 'workspace_identity=%s\n' "$workspace_identity"
    printf 'workspace_launch_sha256=%s\n' "$workspace_sha256"
    printf 'state_path=%s\n' "$state"
    printf 'state_identity=%s\n' "$state_identity"
    printf 'state_launch_sha256=%s\n' "$state_sha256"
    printf 'launch_config_sha256=%s\n' "$launch_config_sha256"
    printf 'default=deny\n'
  } > "$temp" || { rm -f -- "$temp"; return 1; }
  mv -f -- "$temp" "$record" || { rm -f -- "$temp"; return 1; }
}

ihar_microvm_network_evidence_remove() {
  local record
  record="$(_ihar_microvm_network_evidence_path)" || return 0
  rm -f -- "$record"
}

_ihar_microvm_network_evidence_read() {
  local record launch_config_sha256 destination value
  local -a lines=() keys=(
    schema owner_pid owner_start vm_pid vm_start tap chain guest_ip host_ip
    gateway_port launch_id egress manifest_path manifest_sha256 config_path
    config_identity config_sha256 config_canonical_sha256 config_snapshot_path
    kernel_path kernel_identity kernel_current_sha256 rootfs_path rootfs_identity
    rootfs_launch_sha256 rootfs_base_sha256 rootfs_lineage_sha256 policy_path
    policy_identity policy_launch_sha256 policy_current_sha256 workspace_path
    workspace_identity workspace_launch_sha256 state_path state_identity
    state_launch_sha256 launch_config_sha256 default
  )
  record="$(_ihar_microvm_network_evidence_path)" || return 1
  [[ -f "$record" && ! -L "$record" ]] || return 1
  mapfile -t lines < "$record" || return 1
  (( ${#lines[@]} == ${#keys[@]} )) || return 1
  local index
  for index in "${!keys[@]}"; do
    [[ "${lines[index]}" == "${keys[index]}="* ]] || return 1
  done
  [[ "${lines[0]}" == schema=3 && "${lines[38]}" == default=deny ]] || return 1
  _IHAR_MICROVM_EVIDENCE_OWNER="${lines[1]#owner_pid=}"
  _IHAR_MICROVM_EVIDENCE_OWNER_START="${lines[2]#owner_start=}"
  _IHAR_MICROVM_EVIDENCE_VM="${lines[3]#vm_pid=}"
  _IHAR_MICROVM_EVIDENCE_VM_START="${lines[4]#vm_start=}"
  _IHAR_MICROVM_EVIDENCE_TAP="${lines[5]#tap=}"
  _IHAR_MICROVM_EVIDENCE_CHAIN="${lines[6]#chain=}"
  _IHAR_MICROVM_EVIDENCE_GUEST="${lines[7]#guest_ip=}"
  _IHAR_MICROVM_EVIDENCE_HOST="${lines[8]#host_ip=}"
  _IHAR_MICROVM_EVIDENCE_PORT="${lines[9]#gateway_port=}"
  _IHAR_MICROVM_EVIDENCE_LAUNCH="${lines[10]#launch_id=}"
  _IHAR_MICROVM_EVIDENCE_EGRESS="${lines[11]#egress=}"
  _IHAR_MICROVM_EVIDENCE_MANIFEST="${lines[12]#manifest_path=}"
  _IHAR_MICROVM_EVIDENCE_MANIFEST_SHA256="${lines[13]#manifest_sha256=}"
  _IHAR_MICROVM_EVIDENCE_CONFIG="${lines[14]#config_path=}"
  _IHAR_MICROVM_EVIDENCE_CONFIG_IDENTITY="${lines[15]#config_identity=}"
  _IHAR_MICROVM_EVIDENCE_CONFIG_SHA256="${lines[16]#config_sha256=}"
  _IHAR_MICROVM_EVIDENCE_CONFIG_CANONICAL_SHA256="${lines[17]#config_canonical_sha256=}"
  _IHAR_MICROVM_EVIDENCE_CONFIG_SNAPSHOT="${lines[18]#config_snapshot_path=}"
  _IHAR_MICROVM_EVIDENCE_KERNEL="${lines[19]#kernel_path=}"
  _IHAR_MICROVM_EVIDENCE_KERNEL_IDENTITY="${lines[20]#kernel_identity=}"
  _IHAR_MICROVM_EVIDENCE_KERNEL_SHA256="${lines[21]#kernel_current_sha256=}"
  _IHAR_MICROVM_EVIDENCE_ROOTFS="${lines[22]#rootfs_path=}"
  _IHAR_MICROVM_EVIDENCE_ROOTFS_IDENTITY="${lines[23]#rootfs_identity=}"
  _IHAR_MICROVM_EVIDENCE_ROOTFS_SHA256="${lines[24]#rootfs_launch_sha256=}"
  _IHAR_MICROVM_EVIDENCE_ROOTFS_BASE_SHA256="${lines[25]#rootfs_base_sha256=}"
  _IHAR_MICROVM_EVIDENCE_ROOTFS_LINEAGE_SHA256="${lines[26]#rootfs_lineage_sha256=}"
  _IHAR_MICROVM_EVIDENCE_POLICY="${lines[27]#policy_path=}"
  _IHAR_MICROVM_EVIDENCE_POLICY_IDENTITY="${lines[28]#policy_identity=}"
  _IHAR_MICROVM_EVIDENCE_POLICY_SHA256="${lines[29]#policy_launch_sha256=}"
  _IHAR_MICROVM_EVIDENCE_POLICY_CURRENT_SHA256="${lines[30]#policy_current_sha256=}"
  _IHAR_MICROVM_EVIDENCE_WORKSPACE="${lines[31]#workspace_path=}"
  _IHAR_MICROVM_EVIDENCE_WORKSPACE_IDENTITY="${lines[32]#workspace_identity=}"
  _IHAR_MICROVM_EVIDENCE_WORKSPACE_SHA256="${lines[33]#workspace_launch_sha256=}"
  _IHAR_MICROVM_EVIDENCE_STATE="${lines[34]#state_path=}"
  _IHAR_MICROVM_EVIDENCE_STATE_IDENTITY="${lines[35]#state_identity=}"
  _IHAR_MICROVM_EVIDENCE_STATE_SHA256="${lines[36]#state_launch_sha256=}"
  _IHAR_MICROVM_EVIDENCE_LAUNCH_CONFIG_SHA256="${lines[37]#launch_config_sha256=}"
  _IHAR_MICROVM_EVIDENCE_DEFAULT="${lines[38]#default=}"
  [[ "$_IHAR_MICROVM_EVIDENCE_OWNER" =~ ^[1-9][0-9]*$ \
    && "$_IHAR_MICROVM_EVIDENCE_OWNER_START" =~ ^[0-9]+$ \
    && "$_IHAR_MICROVM_EVIDENCE_VM" =~ ^[1-9][0-9]*$ \
    && "$_IHAR_MICROVM_EVIDENCE_VM_START" =~ ^[0-9]+$ \
    && "$_IHAR_MICROVM_EVIDENCE_TAP" =~ ^[A-Za-z0-9_-]{1,15}$ \
    && "$_IHAR_MICROVM_EVIDENCE_CHAIN" =~ ^[A-Za-z0-9_]{1,25}$ \
    && "$_IHAR_MICROVM_EVIDENCE_GUEST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ \
    && "$_IHAR_MICROVM_EVIDENCE_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ \
    && "$_IHAR_MICROVM_EVIDENCE_PORT" =~ ^[1-9][0-9]*$ \
    && "$_IHAR_MICROVM_EVIDENCE_LAUNCH" =~ ^[A-Za-z0-9._-]+$ \
    && "$_IHAR_MICROVM_EVIDENCE_DEFAULT" == deny ]] || return 1
  for value in "$_IHAR_MICROVM_EVIDENCE_MANIFEST" "$_IHAR_MICROVM_EVIDENCE_CONFIG" \
      "$_IHAR_MICROVM_EVIDENCE_CONFIG_SNAPSHOT" "$_IHAR_MICROVM_EVIDENCE_KERNEL" \
      "$_IHAR_MICROVM_EVIDENCE_ROOTFS" "$_IHAR_MICROVM_EVIDENCE_POLICY" \
      "$_IHAR_MICROVM_EVIDENCE_WORKSPACE" "$_IHAR_MICROVM_EVIDENCE_STATE"; do
    [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\t'* ]] || return 1
  done
  for value in "$_IHAR_MICROVM_EVIDENCE_MANIFEST_SHA256" \
      "$_IHAR_MICROVM_EVIDENCE_CONFIG_SHA256" \
      "$_IHAR_MICROVM_EVIDENCE_CONFIG_CANONICAL_SHA256" \
      "$_IHAR_MICROVM_EVIDENCE_KERNEL_SHA256" "$_IHAR_MICROVM_EVIDENCE_ROOTFS_SHA256" \
      "$_IHAR_MICROVM_EVIDENCE_ROOTFS_BASE_SHA256" \
      "$_IHAR_MICROVM_EVIDENCE_ROOTFS_LINEAGE_SHA256" \
      "$_IHAR_MICROVM_EVIDENCE_POLICY_SHA256" \
      "$_IHAR_MICROVM_EVIDENCE_POLICY_CURRENT_SHA256" \
      "$_IHAR_MICROVM_EVIDENCE_WORKSPACE_SHA256" "$_IHAR_MICROVM_EVIDENCE_STATE_SHA256" \
      "$_IHAR_MICROVM_EVIDENCE_LAUNCH_CONFIG_SHA256"; do
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 1
  done
  for value in "$_IHAR_MICROVM_EVIDENCE_CONFIG_IDENTITY" \
      "$_IHAR_MICROVM_EVIDENCE_KERNEL_IDENTITY" "$_IHAR_MICROVM_EVIDENCE_ROOTFS_IDENTITY" \
      "$_IHAR_MICROVM_EVIDENCE_POLICY_IDENTITY" "$_IHAR_MICROVM_EVIDENCE_WORKSPACE_IDENTITY" \
      "$_IHAR_MICROVM_EVIDENCE_STATE_IDENTITY"; do
    [[ "$value" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
  done
  launch_config_sha256="$(_ihar_microvm_launch_config_digest \
    "$_IHAR_MICROVM_EVIDENCE_OWNER" "$_IHAR_MICROVM_EVIDENCE_OWNER_START" \
    "$_IHAR_MICROVM_EVIDENCE_VM" "$_IHAR_MICROVM_EVIDENCE_VM_START" \
    "$_IHAR_MICROVM_EVIDENCE_TAP" "$_IHAR_MICROVM_EVIDENCE_CHAIN" \
    "$_IHAR_MICROVM_EVIDENCE_GUEST" "$_IHAR_MICROVM_EVIDENCE_HOST" \
    "$_IHAR_MICROVM_EVIDENCE_PORT" "$_IHAR_MICROVM_EVIDENCE_LAUNCH" \
    "$_IHAR_MICROVM_EVIDENCE_EGRESS" "$_IHAR_MICROVM_EVIDENCE_MANIFEST" \
    "$_IHAR_MICROVM_EVIDENCE_MANIFEST_SHA256" "$_IHAR_MICROVM_EVIDENCE_CONFIG" \
    "$_IHAR_MICROVM_EVIDENCE_CONFIG_IDENTITY" "$_IHAR_MICROVM_EVIDENCE_CONFIG_SHA256" \
    "$_IHAR_MICROVM_EVIDENCE_CONFIG_CANONICAL_SHA256" \
    "$_IHAR_MICROVM_EVIDENCE_CONFIG_SNAPSHOT" "$_IHAR_MICROVM_EVIDENCE_KERNEL" \
    "$_IHAR_MICROVM_EVIDENCE_KERNEL_IDENTITY" "$_IHAR_MICROVM_EVIDENCE_KERNEL_SHA256" \
    "$_IHAR_MICROVM_EVIDENCE_ROOTFS" "$_IHAR_MICROVM_EVIDENCE_ROOTFS_IDENTITY" \
    "$_IHAR_MICROVM_EVIDENCE_ROOTFS_SHA256" "$_IHAR_MICROVM_EVIDENCE_ROOTFS_BASE_SHA256" \
    "$_IHAR_MICROVM_EVIDENCE_ROOTFS_LINEAGE_SHA256" "$_IHAR_MICROVM_EVIDENCE_POLICY" \
    "$_IHAR_MICROVM_EVIDENCE_POLICY_IDENTITY" "$_IHAR_MICROVM_EVIDENCE_POLICY_SHA256" \
    "$_IHAR_MICROVM_EVIDENCE_POLICY_CURRENT_SHA256" "$_IHAR_MICROVM_EVIDENCE_WORKSPACE" \
    "$_IHAR_MICROVM_EVIDENCE_WORKSPACE_IDENTITY" "$_IHAR_MICROVM_EVIDENCE_WORKSPACE_SHA256" \
    "$_IHAR_MICROVM_EVIDENCE_STATE" "$_IHAR_MICROVM_EVIDENCE_STATE_IDENTITY" \
    "$_IHAR_MICROVM_EVIDENCE_STATE_SHA256" deny)" || return 1
  [[ "$launch_config_sha256" == "$_IHAR_MICROVM_EVIDENCE_LAUNCH_CONFIG_SHA256" ]] \
    || return 1
  IFS=',' read -r -a _IHAR_MICROVM_EVIDENCE_EGRESS_ITEMS <<< \
    "$_IHAR_MICROVM_EVIDENCE_EGRESS"
  [[ -n "$_IHAR_MICROVM_EVIDENCE_EGRESS" ]] || _IHAR_MICROVM_EVIDENCE_EGRESS_ITEMS=()
  for destination in "${_IHAR_MICROVM_EVIDENCE_EGRESS_ITEMS[@]}"; do
    [[ "$destination" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[1-9][0-9]*$ ]] || return 1
    (( ${destination##*:} <= 65535 )) || return 1
  done
}

_ihar_microvm_link_active() { ip link show dev "$1" >/dev/null 2>&1; }

_ihar_microvm_process_is_firecracker() {
  local actual expected
  actual="$(readlink -f "/proc/$1/exe" 2>/dev/null)" || return 1
  expected="$(readlink -f "$IHAR_STORE/bin/firecracker" 2>/dev/null)" || return 1
  [[ -n "$actual" && "$actual" == "$expected" ]]
}

_ihar_microvm_process_uses_config() {
  local pid="$1" expected="$2" argument previous=""
  while IFS= read -r -d '' argument; do
    [[ "$previous" == --config-file && "$argument" == "$expected" ]] && return 0
    previous="$argument"
  done < "/proc/$pid/cmdline"
  return 1
}

_ihar_microvm_config_facts() { # <config> <tap> <guest-ip> <host-ip>
  python3 - "$1" "$2" "$3" "$4" "$IHAR_STORE/bin/vmlinux" <<'PY'
import hashlib
import json
import os
import sys

config, tap, guest, host, kernel = sys.argv[1:]
try:
    with open(config, encoding="utf-8") as stream:
        data = json.load(stream)
except (OSError, TypeError, ValueError):
    raise SystemExit(1)

directory = os.path.dirname(config)
paths = {
    "rootfs": os.path.join(directory, "rootfs.ext4"),
    "policy": os.path.join(directory, "policy.ext4"),
    "workspace": os.path.join(directory, "workspace.ext4"),
    "state": os.path.join(directory, "state.ext4"),
}
suffix = tap.rsplit("-", 1)[-1]
mac_octet = int(suffix) if suffix.isdigit() else 1
boot_args = (
    "console=ttyS0 reboot=k panic=1 pci=off nomodules "
    f"ip={guest}::{host}:255.255.255.252::eth0:off"
)
expected_drives = [
    {"drive_id": "rootfs", "path_on_host": paths["rootfs"],
     "is_root_device": True, "is_read_only": False},
    {"drive_id": "policy", "path_on_host": paths["policy"],
     "is_root_device": False, "is_read_only": True},
    {"drive_id": "workspace", "path_on_host": paths["workspace"],
     "is_root_device": False, "is_read_only": False},
    {"drive_id": "state", "path_on_host": paths["state"],
     "is_root_device": False, "is_read_only": False},
]
valid = (
    isinstance(data, dict)
    and set(data) == {"boot-source", "drives", "machine-config", "network-interfaces"}
    and data.get("boot-source") == {
        "kernel_image_path": kernel,
        "boot_args": boot_args,
    }
    and data.get("drives") == expected_drives
    and isinstance(data.get("machine-config"), dict)
    and set(data["machine-config"]) == {"vcpu_count", "mem_size_mib"}
    and all(
        isinstance(data["machine-config"][key], int)
        and not isinstance(data["machine-config"][key], bool)
        and data["machine-config"][key] > 0
        for key in ("vcpu_count", "mem_size_mib")
    )
    and data.get("network-interfaces") == [{
        "iface_id": "eth0",
        "guest_mac": f"AA:FC:00:00:00:{mac_octet:02X}",
        "host_dev_name": tap,
    }]
)
if not valid:
    raise SystemExit(1)
for value in (config, kernel, *paths.values()):
    if any(character in value for character in "\r\n\t"):
        raise SystemExit(1)
canonical = json.dumps(data, sort_keys=True, separators=(",", ":")).encode()
print(hashlib.sha256(canonical).hexdigest())
print(kernel)
for name in ("rootfs", "policy", "workspace", "state"):
    print(paths[name])
PY
}

_ihar_microvm_config_matches_evidence() {
  local actual pinned
  local -a facts=() manifest_facts=()
  [[ -f "$_IHAR_MICROVM_EVIDENCE_MANIFEST" && ! -L "$_IHAR_MICROVM_EVIDENCE_MANIFEST" ]] \
    || return 1
  actual="$(sha256sum "$_IHAR_MICROVM_EVIDENCE_MANIFEST" | cut -d' ' -f1)" || return 1
  [[ "$actual" == "$_IHAR_MICROVM_EVIDENCE_MANIFEST_SHA256" ]] || return 1
  mapfile -t manifest_facts < <(_ihar_microvm_launch_manifest_facts \
    "$_IHAR_MICROVM_EVIDENCE_MANIFEST")
  (( ${#manifest_facts[@]} == 26 )) || return 1
  [[ "${manifest_facts[0]}" == "$_IHAR_MICROVM_EVIDENCE_CONFIG" \
    && "${manifest_facts[1]}" == "$_IHAR_MICROVM_EVIDENCE_CONFIG_IDENTITY" \
    && "${manifest_facts[2]}" == "$_IHAR_MICROVM_EVIDENCE_CONFIG_SHA256" \
    && "${manifest_facts[3]}" == "$_IHAR_MICROVM_EVIDENCE_CONFIG_CANONICAL_SHA256" \
    && "${manifest_facts[4]}" == "$_IHAR_MICROVM_EVIDENCE_CONFIG_SNAPSHOT" \
    && "${manifest_facts[5]}" == "$_IHAR_MICROVM_EVIDENCE_KERNEL" \
    && "${manifest_facts[6]}" == "$_IHAR_MICROVM_EVIDENCE_KERNEL_IDENTITY" \
    && "${manifest_facts[7]}" == "$_IHAR_MICROVM_EVIDENCE_KERNEL_SHA256" \
    && "${manifest_facts[8]}" == "$_IHAR_MICROVM_EVIDENCE_ROOTFS" \
    && "${manifest_facts[9]}" == "$_IHAR_MICROVM_EVIDENCE_ROOTFS_IDENTITY" \
    && "${manifest_facts[10]}" == "$_IHAR_MICROVM_EVIDENCE_ROOTFS_SHA256" \
    && "${manifest_facts[11]}" == "$_IHAR_MICROVM_EVIDENCE_ROOTFS_BASE_SHA256" \
    && "${manifest_facts[12]}" == "$_IHAR_MICROVM_EVIDENCE_ROOTFS_LINEAGE_SHA256" \
    && "${manifest_facts[13]}" == "$_IHAR_MICROVM_EVIDENCE_POLICY" \
    && "${manifest_facts[14]}" == "$_IHAR_MICROVM_EVIDENCE_POLICY_IDENTITY" \
    && "${manifest_facts[15]}" == "$_IHAR_MICROVM_EVIDENCE_POLICY_SHA256" \
    && "${manifest_facts[16]}" == "$_IHAR_MICROVM_EVIDENCE_POLICY_CURRENT_SHA256" \
    && "${manifest_facts[17]}" == "$_IHAR_MICROVM_EVIDENCE_WORKSPACE" \
    && "${manifest_facts[18]}" == "$_IHAR_MICROVM_EVIDENCE_WORKSPACE_IDENTITY" \
    && "${manifest_facts[19]}" == "$_IHAR_MICROVM_EVIDENCE_WORKSPACE_SHA256" \
    && "${manifest_facts[20]}" == "$_IHAR_MICROVM_EVIDENCE_STATE" \
    && "${manifest_facts[21]}" == "$_IHAR_MICROVM_EVIDENCE_STATE_IDENTITY" \
    && "${manifest_facts[22]}" == "$_IHAR_MICROVM_EVIDENCE_STATE_SHA256" \
    && "${manifest_facts[23]}" == "$_IHAR_MICROVM_EVIDENCE_TAP" \
    && "${manifest_facts[24]}" == "$_IHAR_MICROVM_EVIDENCE_GUEST" \
    && "${manifest_facts[25]}" == "$_IHAR_MICROVM_EVIDENCE_HOST" ]] || return 1
  [[ -f "$_IHAR_MICROVM_EVIDENCE_CONFIG_SNAPSHOT" \
    && ! -L "$_IHAR_MICROVM_EVIDENCE_CONFIG_SNAPSHOT" ]] || return 1
  actual="$(sha256sum "$_IHAR_MICROVM_EVIDENCE_CONFIG_SNAPSHOT" | cut -d' ' -f1)" \
    || return 1
  [[ "$actual" == "$_IHAR_MICROVM_EVIDENCE_CONFIG_SHA256" ]] || return 1
  mapfile -t facts < <(_ihar_microvm_config_facts \
    "$_IHAR_MICROVM_EVIDENCE_CONFIG_SNAPSHOT" "$_IHAR_MICROVM_EVIDENCE_TAP" \
    "$_IHAR_MICROVM_EVIDENCE_GUEST" "$_IHAR_MICROVM_EVIDENCE_HOST")
  (( ${#facts[@]} == 6 )) || return 1
  [[ "${facts[0]}" == "$_IHAR_MICROVM_EVIDENCE_CONFIG_CANONICAL_SHA256" ]] || return 1
  [[ -f "$_IHAR_MICROVM_EVIDENCE_KERNEL" && ! -L "$_IHAR_MICROVM_EVIDENCE_KERNEL" \
    && -f "$_IHAR_MICROVM_EVIDENCE_POLICY" && ! -L "$_IHAR_MICROVM_EVIDENCE_POLICY" ]] \
    || return 1
  [[ "$(_ihar_microvm_file_identity "$_IHAR_MICROVM_EVIDENCE_KERNEL")" \
      == "$_IHAR_MICROVM_EVIDENCE_KERNEL_IDENTITY" \
    && "$(_ihar_microvm_file_identity "$_IHAR_MICROVM_EVIDENCE_POLICY")" \
      == "$_IHAR_MICROVM_EVIDENCE_POLICY_IDENTITY" ]] || return 1
  actual="$(sha256sum "$_IHAR_MICROVM_EVIDENCE_KERNEL" | cut -d' ' -f1)" || return 1
  [[ "$actual" == "$_IHAR_MICROVM_EVIDENCE_KERNEL_SHA256" ]] || return 1
  pinned="$(ihar_lockfile_get microvm.kernel 2>/dev/null)" || return 1
  [[ "$pinned" == "$_IHAR_MICROVM_EVIDENCE_KERNEL_SHA256" ]] || return 1
  pinned="$(ihar_lockfile_get microvm.rootfs 2>/dev/null)" || return 1
  [[ "$pinned" == "$_IHAR_MICROVM_EVIDENCE_ROOTFS_BASE_SHA256" ]] || return 1
  actual="$(sha256sum "$_IHAR_MICROVM_EVIDENCE_POLICY" | cut -d' ' -f1)" || return 1
  [[ "$actual" == "$_IHAR_MICROVM_EVIDENCE_POLICY_CURRENT_SHA256" ]]
}

_ihar_microvm_network_rules_verified() {
  local tap="$_IHAR_MICROVM_EVIDENCE_TAP" chain="$_IHAR_MICROVM_EVIDENCE_CHAIN"
  local input_chain="${chain}_IN" port="$_IHAR_MICROVM_EVIDENCE_PORT"
  local host="$_IHAR_MICROVM_EVIDENCE_HOST" marker="ihar:${_IHAR_MICROVM_EVIDENCE_LAUNCH}"
  local guest="$_IHAR_MICROVM_EVIDENCE_GUEST" rules first second last count expected
  local destination ip dport
  rules="$(_ihar_microvm_iptables -S "$chain" 2>/dev/null)" || return 1
  count="$(awk -v chain="$chain" '$1 == "-A" && $2 == chain {count++} END {print count + 0}' <<< "$rules")"
  last="$(awk -v chain="$chain" '$1 == "-A" && $2 == chain {line=$0} END {print line}' <<< "$rules")"
  expected=$(( ${#_IHAR_MICROVM_EVIDENCE_EGRESS_ITEMS[@]} + 2 ))
  [[ "$count" == "$expected" && "$last" == "-A $chain -j DROP" ]] || return 1
  rules="$(_ihar_microvm_iptables -S "$input_chain" 2>/dev/null)" || return 1
  count="$(awk -v chain="$input_chain" '$1 == "-A" && $2 == chain {count++} END {print count + 0}' <<< "$rules")"
  last="$(awk -v chain="$input_chain" '$1 == "-A" && $2 == chain {line=$0} END {print line}' <<< "$rules")"
  [[ "$count" == 3 && "$last" == "-A $input_chain -j DROP" ]] || return 1
  rules="$(_ihar_microvm_iptables -S FORWARD 2>/dev/null)" || return 1
  first="$(awk '$1 == "-A" {print; exit}' <<< "$rules")"
  second="$(awk '$1 == "-A" {count++; if (count == 2) {print; exit}}' <<< "$rules")"
  [[ "$first" == "-A FORWARD -o $tap -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" \
    || "$first" == "-A FORWARD -o $tap -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" ]] \
    || return 1
  [[ "$second" == "-A FORWARD -i $tap -j $chain" ]] || return 1
  rules="$(_ihar_microvm_iptables -S INPUT 2>/dev/null)" || return 1
  first="$(awk '$1 == "-A" {print; exit}' <<< "$rules")"
  [[ "$first" == "-A INPUT -i $tap -j $input_chain" ]] || return 1
  _ihar_microvm_iptables -C "$chain" -j DROP >/dev/null 2>&1 \
    && _ihar_microvm_iptables -C FORWARD -i "$tap" -j "$chain" >/dev/null 2>&1 \
    && _ihar_microvm_iptables -C "$chain" -m conntrack \
      --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 \
    && _ihar_microvm_iptables -C FORWARD -o "$tap" -m conntrack \
      --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 \
    && _ihar_microvm_iptables -C "$input_chain" -j DROP >/dev/null 2>&1 \
    && _ihar_microvm_iptables -C INPUT -i "$tap" -j "$input_chain" >/dev/null 2>&1 \
    && _ihar_microvm_iptables -C "$input_chain" -m conntrack \
      --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 \
    && _ihar_microvm_iptables -C "$input_chain" -d 127.0.0.1 -p tcp \
      --dport "$port" -j ACCEPT >/dev/null 2>&1 \
    && _ihar_microvm_iptables -C INPUT -i "$tap" -p tcp --dport "$port" \
      -m comment --comment "$marker" -j ACCEPT >/dev/null 2>&1 \
    && _ihar_microvm_iptables -t nat -C PREROUTING -i "$tap" -d "$host" -p tcp \
      --dport "$port" -m comment --comment "$marker" -j DNAT \
      --to-destination "127.0.0.1:$port" >/dev/null 2>&1 \
    || return 1
  for destination in "${_IHAR_MICROVM_EVIDENCE_EGRESS_ITEMS[@]}"; do
    ip="${destination%:*}"; dport="${destination##*:}"
    _ihar_microvm_iptables -C "$chain" -d "$ip" -p tcp --dport "$dport" \
      -j ACCEPT >/dev/null 2>&1 || return 1
    _ihar_microvm_iptables -t nat -C POSTROUTING -s "$guest" -d "$ip" -p tcp \
      --dport "$dport" -m comment --comment "$marker" -j MASQUERADE \
      >/dev/null 2>&1 || return 1
  done
}

# ihar_microvm_network_evidence — read-only, closed boolean facts for `ihar check`.
ihar_microvm_network_evidence() {
  local configured=false available=false active=false verified=false
  if [[ "${IHAR_PROFILE_SANDBOX:-}" == microvm && -n "${IHAR_PROFILE_NETPOLICY:-}" ]]; then
    configured=true
    _ihar_microvm_assets_available && available=true
    if _ihar_microvm_network_evidence_read \
        && kill -0 "$_IHAR_MICROVM_EVIDENCE_OWNER" 2>/dev/null \
        && [[ "$(_ihar_microvm_process_start_time "$_IHAR_MICROVM_EVIDENCE_OWNER")" \
          == "$_IHAR_MICROVM_EVIDENCE_OWNER_START" ]] \
        && kill -0 "$_IHAR_MICROVM_EVIDENCE_VM" 2>/dev/null \
        && [[ "$(_ihar_microvm_process_start_time "$_IHAR_MICROVM_EVIDENCE_VM")" \
          == "$_IHAR_MICROVM_EVIDENCE_VM_START" ]] \
        && _ihar_microvm_process_is_firecracker "$_IHAR_MICROVM_EVIDENCE_VM" \
        && _ihar_microvm_process_uses_config "$_IHAR_MICROVM_EVIDENCE_VM" \
          "$_IHAR_MICROVM_EVIDENCE_CONFIG" \
        && _ihar_microvm_config_matches_evidence \
        && _ihar_microvm_link_active "$_IHAR_MICROVM_EVIDENCE_TAP"; then
      active=true
      if [[ "$available" == true ]] && _ihar_microvm_network_rules_verified; then
        verified=true
      fi
    fi
  fi
  printf '{"configured":%s,"available":%s,"active":%s,"verified":%s}\n' \
    "$configured" "$available" "$active" "$verified"
}

_ihar_microvm_coord_root() {
  local root
  root="${XDG_RUNTIME_DIR:-/tmp}/ihar-microvm-$(id -u)"
  mkdir -p "$root" && chmod 700 "$root" || return 1
  printf '%s\n' "$root"
}

# Reader/writer launch guard without inherited lock descriptors. Native vendors keep
# their PID when the shell execs; stale registrations are swept under the guard lock.
ihar_launch_state_enter() {
  local mode="$1" dir="$IHAR_STATE/.launch-guard" file owner busy
  mkdir -p "$dir/native" || ihar_die 3 "cannot create the launch state guard"
  while true; do
    exec {guard_fd}>"$dir/lock"; flock -x "$guard_fd" || ihar_die 3 "cannot lock the launch state guard"
    for file in "$dir/native"/*.pid "$dir/isolated.pid"; do
      [[ -e "$file" ]] || continue
      owner="$(cat "$file" 2>/dev/null || true)"
      [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null || rm -f "$file"
    done
    busy=false
    if [[ "$mode" == isolated ]]; then
      [[ -e "$dir/isolated.pid" ]] && busy=true
      compgen -G "$dir/native/*.pid" >/dev/null && busy=true
      [[ "$busy" == true ]] || printf '%s\n' "$$" > "$dir/isolated.pid"
    else
      [[ -e "$dir/isolated.pid" ]] && busy=true
      [[ "$busy" == true ]] || printf '%s\n' "$$" > "$dir/native/$$.pid"
    fi
    exec {guard_fd}>&-
    [[ "$busy" == false ]] && return 0
    sleep 0.1
  done
}

ihar_launch_state_leave() {
  local dir="$IHAR_STATE/.launch-guard"
  rm -f "$dir/native/$$.pid"
  [[ "$(cat "$dir/isolated.pid" 2>/dev/null || true)" == "$$" ]] && rm -f "$dir/isolated.pid"
}

ihar_microvm_reserve_slot() {
  [[ -n "${IHAR_MICROVM_SLOT:-}" ]] && return 0
  local dir file owner slot found=false coord
  coord="$(_ihar_microvm_coord_root)" || ihar_die 3 "cannot create host microVM coordination state"
  dir="$coord/slots"
  mkdir -p "$dir" || ihar_die 3 "cannot create the microVM slot directory"
  exec {reserve_fd}>"$dir/lock"; flock -x "$reserve_fd" || ihar_die 3 "cannot lock the microVM slot allocator"
  for file in "$dir"/*.pid; do
    [[ -e "$file" ]] || continue
    owner="$(cat "$file" 2>/dev/null || true)"
    [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null || rm -f "$file"
  done
  for slot in $(seq 1 32); do
    if [[ ! -e "$dir/$slot.pid" ]]; then found=true; break; fi
  done
  [[ "$found" == true ]] || ihar_die 3 "no free microVM network slot"
  printf '%s\n' "$$" > "$dir/$slot.pid"
  exec {reserve_fd}>&-
  IHAR_MICROVM_SLOT="$slot"
  IHAR_MICROVM_TAP="tap-ih-$(id -u)-$slot"
  IHAR_MICROVM_HOST_IP="172.31.0.$(( (slot - 1) * 4 + 1 ))"
  IHAR_MICROVM_GUEST_IP="172.31.0.$(( (slot - 1) * 4 + 2 ))"
  IHAR_MICROVM_CHAIN="IHAR_${IHAR_LAUNCH_ID:-$$}"
  IHAR_MICROVM_CHAIN="${IHAR_MICROVM_CHAIN//[^A-Za-z0-9_]/_}"
  IHAR_MICROVM_CHAIN="${IHAR_MICROVM_CHAIN:0:25}"
  export IHAR_MICROVM_SLOT IHAR_MICROVM_TAP IHAR_MICROVM_HOST_IP \
    IHAR_MICROVM_GUEST_IP IHAR_MICROVM_CHAIN
}

ihar_microvm_release_slot() {
  [[ -n "${IHAR_MICROVM_SLOT:-}" ]] || return 0
  local coord
  coord="$(_ihar_microvm_coord_root)" || return 0
  rm -f "$coord/slots/$IHAR_MICROVM_SLOT.pid"
  IHAR_MICROVM_SLOT=""
}

_ihar_microvm_forward_acquire() {
  local dir file owner coord
  coord="$(_ihar_microvm_coord_root)" || return 1
  dir="$coord/ip-forward"
  mkdir -p "$dir/consumers" || return 1
  exec {forward_fd}>"$dir/lock"; flock -x "$forward_fd" || return 1
  for file in "$dir"/consumers/*.pid; do
    [[ -e "$file" ]] || continue
    owner="$(cat "$file" 2>/dev/null || true)"
    [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null || rm -f "$file"
  done
  if ! compgen -G "$dir/consumers/*.pid" >/dev/null; then
    sysctl -n net.ipv4.ip_forward > "$dir/original" || return 1
    sudo -n sysctl -w net.ipv4.ip_forward=1 >/dev/null || return 1
  fi
  printf '%s\n' "$$" > "$dir/consumers/$$.pid"
  exec {forward_fd}>&-
}

_ihar_microvm_forward_release() {
  local dir file owner original coord
  coord="$(_ihar_microvm_coord_root)" || return 0
  dir="$coord/ip-forward"
  [[ -d "$dir" ]] || return 0
  exec {forward_fd}>"$dir/lock"; flock -x "$forward_fd" || return 0
  rm -f "$dir/consumers/$$.pid"
  for file in "$dir"/consumers/*.pid; do
    [[ -e "$file" ]] || continue
    owner="$(cat "$file" 2>/dev/null || true)"
    [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null || rm -f "$file"
  done
  if ! compgen -G "$dir/consumers/*.pid" >/dev/null; then
    original="$(cat "$dir/original" 2>/dev/null || echo 0)"
    sudo -n sysctl -w "net.ipv4.ip_forward=$original" >/dev/null 2>&1 || true
  fi
  exec {forward_fd}>&-
}

# One chain owns all forwarded guest traffic. Its final DROP is the guarantee.
ihar_microvm_network_apply() {
  local tap="${IHAR_MICROVM_TAP:?}" guest="${IHAR_MICROVM_GUEST_IP:?}"
  local host="${IHAR_MICROVM_HOST_IP:?}" chain="${IHAR_MICROVM_CHAIN:?}"
  local input_chain="${chain}_IN"
  local port="${IHAR_GATEWAY_ACTIVE_PORT:?}" marker="ihar:${IHAR_LAUNCH_ID:-$$}"
  sudo -n true >/dev/null 2>&1 || return 1

  _ihar_microvm_forward_acquire || return 1

  _ihar_microvm_iptables -N "$chain" || return 1
  _ihar_microvm_iptables -N "$input_chain" || return 1
  _ihar_microvm_iptables -A "$chain" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
  local destination ip dport
  for destination in ${IHAR_MICROVM_MCP_EGRESS:-}; do
    destination="${destination%%|*}"
    ip="${destination%:*}"; dport="${destination##*:}"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$dport" =~ ^[0-9]+$ ]] || return 1
    _ihar_microvm_iptables -A "$chain" -d "$ip" -p tcp --dport "$dport" -j ACCEPT || return 1
    _ihar_microvm_iptables -t nat -A POSTROUTING -s "$guest" -d "$ip" -p tcp --dport "$dport" \
      -m comment --comment "$marker" -j MASQUERADE || return 1
  done
  _ihar_microvm_iptables -A "$chain" -j DROP || return 1
  _ihar_microvm_iptables -I FORWARD 1 -i "$tap" -j "$chain" || return 1
  _ihar_microvm_iptables -I FORWARD 1 -o "$tap" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1

  _ihar_microvm_iptables -A "$input_chain" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1

  sudo -n sysctl -w "net.ipv4.conf.${tap}.route_localnet=1" >/dev/null || return 1
  _ihar_microvm_iptables -t nat -A PREROUTING -i "$tap" -d "$host" -p tcp --dport "$port" \
    -m comment --comment "$marker" -j DNAT --to-destination "127.0.0.1:$port" || return 1
  _ihar_microvm_iptables -A INPUT -i "$tap" -p tcp --dport "$port" \
    -m comment --comment "$marker" -j ACCEPT || return 1
  _ihar_microvm_iptables -A "$input_chain" -d 127.0.0.1 -p tcp --dport "$port" -j ACCEPT || return 1
  _ihar_microvm_iptables -A "$input_chain" -j DROP || return 1
  _ihar_microvm_iptables -I INPUT 1 -i "$tap" -j "$input_chain" || return 1
}

ihar_microvm_network_remove() {
  local tap="${IHAR_MICROVM_TAP:-}" chain="${IHAR_MICROVM_CHAIN:-}"
  local input_chain="${chain}_IN"
  [[ -n "$tap" && -n "$chain" ]] || return 0
  local marker="ihar:${IHAR_LAUNCH_ID:-$$}" line
  _ihar_microvm_iptables -D FORWARD -i "$tap" -j "$chain" 2>/dev/null || true
  _ihar_microvm_iptables -D FORWARD -o "$tap" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  _ihar_microvm_iptables -F "$chain" 2>/dev/null || true
  _ihar_microvm_iptables -X "$chain" 2>/dev/null || true
  _ihar_microvm_iptables -D INPUT -i "$tap" -j "$input_chain" 2>/dev/null || true
  _ihar_microvm_iptables -F "$input_chain" 2>/dev/null || true
  _ihar_microvm_iptables -X "$input_chain" 2>/dev/null || true
  local table table_chain
  for table_chain in 'nat PREROUTING' 'nat POSTROUTING' 'filter INPUT'; do
    # Remove only rules carrying this launch marker; line numbers are re-read after each delete.
    read -r table chain_name <<< "$table_chain"
    while line="$(sudo -n iptables -t "$table" -L "$chain_name" --line-numbers -n 2>/dev/null \
      | awk -v marker="$marker" '$0 ~ marker {print $1; exit}')" && [[ -n "$line" ]]; do
      sudo -n iptables -t "$table" -D "$chain_name" "$line" 2>/dev/null || break
    done
  done
  sudo -n sysctl -w "net.ipv4.conf.${tap}.route_localnet=0" >/dev/null 2>&1 || true
  _ihar_microvm_forward_release
}

_ihar_microvm_collect_egress() {
  python3 - "$IHAR_ROOT/manifests/mcp/registry.json" <<'PY'
import json, os, socket, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
seen = set()
for server in data["servers"]:
    profiles = server.get("profiles", [])
    if "*" not in profiles and "isolated" not in profiles:
        continue
    if any(not os.environ.get(name) for name in server.get("requires_env", [])):
        continue
    for item in server.get("egress", []):
        for name, value in os.environ.items():
            item = item.replace("${" + name + "}", value)
        if "${" in item:
            continue
        host, port = item.rsplit(":", 1)
        try:
            results = socket.getaddrinfo(host, int(port), socket.AF_INET, socket.SOCK_STREAM)
        except socket.gaierror as error:
            raise SystemExit(f"cannot resolve declared MCP host {host}: {error}")
        for result in results:
            seen.add((result[4][0], host, int(port)))
for ip, host, port in sorted(seen):
    print(f"{ip}:{port}|{host}")
PY
}

_ihar_microvm_make_image() {
  local image="$1" source="$2" mib="$3"
  truncate -s "${mib}M" "$image" || return 1
  mkfs.ext4 -F -q -d "$source" "$image" >/dev/null 2>&1
}

_ihar_microvm_prepare_rootfs() {
  local rootfs="$1" base_sha256="${2:-}" public_key="$IHAR_STORE/microvm/current/client_key.pub"
  local sshd_policy="${rootfs}.sshd-policy"
  if [[ -n "$base_sha256" ]]; then
    [[ "$base_sha256" =~ ^[0-9a-f]{64}$ \
      && "$(sha256sum "$rootfs" | cut -d' ' -f1)" == "$base_sha256" ]] || return 1
  fi
  printf '%s\n' \
    'PermitRootLogin prohibit-password' \
    'AllowUsers root' \
    'PubkeyAuthentication yes' \
    'PasswordAuthentication no' > "$sshd_policy" || return 1
  debugfs -w -R 'set_inode_field /root/.ssh mode 040700' "$rootfs" >/dev/null 2>&1 || return 1
  debugfs -w -R 'rm /root/.ssh/authorized_keys' "$rootfs" >/dev/null 2>&1 || return 1
  debugfs -w -R "write $public_key /root/.ssh/authorized_keys" "$rootfs" >/dev/null 2>&1 || return 1
  debugfs -w -R 'rm /etc/ssh/sshd_config.d/iclaude.conf' "$rootfs" >/dev/null 2>&1 || return 1
  debugfs -w -R "write $sshd_policy /etc/ssh/sshd_config.d/iclaude.conf" "$rootfs" >/dev/null 2>&1 || return 1
  rm -f "$sshd_policy"
  [[ -z "$base_sha256" ]] || _ihar_microvm_rootfs_lineage_write "$rootfs" "$base_sha256"
}

_ihar_microvm_quote_argv() {
  local vendor="$1" runtime="$2" item guest index=0
  printf 'exec'
  for item in "${IHAR_ARGV[@]}"; do
    if (( index == 0 )); then
      guest="/mnt/ihar/bin/$vendor"
    else
      guest="${item//$runtime//mnt/ihar/runtime/$vendor}"
    fi
    printf ' %q' "$guest"
    index=$((index + 1))
  done
  printf '\n'
}

_ihar_microvm_rewrite_runtime_links() {
  local root="$1" link target relative
  while IFS= read -r -d '' link; do
    # Codex auth is staged on the writable state drive under a global owner.
    [[ "$link" == "$root/runtime/codex/auth.json" ]] && continue
    target="$(readlink -f "$link")"
    if [[ "$target" == "$IHAR_STATE/st/"* ]]; then
      relative="${target#"$IHAR_STATE/st/"}"
      rm "$link" && ln -s "/mnt/ihar-state/st/$relative" "$link"
    elif [[ "$target" == "$IHAR_STORE/"* ]]; then
      relative="${target#"$IHAR_STORE/"}"
      mkdir -p "$root/store/$(dirname "$relative")"
      cp -RL "$target" "$root/store/$relative"
      rm "$link" && ln -s "/mnt/ihar/store/$relative" "$link"
    fi
  done < <(find "$root/runtime" -type l -print0)
}

_ihar_microvm_stage_guest_auth() { # <policy-bundle> <state-seed> <canonical>
  local bundle="$1" state_seed="$2" canonical="$3"
  local link="$bundle/runtime/codex/auth.json" target="$state_seed/.ihar-guest-codex-home/auth.json"
  local entry name
  [[ -L "$link" && "$(readlink "$link")" == "$canonical" ]] || return 1
  [[ ! -e "$(dirname "$target")" && ! -L "$(dirname "$target")" ]] || return 1
  mkdir -m 700 "$(dirname "$target")" || return 1
  chmod 700 "$state_seed" || return 1
  ( umask 077; cp -L -- "$canonical" "$target" ) || return 1
  chmod 600 "$target" || return 1
  for entry in "$bundle/runtime/codex"/* "$bundle/runtime/codex"/.[!.]* "$bundle/runtime/codex"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="${entry##*/}"
    [[ "$name" == auth.json ]] && continue
    ln -s "/mnt/ihar/runtime/codex/$name" "$(dirname "$target")/$name" || return 1
  done
  rm -- "$link" || return 1
  ln -s /mnt/ihar-state/.ihar-guest-codex-home/auth.json "$link"
}

_ihar_microvm_extract_guest_auth() { # <state-image> <private-bundle>
  local image="$1" bundle="$2" metadata temporary
  metadata="$(debugfs -R 'stat /.ihar-guest-codex-home/auth.json' "$image" 2>/dev/null)" || return 1
  grep -q 'Type: regular' <<< "$metadata" || return 1
  temporary="$(mktemp "$bundle/.auth-return-XXXXXX")" || return 1
  if ! debugfs -R "dump /.ihar-guest-codex-home/auth.json $temporary" "$image" >/dev/null 2>&1; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 600 "$temporary" || return 1
  ihar_python ihar.codex.auth_owner guest-commit-candidate "$bundle" "$temporary"
}

_ihar_microvm_image_auth_matches() { # <state-image> <seed-auth> <private-bundle>
  local image="$1" seed="$2" bundle="$3" metadata temporary result=1
  metadata="$(debugfs -R 'stat /.ihar-guest-codex-home/auth.json' "$image" 2>/dev/null)" || return 1
  grep -q 'Type: regular' <<< "$metadata" || return 1
  temporary="$(mktemp "$bundle/.auth-seed-check-XXXXXX")" || return 1
  if debugfs -R "dump /.ihar-guest-codex-home/auth.json $temporary" "$image" >/dev/null 2>&1 \
      && cmp -s -- "$seed" "$temporary"; then
    result=0
  fi
  rm -f -- "$temporary"
  return "$result"
}

_ihar_microvm_translate_bundle_paths() {
  python3 - "$1" "$IHAR_PROJECT_ROOT" "$IHAR_STATE" "$IHAR_STORE" <<'PY'
import pathlib, stat, sys
root = pathlib.Path(sys.argv[1])
replacements = (
    (sys.argv[2].encode(), b"/workspace"),
    (sys.argv[3].encode(), b"/mnt/ihar-state"),
    (sys.argv[4].encode(), b"/mnt/ihar/store"),
)
for path in root.rglob("*"):
    if not path.is_file() or path.is_symlink():
        continue
    data = path.read_bytes()
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        continue
    changed = data
    for old, new in replacements:
        changed = changed.replace(old, new)
    if changed != data:
        path.chmod(path.stat().st_mode | stat.S_IWUSR)
        path.write_bytes(changed)
PY
}

# ihar_microvm_launch <vendor> <runtime> — owns VM, network and exact cleanup.
ihar_microvm_launch() {
  local vendor="$1" runtime="$2"
  ihar_microvm_preflight

  local session tap
  mkdir -p "$IHAR_STATE_ROOT/microvm" \
    || ihar_die 3 "cannot create microVM session parent"
  [[ ! -L "$IHAR_STATE_ROOT/microvm" ]] \
    || ihar_die 3 "microVM session parent is unsafe"
  session="$(mktemp -d "$IHAR_STATE_ROOT/microvm/${IHAR_LAUNCH_ID:-$$}.XXXXXX")" \
    || ihar_die 3 "cannot create microVM session directory"
  local codex_runtime="$runtime" guest_owner_id="" guest_owner_file="$session/guest-owner-id" old_umask
  [[ "$vendor" == codex ]] || codex_runtime="${IHAR_OTHER_RUNTIME:?Codex guest runtime is absent}"
  old_umask="$(umask)"
  umask 077
  local guest_vm_started=false early_cleanup_done=false
  _ihar_microvm_early_cleanup() {
    [[ "$early_cleanup_done" != true ]] || return 0
    early_cleanup_done=true
    if [[ "$guest_vm_started" != true ]]; then
      if [[ -z "$guest_owner_id" && -f "$guest_owner_file" ]]; then
        IFS= read -r guest_owner_id < "$guest_owner_file" || true
      fi
      if [[ "$guest_owner_id" =~ ^[a-f0-9]{32}$ ]]; then
        ihar_codex_guest_owner abort "$guest_owner_id" >/dev/null 2>&1 || true
      fi
    fi
    ihar_microvm_release_slot
    ihar_launch_state_leave
    ihar_gateway_release
  }
  trap _ihar_microvm_early_cleanup EXIT
  trap '_ihar_microvm_early_cleanup; exit 130' INT TERM
  ihar_codex_guest_owner acquire "$codex_runtime" "$guest_owner_file" \
    || ihar_die 3 "Codex guest credential owner is unavailable"
  umask "$old_umask"
  IFS= read -r guest_owner_id < "$guest_owner_file" \
    || ihar_die 3 "Codex guest credential owner handoff is unavailable"
  [[ "$guest_owner_id" =~ ^[a-f0-9]{32}$ ]] \
    || ihar_die 3 "Codex guest credential owner handoff is invalid"
  ihar_microvm_reserve_slot
  tap="$IHAR_MICROVM_TAP"

  local rootfs="$session/rootfs.ext4" workspace="$session/workspace.ext4"
  local policy="$session/policy.ext4" state_img="$session/state.ext4"
  local state_seed="$session/state-seed" guest_auth_bundle="$session/guest-auth"
  cp --sparse=always "$IHAR_STORE/bin/rootfs.ext4" "$rootfs" \
    || ihar_die 3 "cannot copy the microVM rootfs"
  local rootfs_base_sha256
  rootfs_base_sha256="$(ihar_lockfile_get microvm.rootfs)"
  _ihar_microvm_prepare_rootfs "$rootfs" "$rootfs_base_sha256" \
    || ihar_die 3 "cannot install the client key in the microVM rootfs copy"
  _ihar_microvm_make_image "$workspace" "$IHAR_PROJECT_ROOT" "${IHAR_MICROVM_WORKSPACE_MB:-2048}" \
    || ihar_die 3 "cannot build the writable workspace image"
  mkdir -m 700 "$state_seed" "$guest_auth_bundle" \
    || ihar_die 3 "cannot create private guest credential bundle"
  cp -a "$IHAR_STATE"/. "$state_seed"/ \
    || ihar_die 3 "cannot stage writable vendor state"

  local bundle="$session/bundle"
  mkdir -p "$bundle/bin" "$bundle/runtime/claude" "$bundle/runtime/codex" "$bundle/state" "$bundle/policy"
  cp -L "$IHAR_CLAUDE_BIN" "$bundle/bin/claude" \
    || ihar_die 3 "cannot stage the Claude binary"
  cp -L "$IHAR_CODEX_BIN" "$bundle/bin/codex" \
    || ihar_die 3 "cannot stage the Codex binary"
  cp -a "$runtime"/. "$bundle/runtime/$vendor"/ || ihar_die 3 "cannot stage the runtime home"
  local other_vendor=claude
  [[ "$vendor" == claude ]] && other_vendor=codex
  [[ -n "${IHAR_OTHER_RUNTIME:-}" && -d "$IHAR_OTHER_RUNTIME" ]] \
    || ihar_die 3 "the $other_vendor runtime home was not materialised for the microVM"
  cp -a "$IHAR_OTHER_RUNTIME"/. "$bundle/runtime/$other_vendor"/ \
    || ihar_die 3 "cannot stage the $other_vendor runtime home"
  cp -RL "$IHAR_STORE/manifests" "$bundle/policy/manifests" \
    || ihar_die 3 "cannot stage the policy bundle"
  _ihar_microvm_rewrite_runtime_links "$bundle" || ihar_die 3 "cannot rewrite guest runtime links"
  _ihar_microvm_stage_guest_auth "$bundle" "$state_seed" "$IHAR_STORE/auth/codex/auth.json" \
    || ihar_die 3 "cannot stage private Codex guest credential"
  _ihar_microvm_translate_bundle_paths "$bundle" || ihar_die 3 "cannot translate guest configuration paths"
  local state_mib=$(( $(du -sm "$state_seed" | awk '{print $1}') + 64 ))
  _ihar_microvm_make_image "$state_img" "$state_seed" "$state_mib" \
    || ihar_die 3 "cannot build the writable vendor state image"
  _ihar_microvm_image_auth_matches "$state_img" "$state_seed/.ihar-guest-codex-home/auth.json" \
    "$guest_auth_bundle" || ihar_die 3 "Codex guest credential image differs from private seed"
  ihar_codex_guest_owner register "$guest_owner_id" "$guest_auth_bundle" "$state_img" \
    "$state_seed/.ihar-guest-codex-home/auth.json" \
    || ihar_die 3 "cannot register Codex guest bundle"
  local size_mib=$(( $(du -sm "$bundle" | awk '{print $1}') + 64 ))
  _ihar_microvm_make_image "$policy" "$bundle" "$size_mib" \
    || ihar_die 3 "cannot build the read-only policy image"

  local resolved_egress
  resolved_egress="$(_ihar_microvm_collect_egress)" \
    || ihar_die 3 "cannot resolve the isolated profile's declared MCP destinations"
  IHAR_MICROVM_MCP_EGRESS="$(cut -d'|' -f1 <<< "$resolved_egress")"
  export IHAR_MICROVM_MCP_EGRESS
  sudo -n ip tuntap add dev "$tap" mode tap user "$(id -u)" \
    || ihar_die 3 "cannot create isolated TAP $tap"
  local pid="" socket="/tmp/ihar-${IHAR_LAUNCH_ID:-$$}.sock"
  _ihar_microvm_cleanup() {
    ihar_microvm_network_evidence_remove
    [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
    [[ -z "$pid" ]] || wait "$pid" 2>/dev/null || true
    ihar_microvm_network_remove
    sudo -n ip link del "$tap" 2>/dev/null || true
    rm -f "$socket"
    _ihar_microvm_early_cleanup
  }
  # shellcheck disable=SC2317
  trap _ihar_microvm_cleanup EXIT
  trap '_ihar_microvm_cleanup; exit 130' INT TERM
  if ! sudo -n ip addr add "$IHAR_MICROVM_HOST_IP/30" dev "$tap" \
      || ! sudo -n ip link set "$tap" up; then
    sudo -n ip link del "$tap" 2>/dev/null || true
    ihar_die 3 "cannot configure isolated TAP $tap"
  fi
  ihar_microvm_network_apply \
    || { ihar_microvm_network_remove; sudo -n ip link del "$tap" 2>/dev/null || true; ihar_die 3 "cannot enforce isolated guest network policy"; }

  local config manifest log="$session/firecracker.log"
  config="$(ihar_microvm_write_config "$session" "$tap" "$IHAR_MICROVM_GUEST_IP" "$rootfs" "$policy" "$workspace" "$state_img")"
  manifest="$(ihar_microvm_launch_manifest_write "$config")" \
    || ihar_die 3 "cannot capture the microVM prelaunch manifest"
  : > "$log"
  ihar_codex_guest_owner starting "$guest_owner_id" \
    || ihar_die 3 "cannot mark Codex guest start boundary"
  guest_vm_started=true
  setsid "$IHAR_STORE/bin/firecracker" --api-sock "$socket" --config-file "$config" --log-path "$log" --level Warn \
    >> "$session/console.log" 2>&1 &
  pid=$!
  local vm_pgrp="" group_ticks=0
  while [[ "$vm_pgrp" != "$pid" ]]; do
    vm_pgrp="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
    (( group_ticks++ < 40 )) || ihar_die 3 "Codex guest VM process group cannot be verified"
    sleep 0.05
  done
  ihar_codex_guest_owner bind-vm "$guest_owner_id" "$pid" "$IHAR_STORE/bin/firecracker" \
    || ihar_die 3 "cannot bind Codex guest VM identity"
  local key="${IHAR_MICROVM_SSH_KEY:-$IHAR_STORE/microvm/current/client_key}" ticks=0 ssh_user=root
  local known_hosts="$session/known_hosts"
  { printf '%s ' "$IHAR_MICROVM_GUEST_IP"; cat "$IHAR_STORE/microvm/current/host_key.pub"; } > "$known_hosts"
  while ! ssh -i "$key" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" \
      -o BatchMode=yes -o ConnectTimeout=1 "$ssh_user@$IHAR_MICROVM_GUEST_IP" true 2>/dev/null; do
    kill -0 "$pid" 2>/dev/null || ihar_die 3 "microVM boot failed; see $log"
    (( ticks++ < 60 )) || ihar_die 3 "microVM guest did not become ready"
    sleep 0.5
  done
  ihar_microvm_network_evidence_write "$pid" "$config" "$manifest" \
    || ihar_die 3 "cannot publish observed microVM network evidence"

  local env_file="$session/guest-env.sh" guest_script="$session/guest-run.sh" command
  ihar_microvm_write_guest_env "$env_file" "$vendor" "/mnt/ihar/runtime/$vendor"
  command="$(_ihar_microvm_quote_argv "$vendor" "$runtime")"
  cp "$env_file" "$guest_script"
  {
    printf 'set -euo pipefail\n'
    printf 'mkdir -p /mnt/ihar /mnt/ihar-state\n'
    printf 'mount -o ro /dev/vdb /mnt/ihar\n'
    printf 'mount /dev/vdd /mnt/ihar-state\n'
    printf 'mountpoint -q /mnt/ihar && mountpoint -q /mnt/ihar-state\n'
    while IFS='|' read -r destination hostname; do
      [[ -n "$hostname" ]] || continue
      printf "printf '%%s %%s\\n' %q %q >> /etc/hosts\n" "${destination%:*}" "$hostname"
    done <<< "$resolved_egress"
    printf 'cd /workspace\n'
    printf 'test -x /mnt/ihar/bin/%q\n' "$vendor"
    printf '%s\n' "$command"
  } >> "$guest_script"
  local status=0 remote_script="/tmp/ihar-${IHAR_LAUNCH_ID:-$$}.sh"
  scp -q -i "$key" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" \
    "$guest_script" "$ssh_user@$IHAR_MICROVM_GUEST_IP:$remote_script" \
    || ihar_die 3 "cannot stage the fail-closed guest launcher"
  ssh -tt -i "$key" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" \
    "$ssh_user@$IHAR_MICROVM_GUEST_IP" \
    "/bin/bash -c '/bin/bash $remote_script; status=\$?; rm -f $remote_script; exit \$status'" \
    || status=$?
  rsync -a --delete -e "ssh -i $key -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts" \
    "$ssh_user@$IHAR_MICROVM_GUEST_IP:/workspace/" "$IHAR_PROJECT_ROOT/" \
    || ihar_die 3 "cannot persist the isolated workspace"
  rsync -a --delete --exclude='/.ihar-guest-codex-home/' -e "ssh -i $key -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts" \
    "$ssh_user@$IHAR_MICROVM_GUEST_IP:/mnt/ihar-state/" "$IHAR_STATE/" \
    || ihar_die 3 "cannot persist isolated vendor state"
  ssh -i "$key" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" \
    "$ssh_user@$IHAR_MICROVM_GUEST_IP" sync >/dev/null 2>&1 \
    || ihar_die 3 "cannot flush isolated guest state"
  ssh -i "$key" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" \
    "$ssh_user@$IHAR_MICROVM_GUEST_IP" poweroff >/dev/null 2>&1 || true
  local shutdown_ticks=0 vm_state
  while [[ -e "/proc/$pid/stat" ]]; do
    vm_state="$(sed -E 's/^.*\) ([A-Z]).*/\1/' "/proc/$pid/stat" 2>/dev/null)" || break
    [[ "$vm_state" == Z ]] && break
    (( shutdown_ticks++ < 100 )) || ihar_die 3 "Codex guest shutdown cannot be verified; credential bundle retained"
    sleep 0.1
  done
  wait "$pid" 2>/dev/null || true
  pid=""
  ihar_codex_guest_owner quiescent "$guest_owner_id" \
    || ihar_die 3 "Codex guest quiescence cannot be verified; credential bundle retained"
  _ihar_microvm_extract_guest_auth "$state_img" "$guest_auth_bundle" \
    || ihar_die 3 "Codex guest credential cannot be extracted; state image retained"
  ihar_codex_guest_owner publish "$guest_owner_id" "$guest_auth_bundle" \
    || ihar_die 3 "Codex guest credential cannot be reconciled; bundle retained"
  ihar_codex_guest_owner release "$guest_owner_id" "$codex_runtime" \
    || ihar_die 3 "Codex guest owner release cannot be verified"
  _ihar_microvm_cleanup; trap - EXIT INT TERM; return "$status"
}
