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
export CODEX_HOME='/mnt/ihar/runtime/codex'
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
  local rootfs="$1" public_key="$IHAR_STORE/microvm/current/client_key.pub"
  local sshd_policy="${rootfs}.sshd-policy"
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

  local session="$IHAR_STATE_ROOT/microvm/${IHAR_LAUNCH_ID:-$$}" tap
  mkdir -p "$session" && chmod 700 "$session" \
    || ihar_die 3 "cannot create microVM session directory"
  ihar_microvm_reserve_slot
  tap="$IHAR_MICROVM_TAP"

  local rootfs="$session/rootfs.ext4" workspace="$session/workspace.ext4"
  local policy="$session/policy.ext4" state_img="$session/state.ext4"
  cp --sparse=always "$IHAR_STORE/bin/rootfs.ext4" "$rootfs" \
    || ihar_die 3 "cannot copy the microVM rootfs"
  _ihar_microvm_prepare_rootfs "$rootfs" \
    || ihar_die 3 "cannot install the client key in the microVM rootfs copy"
  _ihar_microvm_make_image "$workspace" "$IHAR_PROJECT_ROOT" "${IHAR_MICROVM_WORKSPACE_MB:-2048}" \
    || ihar_die 3 "cannot build the writable workspace image"
  local state_mib=$(( $(du -sm "$IHAR_STATE" | awk '{print $1}') + 64 ))
  _ihar_microvm_make_image "$state_img" "$IHAR_STATE" "$state_mib" \
    || ihar_die 3 "cannot build the writable vendor state image"

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
  _ihar_microvm_translate_bundle_paths "$bundle" || ihar_die 3 "cannot translate guest configuration paths"
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
    [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
    [[ -z "$pid" ]] || wait "$pid" 2>/dev/null || true
    ihar_microvm_network_remove
    sudo -n ip link del "$tap" 2>/dev/null || true
    rm -f "$socket"
    ihar_microvm_release_slot
    ihar_launch_state_leave
    ihar_gateway_release
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

  local config log="$session/firecracker.log"
  config="$(ihar_microvm_write_config "$session" "$tap" "$IHAR_MICROVM_GUEST_IP" "$rootfs" "$policy" "$workspace" "$state_img")"
  : > "$log"
  "$IHAR_STORE/bin/firecracker" --api-sock "$socket" --config-file "$config" --log-path "$log" --level Warn \
    >> "$session/console.log" 2>&1 &
  pid=$!
  local key="${IHAR_MICROVM_SSH_KEY:-$IHAR_STORE/microvm/current/client_key}" ticks=0 ssh_user=root
  local known_hosts="$session/known_hosts"
  { printf '%s ' "$IHAR_MICROVM_GUEST_IP"; cat "$IHAR_STORE/microvm/current/host_key.pub"; } > "$known_hosts"
  while ! ssh -i "$key" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" \
      -o BatchMode=yes -o ConnectTimeout=1 "$ssh_user@$IHAR_MICROVM_GUEST_IP" true 2>/dev/null; do
    kill -0 "$pid" 2>/dev/null || ihar_die 3 "microVM boot failed; see $log"
    (( ticks++ < 60 )) || ihar_die 3 "microVM guest did not become ready"
    sleep 0.5
  done

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
  rsync -a --delete -e "ssh -i $key -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts" \
    "$ssh_user@$IHAR_MICROVM_GUEST_IP:/mnt/ihar-state/" "$IHAR_STATE/" \
    || ihar_die 3 "cannot persist isolated vendor state"
  _ihar_microvm_cleanup; trap - EXIT INT TERM; return "$status"
}
