#!/usr/bin/env bash
# Cross-component concurrency invariants use explicit entry/release markers. Sleeps
# bound waits only; no passing assertion depends on elapsed time.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
export IHAR_ROOT="$ROOT" PYTHONPATH="$ROOT/lib/python"

BG_PIDS=()
cleanup() {
  local pid
  for pid in "${BG_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$IHAR_TEST_TMP"
}
trap cleanup EXIT

wait_for_file() { # <path>
  local path="$1" attempt=0
  while [[ ! -e "$path" && "$attempt" -lt 500 ]]; do
    sleep 0.01
    attempt=$((attempt + 1))
  done
  [[ -e "$path" ]]
}

tree_hash() { # <directory>
  find "$1" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
}

# --- two profile publications overlap but never share or rewrite a runtime -----------

RUNTIME_STATE="$IHAR_TEST_TMP/runtime-state"
mkdir -p "$RUNTIME_STATE/r" "$IHAR_TEST_TMP/render-standard" "$IHAR_TEST_TMP/render-protected"
printf 'standard\n' > "$IHAR_TEST_TMP/render-standard/settings.json"
printf 'protected\n' > "$IHAR_TEST_TMP/render-protected/settings.json"

REAL_CP="$(command -v cp)"
REAL_FLOCK="$(command -v flock)"
mkdir -p "$IHAR_TEST_TMP/barrier-bin" "$IHAR_TEST_TMP/runtime-barrier"
cat > "$IHAR_TEST_TMP/barrier-bin/cp" <<'SH'
#!/usr/bin/env bash
touch "$IHAR_BARRIER_ROOT/$IHAR_BARRIER_LABEL.entered"
while [[ ! -e "$IHAR_BARRIER_ROOT/$IHAR_BARRIER_LABEL.release" ]]; do sleep 0.01; done
exec "$IHAR_REAL_CP" "$@"
SH
chmod +x "$IHAR_TEST_TMP/barrier-bin/cp"
cat > "$IHAR_TEST_TMP/barrier-bin/flock" <<'SH'
#!/usr/bin/env bash
touch "$IHAR_FLOCK_ACK"
exec "$IHAR_REAL_FLOCK" "$@"
SH
chmod +x "$IHAR_TEST_TMP/barrier-bin/flock"

cat > "$IHAR_TEST_TMP/runtime-worker.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$IHAR_ROOT/lib/core/logging.sh"
source "$IHAR_ROOT/lib/core/init.sh"
source "$IHAR_ROOT/lib/core/lock.sh"
ihar_link_runtime() { :; }
ihar_verify_runtime_state_links() { :; }
source "$IHAR_ROOT/lib/state/runtime.sh"
export IHAR_STATE="$1" IHAR_PROFILE="$2"
ihar_runtime_materialise claude "$3" "$4" writable > "$5"
SH
chmod +x "$IHAR_TEST_TMP/runtime-worker.sh"

PATH="$IHAR_TEST_TMP/barrier-bin:$PATH" IHAR_REAL_CP="$REAL_CP" IHAR_REAL_FLOCK="$REAL_FLOCK" \
  IHAR_FLOCK_ACK="$IHAR_TEST_TMP/runtime-barrier/standard.flock" \
  IHAR_BARRIER_ROOT="$IHAR_TEST_TMP/runtime-barrier" IHAR_BARRIER_LABEL=standard \
  "$IHAR_TEST_TMP/runtime-worker.sh" "$RUNTIME_STATE" standard 11111111 \
    "$IHAR_TEST_TMP/render-standard" "$IHAR_TEST_TMP/standard.runtime" &
BG_PIDS+=("$!")
assert_exit "standard invokes the production state flock" 0 \
  wait_for_file "$IHAR_TEST_TMP/runtime-barrier/standard.flock"
assert_exit "standard render reaches its publication barrier" 0 \
  wait_for_file "$IHAR_TEST_TMP/runtime-barrier/standard.entered"

PATH="$IHAR_TEST_TMP/barrier-bin:$PATH" IHAR_REAL_CP="$REAL_CP" IHAR_REAL_FLOCK="$REAL_FLOCK" \
  IHAR_FLOCK_ACK="$IHAR_TEST_TMP/runtime-barrier/protected.flock" \
  IHAR_BARRIER_ROOT="$IHAR_TEST_TMP/runtime-barrier" IHAR_BARRIER_LABEL=protected \
  "$IHAR_TEST_TMP/runtime-worker.sh" "$RUNTIME_STATE" protected 22222222 \
    "$IHAR_TEST_TMP/render-protected" "$IHAR_TEST_TMP/protected.runtime" &
BG_PIDS+=("$!")
assert_exit "protected invokes the production state flock while standard is paused" 0 \
  wait_for_file "$IHAR_TEST_TMP/runtime-barrier/protected.flock"
assert_exit "protected cannot enter publication while standard owns the state lock" 1 \
  test -e "$IHAR_TEST_TMP/runtime-barrier/protected.entered"
assert_exit "protected cannot publish while standard owns the state lock" 1 \
  test -s "$IHAR_TEST_TMP/protected.runtime"
touch "$IHAR_TEST_TMP/runtime-barrier/standard.release"
assert_exit "protected reaches publication after standard releases" 0 \
  wait_for_file "$IHAR_TEST_TMP/runtime-barrier/protected.entered"
assert_exit "standard publication is visible before protected is released" 0 \
  test -s "$IHAR_TEST_TMP/standard.runtime"
touch "$IHAR_TEST_TMP/runtime-barrier/protected.release"
wait "${BG_PIDS[0]}" "${BG_PIDS[1]}"

standard_runtime="$(cat "$IHAR_TEST_TMP/standard.runtime")"
protected_runtime="$(cat "$IHAR_TEST_TMP/protected.runtime")"
assert_exit "different profiles publish distinct runtime homes" 1 \
  test "$standard_runtime" = "$protected_runtime"
standard_before="$(tree_hash "$standard_runtime")"
protected_before="$(tree_hash "$protected_runtime")"
PATH="$IHAR_TEST_TMP/barrier-bin:$PATH" IHAR_REAL_CP="$REAL_CP" \
  IHAR_REAL_FLOCK="$REAL_FLOCK" \
  IHAR_FLOCK_ACK="$IHAR_TEST_TMP/runtime-barrier/standard-reuse.flock" \
  IHAR_BARRIER_ROOT="$IHAR_TEST_TMP/runtime-barrier" IHAR_BARRIER_LABEL=standard \
  "$IHAR_TEST_TMP/runtime-worker.sh" "$RUNTIME_STATE" standard 11111111 \
    "$IHAR_TEST_TMP/render-standard" "$IHAR_TEST_TMP/standard-again.runtime"
assert_eq "standard runtime stays unchanged after publication" "$standard_before" \
  "$(tree_hash "$standard_runtime")"
assert_eq "protected runtime stays unchanged after the other reuse" "$protected_before" \
  "$(tree_hash "$protected_runtime")"

# --- parallel install entrants serialize on the required store lock ------------------

cat > "$IHAR_TEST_TMP/lock-worker.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$IHAR_ROOT/lib/core/logging.sh"
source "$IHAR_ROOT/lib/core/init.sh"
source "$IHAR_ROOT/lib/core/lock.sh"
id="$1"; root="$2"
export IHAR_STORE="$3" IHAR_NVM="$3-nvm"
source "$IHAR_ROOT/lib/store/install.sh"
_ihar_install_all() {
  printf '%s\n' "$id" >> "$root/order"
  touch "$root/$id.entered"
  while [[ ! -e "$root/$id.release" ]]; do sleep 0.01; done
}
ihar_cmd_install
touch "$root/$id.done"
SH
chmod +x "$IHAR_TEST_TMP/lock-worker.sh"
LOCK_BARRIER="$IHAR_TEST_TMP/store-barrier"
mkdir -p "$LOCK_BARRIER"
PATH="$IHAR_TEST_TMP/barrier-bin:$PATH" IHAR_REAL_FLOCK="$REAL_FLOCK" \
  IHAR_FLOCK_ACK="$LOCK_BARRIER/one.flock" \
  "$IHAR_TEST_TMP/lock-worker.sh" one "$LOCK_BARRIER" "$IHAR_STORE" & BG_PIDS+=("$!")
assert_exit "first install invokes the production store flock" 0 \
  wait_for_file "$LOCK_BARRIER/one.flock"
assert_exit "first install enters the store lock" 0 wait_for_file "$LOCK_BARRIER/one.entered"
PATH="$IHAR_TEST_TMP/barrier-bin:$PATH" IHAR_REAL_FLOCK="$REAL_FLOCK" \
  IHAR_FLOCK_ACK="$LOCK_BARRIER/two.flock" \
  "$IHAR_TEST_TMP/lock-worker.sh" two "$LOCK_BARRIER" "$IHAR_STORE" & BG_PIDS+=("$!")
assert_exit "second install invokes the production store flock while first is paused" 0 \
  wait_for_file "$LOCK_BARRIER/two.flock"
assert_exit "second install cannot enter while first holds the lock" 1 \
  test -e "$LOCK_BARRIER/two.entered"
touch "$LOCK_BARRIER/one.release"
assert_exit "second install enters after first releases" 0 wait_for_file "$LOCK_BARRIER/two.entered"
assert_eq "store-lock entry order is observable" $'one\ntwo' "$(cat "$LOCK_BARRIER/order")"
touch "$LOCK_BARRIER/two.release"
assert_exit "both serialized installs leave the lock" 0 wait_for_file "$LOCK_BARRIER/two.done"

# --- gateway identity and refcount retention -----------------------------------------

cat > "$IHAR_TEST_TMP/gateway-worker.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$IHAR_ROOT/lib/core/logging.sh"
source "$IHAR_ROOT/lib/core/init.sh"
source "$IHAR_ROOT/lib/core/lock.sh"
source "$IHAR_ROOT/lib/gateway/gateway.sh"
name="$1"; level="$2"; root="$3"
export IHAR_PROFILE=protected IHAR_PROFILE_GATEWAY=explicit
export IHAR_PROFILE_HOOKS=best-effort IHAR_GATEWAY_MASKING_LEVEL="$level"
export IHAR_GATEWAY_ENGINE=regex
ihar_gateway_acquire
dir="$IHAR_STATE_ROOT/gw/$IHAR_GATEWAY_KEY"
printf '%s %s %s\n' "$IHAR_GATEWAY_KEY" "$(cat "$dir/pid")" "$(cat "$dir/port")" > "$root/$name.result"
touch "$root/$name.ready"
while [[ ! -e "$root/$name.release" ]]; do sleep 0.01; done
ihar_gateway_release
touch "$root/$name.done"
SH
chmod +x "$IHAR_TEST_TMP/gateway-worker.sh"

GATEWAY_BARRIER="$IHAR_TEST_TMP/gateway-barrier"
mkdir -p "$GATEWAY_BARRIER"
"$IHAR_TEST_TMP/gateway-worker.sh" standard standard "$GATEWAY_BARRIER" & BG_PIDS+=("$!")
"$IHAR_TEST_TMP/gateway-worker.sh" secrets secrets "$GATEWAY_BARRIER" & BG_PIDS+=("$!")
assert_exit "standard gateway client acquires an instance" 0 wait_for_file "$GATEWAY_BARRIER/standard.ready"
assert_exit "secrets gateway client acquires an instance" 0 wait_for_file "$GATEWAY_BARRIER/secrets.ready"
read -r standard_key standard_pid standard_port < "$GATEWAY_BARRIER/standard.result"
read -r secrets_key secrets_pid secrets_port < "$GATEWAY_BARRIER/secrets.result"
assert_exit "different masking levels use different gateway keys" 1 \
  test "$standard_key" = "$secrets_key"
assert_exit "different masking levels use different gateway processes" 1 \
  test "$standard_pid" = "$secrets_pid"
touch "$GATEWAY_BARRIER/standard.release" "$GATEWAY_BARRIER/secrets.release"
assert_exit "separate gateway clients release cleanly" 0 wait_for_file "$GATEWAY_BARRIER/secrets.done"

"$IHAR_TEST_TMP/gateway-worker.sh" consumer-one standard "$GATEWAY_BARRIER" & BG_PIDS+=("$!")
assert_exit "first shared consumer acquires an instance" 0 wait_for_file "$GATEWAY_BARRIER/consumer-one.ready"
"$IHAR_TEST_TMP/gateway-worker.sh" consumer-two standard "$GATEWAY_BARRIER" & BG_PIDS+=("$!")
assert_exit "second shared consumer attaches" 0 wait_for_file "$GATEWAY_BARRIER/consumer-two.ready"
read -r shared_key shared_pid shared_port < "$GATEWAY_BARRIER/consumer-one.result"
read -r attached_key attached_pid attached_port < "$GATEWAY_BARRIER/consumer-two.result"
assert_eq "same gateway configuration shares one key" "$shared_key" "$attached_key"
assert_eq "same gateway configuration shares one process" "$shared_pid" "$attached_pid"
assert_eq "same gateway configuration shares one endpoint" "$shared_port" "$attached_port"

touch "$GATEWAY_BARRIER/consumer-one.release"
assert_exit "first consumer release completes" 0 wait_for_file "$GATEWAY_BARRIER/consumer-one.done"
shared_dir="$IHAR_STATE_ROOT/gw/$shared_key"
assert_exit "shared gateway remains live for second consumer" 0 kill -0 "$shared_pid"
assert_exit "shared gateway pid remains published" 0 test -s "$shared_dir/pid"
assert_exit "shared gateway endpoint answers after the first release" 0 \
  env PYTHONPATH="$ROOT/lib/python" python3 -m ihar.gateway.probe "$shared_port"

touch "$GATEWAY_BARRIER/consumer-two.release"
assert_exit "last consumer release completes" 0 wait_for_file "$GATEWAY_BARRIER/consumer-two.done"
assert_exit "last release removes the live pid marker" 1 test -e "$shared_dir/pid"

finish
