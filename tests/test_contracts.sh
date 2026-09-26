#!/usr/bin/env bash
# S0 gate G0: every shipped profile and network policy validates, and the guarantee
# text each profile prints is data rather than prose buried in code.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
export PYTHONPATH="$ROOT/lib/python"

py() { python3 -c "$1" "${@:2}"; }

# --- every shipped contract file validates -------------------------------------

for file in "$ROOT"/manifests/profiles/*.json; do
  assert_exit "profile $(basename "$file") validates" 0 \
    py 'import sys; from ihar import jsonio; jsonio.read("profile", sys.argv[1])' "$file"
done

for file in "$ROOT"/manifests/netpolicy/*.json; do
  assert_exit "netpolicy $(basename "$file") validates" 0 \
    py 'import sys; from ihar import jsonio; jsonio.read("netpolicy", sys.argv[1])' "$file"
done

# --- only the profiles whose gates passed are shipped ----------------------------

for name in standard protected isolated; do
  assert_exit "profile $name is shipped" 0 test -f "$ROOT/manifests/profiles/$name.json"
done
assert_exit "the failed transparent spike drops remote-protected" 1 \
  test -e "$ROOT/manifests/profiles/remote-protected.json"

# --- guarantee text is data, non-empty, and names the profile's scope ------------

guarantees="$(py '
import glob, json, sys
for path in sorted(glob.glob(sys.argv[1] + "/manifests/profiles/*.json")):
    obj = json.load(open(path))
    print(obj["name"], "::", obj["guarantee"])
' "$ROOT")"

assert_contains "standard states it guarantees nothing" "$guarantees" "standard :: No guarantee."
assert_contains "protected scopes its claim to model egress" "$guarantees" "protected :: Model egress:"
assert_contains "isolated scopes its claim to machine egress" "$guarantees" "isolated :: Machine egress:"
assert_contains "protected says other egress is uncontrolled" "$guarantees" \
  "Other tool network egress is not controlled"

# --- every netpolicy a profile names exists -------------------------------------

missing="$(py '
import glob, json, os, sys
root = sys.argv[1]
for path in sorted(glob.glob(root + "/manifests/profiles/*.json")):
    obj = json.load(open(path))
    policy = obj["netpolicy"]
    if policy and not os.path.exists(f"{root}/manifests/netpolicy/{policy}.json"):
        print(f"{obj['name']} -> {policy}")
' "$ROOT")"
assert_eq "every named netpolicy exists" "" "$missing"

# --- semantic rules reject the configurations the LLD forbids --------------------

# A rejection exits 7, never 1. Python exits 1 for an uncaught exception, an import
# failure and a syntax error in the interpolated literal, so asserting 1 would let a
# crashing validator report PASS. Only a SchemaError reaches 7.
reject() { # <desc> <kind> <python dict literal>
  local desc="$1" kind="$2" doc="$3"
  assert_exit "$desc" 7 py "
import sys
from ihar import jsonio
try:
    jsonio.check(sys.argv[1], $doc)
except jsonio.SchemaError:
    sys.exit(7)
sys.exit(0)
" "$kind"
}

accept() { # <desc> <kind> <python dict literal>
  local desc="$1" kind="$2" doc="$3"
  assert_exit "$desc" 0 py "
import sys
from ihar import jsonio
jsonio.check(sys.argv[1], $doc)
" "$kind"
}

# The rejection helper must itself fail on a crash rather than pass.
assert_exit "a crashing snippet is not mistaken for a rejection" 1 py "
import sys
from ihar import jsonio
raise RuntimeError('boom')
"

base='{"schema":1,"name":"x","guarantee":"g","hooks":"best-effort","gateway":"off",
       "masking_level":"off","sandbox":"vendor-default","netpolicy":None,"remote":[],
       "mcp":{"strict":False},"acp":"allow","console":"allow","env_passthrough":[],
       "handoff":{"system_prompt":False}}'

reject "masking above off with no gateway is rejected" profile \
  "{**$base, 'masking_level':'standard'}"
reject "enforced hooks with acp allow is rejected" profile \
  "{**$base, 'hooks':'enforced', 'gateway':'explicit', 'masking_level':'standard'}"
reject "microvm sandbox with no netpolicy is rejected" profile \
  "{**$base, 'sandbox':'microvm', 'acp':'refuse', 'hooks':'enforced', 'gateway':'explicit',
    'masking_level':'standard'}"
reject "claude remote with an explicit gateway is rejected" profile \
  "{**$base, 'remote':['claude'], 'gateway':'explicit', 'masking_level':'standard',
    'hooks':'enforced', 'acp':'refuse'}"
reject "unknown key is rejected" profile "{**$base, 'extra':1}"
reject "wrong enum value is rejected" profile "{**$base, 'gateway':'sideways'}"
reject "a netpolicy name that escapes its directory is rejected" profile \
  "{**$base, 'netpolicy':'../../../tmp/open'}"

accept "a valid minimal profile is accepted" profile "$base"
reject "transparent gateway profiles are no longer declarable" profile \
  "{**$base, 'remote':['claude'], 'gateway':'transparent', 'masking_level':'standard',
    'hooks':'enforced', 'acp':'refuse'}"

# --- network policy entries must name something enforceable ----------------------

reject "deny-by-default with an empty allow list is rejected" netpolicy \
  "{'schema':1,'name':'x','default':'deny','allow':[]}"
reject "an allow entry naming neither kind nor host is rejected" netpolicy \
  "{'schema':1,'name':'x','default':'deny','allow':[{'reason':'why'}]}"
reject "an allow entry naming both kind and host is rejected" netpolicy \
  "{'schema':1,'name':'x','default':'deny','allow':[{'kind':'gateway','host':'h'}]}"
reject "a port with no host is rejected" netpolicy \
  "{'schema':1,'name':'x','default':'deny','allow':[{'port':443}]}"
reject "a port outside the valid range is rejected" netpolicy \
  "{'schema':1,'name':'x','default':'deny','allow':[{'host':'h','port':0}]}"

# --- the hook manifest linter ----------------------------------------------------

entry="{'id':'a','event':'PreToolUse','tools':['shell'],'script':'s.py','args':[],
        'timeout':10,'vendors':['codex'],'profiles':['*']}"
rw="{**$entry,'rewrites_input':True}"

reject "two input-rewriting hooks on the same tool set are rejected" hook-manifest \
  "{'schema':1,'entries':[$rw, {**$rw,'id':'b'}]}"
# The hazard is that both hooks match the same call, which is intersection, not
# equality: a Bash call fires both of these.
reject "two input-rewriting hooks on overlapping tool sets are rejected" hook-manifest \
  "{'schema':1,'entries':[{**$rw,'tools':['shell','file-write']}, {**$rw,'id':'b'}]}"
reject "duplicate hook ids are rejected" hook-manifest \
  "{'schema':1,'entries':[$entry, $entry]}"
reject "a script path that escapes the hooks directory is rejected" hook-manifest \
  "{'schema':1,'entries':[{**$entry,'script':'../../../tmp/evil.py'}]}"
reject "a non-positive hook timeout is rejected" hook-manifest \
  "{'schema':1,'entries':[{**$entry,'timeout':0}]}"

accept "one rewriting hook beside a non-rewriting one is accepted" hook-manifest \
  "{'schema':1,'entries':[$rw, {**$entry,'id':'b'}]}"
# Two hooks that never run in the same process cannot race.
accept "rewriting hooks on different vendors are accepted" hook-manifest \
  "{'schema':1,'entries':[$rw, {**$rw,'id':'b','vendors':['claude']}]}"
accept "rewriting hooks on disjoint profiles are accepted" hook-manifest \
  "{'schema':1,'entries':[{**$rw,'profiles':['standard']},
                          {**$rw,'id':'b','profiles':['protected']}]}"
accept "rewriting hooks on disjoint tool sets are accepted" hook-manifest \
  "{'schema':1,'entries':[$rw, {**$rw,'id':'b','tools':['file-read']}]}"
accept "a nested script path inside the hooks directory is accepted" hook-manifest \
  "{'schema':1,'entries':[{**$entry,'script':'claude-only/caveman.js'}]}"

# --- every JSON contract the LLD specifies has a registered kind ------------------

for kind in profile netpolicy hook-manifest mcp-registry capabilities session \
            launch-claim handoff daemon-record conformance home-marker lockfile \
            install-receipt state-manifest asset-manifest mutable-link-manifest \
            test-inventory; do
  assert_exit "contract kind '$kind' is registered" 0 py "
import sys
from ihar import jsonio
sys.exit(0 if sys.argv[1] in jsonio.KINDS else 1)
" "$kind"
done


assert_exit "the persistent-state manifest validates" 0 \
  py 'import sys; from ihar import jsonio; jsonio.read("state-manifest", sys.argv[1])' \
  "$ROOT/manifests/state.json"

# --- tracked assets are one safe, explicit inventory -----------------------------

asset_entry="{'vendor':'common','source':'hooks','target':'hooks','kind':'directory',
             'required':True,'runtime':False}"

accept "a minimal asset inventory entry is accepted" asset-manifest \
  "{'schema':1,'entries':[$asset_entry]}"
reject "an asset source that escapes its root is rejected" asset-manifest \
  "{'schema':1,'entries':[{**$asset_entry,'source':'../auth'}]}"
reject "an asset target that escapes its runtime is rejected" asset-manifest \
  "{'schema':1,'entries':[{**$asset_entry,'target':'../hooks'}]}"
reject "authentication is not a tracked asset" asset-manifest \
  "{'schema':1,'entries':[{**$asset_entry,'source':'auth/claude'}]}"
reject "generated settings are not tracked assets" asset-manifest \
  "{'schema':1,'entries':[{**$asset_entry,'target':'settings.json'}]}"
reject "state is not a tracked asset" asset-manifest \
  "{'schema':1,'entries':[{**$asset_entry,'source':'st/codex'}]}"
reject "an asset target is unique per vendor" asset-manifest \
  "{'schema':1,'entries':[$asset_entry, {**$asset_entry,'source':'skills'}]}"

assert_exit "the tracked-asset manifest validates" 0 \
  py 'import sys; from ihar import jsonio; jsonio.read("asset-manifest", sys.argv[1])' \
  "$ROOT/manifests/assets.json"

# Runtime generation identity is a semantic projection of the validated asset
# inventory, not the manifest's byte layout. Optional source presence is part of
# that projection because it changes which runtime links can be materialised.
ASSET_IDENTITY_ROOT="$IHAR_TEST_TMP/asset-identity"
mkdir -p "$ASSET_IDENTITY_ROOT/required"
printf 'required\n' > "$ASSET_IDENTITY_ROOT/required/instructions.md"
cat > "$ASSET_IDENTITY_ROOT/first.json" <<'JSON'
{"schema":1,"entries":[
  {"vendor":"common","source":"optional/tools","target":"tools","kind":"directory","required":false,"runtime":true},
  {"vendor":"claude","source":"required/instructions.md","target":"CLAUDE.md","kind":"file","required":true,"runtime":true}
]}
JSON
cat > "$ASSET_IDENTITY_ROOT/reordered.json" <<'JSON'
{
  "entries": [
    {"runtime": true, "required": true, "kind": "file", "target": "CLAUDE.md", "source": "required/instructions.md", "vendor": "claude"},
    {"runtime": true, "required": false, "kind": "directory", "target": "tools", "source": "optional/tools", "vendor": "common"}
  ],
  "schema": 1
}
JSON
assert_exit "asset runtime identity query succeeds" 0 \
  python3 -m ihar.inventory asset-identity \
    "$ASSET_IDENTITY_ROOT/first.json" all "$ASSET_IDENTITY_ROOT"
asset_identity_first="$(python3 -m ihar.inventory asset-identity \
  "$ASSET_IDENTITY_ROOT/first.json" all "$ASSET_IDENTITY_ROOT")"
asset_identity_reordered="$(python3 -m ihar.inventory asset-identity \
  "$ASSET_IDENTITY_ROOT/reordered.json" all "$ASSET_IDENTITY_ROOT")"
assert_eq "asset identity ignores JSON and entry ordering" \
  "$asset_identity_first" "$asset_identity_reordered"

mkdir -p "$ASSET_IDENTITY_ROOT/optional"
printf 'wrong kind\n' > "$ASSET_IDENTITY_ROOT/optional/tools"
asset_identity_optional_wrong_kind="$(python3 -m ihar.inventory asset-identity \
  "$ASSET_IDENTITY_ROOT/first.json" all "$ASSET_IDENTITY_ROOT")"
assert_exit "an optional wrong-kind source differs from absence" 1 \
  test "$asset_identity_first" = "$asset_identity_optional_wrong_kind"

rm "$ASSET_IDENTITY_ROOT/optional/tools"
mkdir "$ASSET_IDENTITY_ROOT/optional/tools"
asset_identity_optional_present="$(python3 -m ihar.inventory asset-identity \
  "$ASSET_IDENTITY_ROOT/first.json" all "$ASSET_IDENTITY_ROOT")"
assert_exit "an optional correct-kind source differs from absence" 1 \
  test "$asset_identity_first" = "$asset_identity_optional_present"
assert_exit "an optional correct-kind source differs from wrong kind" 1 \
  test "$asset_identity_optional_wrong_kind" = "$asset_identity_optional_present"

python3 - "$ASSET_IDENTITY_ROOT/first.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path, encoding="utf-8"))
document["entries"].append({
    "vendor": "codex", "source": "required/new.txt", "target": "new.txt",
    "kind": "file", "required": True, "runtime": True,
})
json.dump(document, open(path, "w", encoding="utf-8"))
PY
asset_identity_required_absent="$(python3 -m ihar.inventory asset-identity \
  "$ASSET_IDENTITY_ROOT/first.json" all "$ASSET_IDENTITY_ROOT")"
assert_exit "a required runtime inventory addition changes asset identity" 1 \
  test "$asset_identity_optional_present" = "$asset_identity_required_absent"
mkdir -p "$ASSET_IDENTITY_ROOT/required/new.txt"
asset_identity_required_wrong_kind="$(python3 -m ihar.inventory asset-identity \
  "$ASSET_IDENTITY_ROOT/first.json" all "$ASSET_IDENTITY_ROOT")"
assert_exit "a required wrong-kind source differs from absence" 1 \
  test "$asset_identity_required_absent" = "$asset_identity_required_wrong_kind"
rm -rf "$ASSET_IDENTITY_ROOT/required/new.txt"
printf 'required new\n' > "$ASSET_IDENTITY_ROOT/required/new.txt"
asset_identity_required_present="$(python3 -m ihar.inventory asset-identity \
  "$ASSET_IDENTITY_ROOT/first.json" all "$ASSET_IDENTITY_ROOT")"
assert_exit "a required correct-kind source differs from absence" 1 \
  test "$asset_identity_required_absent" = "$asset_identity_required_present"
assert_exit "a required correct-kind source differs from wrong kind" 1 \
  test "$asset_identity_required_wrong_kind" = "$asset_identity_required_present"

# --- mutable auth and plugin links are separate from tracked assets ---------------

mutable_entry="{'vendor':'claude','source':'auth/claude/.credentials.json',
                 'target':'.credentials.json','kind':'file'}"

accept "a minimal mutable-link entry is accepted" mutable-link-manifest \
  "{'schema':1,'entries':[$mutable_entry]}"
reject "a mutable source cannot escape the store" mutable-link-manifest \
  "{'schema':1,'entries':[{**$mutable_entry,'source':'../credentials'}]}"
reject "a mutable runtime target cannot escape its home" mutable-link-manifest \
  "{'schema':1,'entries':[{**$mutable_entry,'target':'../credentials'}]}"
reject "a mutable source cannot use a dot-segment alias" mutable-link-manifest \
  "{'schema':1,'entries':[{**$mutable_entry,'source':'auth/claude/.'}]}"
reject "a mutable target cannot be a dot segment" mutable-link-manifest \
  "{'schema':1,'entries':[{**$mutable_entry,'target':'.'}]}"
reject "a mutable source cannot use repeated separators" mutable-link-manifest \
  "{'schema':1,'entries':[{**$mutable_entry,'source':'auth//claude/.credentials.json'}]}"
reject "a mutable target cannot use a trailing separator" mutable-link-manifest \
  "{'schema':1,'entries':[{**$mutable_entry,'target':'plugins/'}]}"
reject "persistent state is not a mutable auth or plugin link" mutable-link-manifest \
  "{'schema':1,'entries':[{**$mutable_entry,'source':'st/claude/history.jsonl'}]}"
reject "a mutable runtime target is unique per vendor" mutable-link-manifest \
  "{'schema':1,'entries':[$mutable_entry, {**$mutable_entry,'source':'auth/claude/other'}]}"
reject "mutable target aliases are duplicate paths" mutable-link-manifest \
  "{'schema':1,'entries':[{**$mutable_entry,'target':'plugins'},
    {**$mutable_entry,'source':'auth/claude/other','target':'plugins/.'}]}"

assert_exit "the mutable-link manifest validates" 0 \
  py 'import sys; from ihar import jsonio; jsonio.read("mutable-link-manifest", sys.argv[1])' \
  "$ROOT/manifests/mutable-links.json"

assert_exit "the tracked release lockfile validates" 0 \
  py 'import sys; from ihar import jsonio; jsonio.read("lockfile", sys.argv[1])' \
  "$ROOT/.ihar-lockfile.json"

# --- executable test inventory is closed and safe ------------------------------------

test_path="{'schema':1,'paths':['tests/test_contracts.sh']}"
accept "a minimal test inventory is accepted" test-inventory "$test_path"
reject "duplicate test paths are rejected" test-inventory \
  "{'schema':1,'paths':['tests/test_contracts.sh','tests/test_contracts.sh']}"
reject "a test path cannot escape the repository" test-inventory \
  "{'schema':1,'paths':['../outside/test_bad.sh']}"
reject "inventory paths must name discovered test files" test-inventory \
  "{'schema':1,'paths':['tests/helpers.sh']}"

assert_exit "the shipped test inventory validates" 0 \
  py 'import sys; from ihar import jsonio; jsonio.read("test-inventory", sys.argv[1])' \
  "$ROOT/manifests/tests.json"

MISSING_INVENTORY="$IHAR_TEST_TMP/missing-tests.json"
printf '%s\n' '{"schema":1,"paths":["tests/test_missing.sh"]}' > "$MISSING_INVENTORY"
assert_exit "the runner rejects a missing inventory path before execution" 3 \
  env IHAR_TEST_INVENTORY="$MISSING_INVENTORY" bash "$ROOT/tests/run.sh"

assert_exit "every shipped hook has exactly one reviewed release pin" 0 \
  py '
import pathlib, sys
from ihar import jsonio
root = pathlib.Path(sys.argv[1])
lock = jsonio.read("lockfile", root / ".ihar-lockfile.json")
hooks = {
    path.relative_to(root).as_posix()
    for path in (root / "hooks").rglob("*")
    if path.is_file() and "__pycache__" not in path.parts
}
managed_root = root / "managed-hooks"
managed = {
    path.relative_to(root).as_posix()
    for path in managed_root.rglob("*")
    if path.is_file()
} if managed_root.is_dir() else set()
sys.exit(0 if set(lock["hooks"]) == hooks and set(lock["managedHooks"]) == managed else 1)
' "$ROOT"

# A pre-existing materialized runtime credential must remain untouched and its
# synthetic payload must never enter diagnostic output.
DIAGNOSTIC_ROOT="$IHAR_TEST_TMP/check-diagnostics"
mkdir -p "$DIAGNOSTIC_ROOT/runtime" "$DIAGNOSTIC_ROOT/store/auth/codex"
printf '%s' 'synthetic-credential-do-not-print' > "$DIAGNOSTIC_ROOT/runtime/auth.json"
diagnostic_status=0
diagnostic_output="$(python3 -m ihar.check_result auth-diff \
  "$DIAGNOSTIC_ROOT/runtime" "$DIAGNOSTIC_ROOT/store" 2>&1)" || diagnostic_status=$?
assert_eq "materialized Codex auth diagnostic is available" "0" "$diagnostic_status"
assert_contains "materialized Codex auth is a mutable-link issue" "$diagnostic_output" "mutable-link: materialized"
assert_contains "materialized Codex auth needs approval" "$diagnostic_output" "user-approved recovery"
assert_contains "materialized Codex auth is neither adopted nor deleted" "$diagnostic_output" \
  "not adopted or deleted"
assert_exit "auth diagnostic never prints credential bytes" 1 \
  grep -F 'synthetic-credential-do-not-print' <<<"$diagnostic_output"
assert_eq "auth diagnostic preserves materialized bytes" 'synthetic-credential-do-not-print' \
  "$(cat "$DIAGNOSTIC_ROOT/runtime/auth.json")"

auth_categories="$(python3 - "$IHAR_TEST_TMP/auth-owner-categories" <<'PY'
import copy
import io
import json
import os
import sys
from contextlib import ExitStack, redirect_stdout
from pathlib import Path

from ihar.check_result import _auth_diff
from ihar.codex import auth_owner

root = Path(sys.argv[1])
store = root / "store"
runtime = root / "runtime"
runtime.mkdir(parents=True)
store.mkdir()
with ExitStack() as stack:
    auth_owner._owner_directories(store, stack, create=True)
canonical = store / "auth" / "codex" / "auth.json"
canonical.write_text("synthetic-token-not-for-output", encoding="utf-8")
canonical.chmod(0o600)
owner_path = store / "auth" / "codex" / ".owner.json"

def report(label):
    captured = io.StringIO()
    with redirect_stdout(captured):
        assert _auth_diff(str(runtime), str(store)) == 0
    print(f"{label}={captured.getvalue().strip()}")

def write_raw(record):
    owner_path.write_text(json.dumps(record), encoding="utf-8")
    owner_path.chmod(0o600)

report("missing")
(runtime / "auth.json").symlink_to(canonical)
report("valid")
record = {
    "schema": 1, "id": "synthetic-owner-id", "runtime": str(runtime),
    "mode": "foreground", "guardian": auth_owner._identity_for(os.getpid()),
    "child": None, "daemon": None, "attached_guardian": None, "state": "active",
}
with ExitStack() as stack:
    _root, _auth, owner = auth_owner._owner_directories(store, stack, create=False)
    auth_owner._write_owner(owner, record)
report("busy")
blocked_record = {
    "schema": 2, "state": "blocked", "guardian": auth_owner._identity_for(os.getpid()),
    "child": None, "children": [], "daemon": None, "guest": None,
    "guest_bundle": None, "guest_reconciled": False,
    "runtime": str(runtime), "config_hash": "synthetic-generation",
}
with ExitStack() as stack:
    _root, _auth, owner = auth_owner._owner_directories(store, stack, create=False)
    auth_owner._write_owner(owner, blocked_record)
report("blocked")
identity = {"pid": 99999998, "start": "nested", "binary": "/nested-secret-value",
            "pgrp": 99999998}
daemon_record = copy.deepcopy(blocked_record)
daemon_record["daemon"] = dict(
    identity, socket=str(root / "private-daemon.sock"), socket_dev=1, socket_ino=2,
)
write_raw(daemon_record)
report("blocked-daemon")
remote_record = copy.deepcopy(blocked_record)
remote_record["daemon"] = copy.deepcopy(daemon_record["daemon"])
remote_record["children"] = [dict(
    identity, client_state=str(root / "private-client-state"), client_state_dev=3,
    client_state_ino=4, descendants=[dict(identity, pid=99999997, pgrp=99999997)],
)]
write_raw(remote_record)
report("blocked-remote")
remote_record["daemon"] = None
write_raw(remote_record)
report("blocked-remote-retained")
auth_stage_record = copy.deepcopy(blocked_record)
auth_stage_record.update(auth_stage=str(root / "private-auth-stage"), auth_verb="login",
                         auth_caller=identity)
write_raw(auth_stage_record)
report("blocked-auth-stage")
file_identity = {
    "dev": 1, "ino": 2, "size": 3, "mtime_ns": 4, "ctime_ns": 5, "sha256": "a" * 64,
}
guest_base = {
    "bundle": str(root / "private-guest-bundle"), "identity": [1, 2],
    "image": str(root / "private-guest-image"), "image_identity": [3, 4],
    "baseline": file_identity, "vm": None, "state": "registered",
}
for guest_state in ("registered", "starting", "running", "quiescent",
                    "published-pending", "returned"):
    guest_record = copy.deepcopy(blocked_record)
    guest = copy.deepcopy(guest_base)
    guest["state"] = guest_state
    if guest_state in ("running", "quiescent", "published-pending", "returned"):
        guest["vm"] = identity
    if guest_state in ("published-pending", "returned"):
        guest.update(candidate=file_identity, published=file_identity, ack_sha256="b" * 64)
    guest_record["guest_bundle"] = guest
    guest_record["guest"] = (identity if guest_state in
                             ("running", "quiescent", "published-pending") else None)
    guest_record["guest_reconciled"] = guest_state == "returned"
    write_raw(guest_record)
    report(f"blocked-guest-{guest_state}")
write_raw({
    "schema": 2, "state": "blocked", "id": "malformed-owner-id",
    "path": str(root / "private-owner-path"), "secret": "malformed-secret-value",
})
report("malformed")
daemon_record["daemon"].pop("socket_ino")
write_raw(daemon_record)
report("truncated-daemon")
daemon_record["daemon"]["socket_ino"] = 2
remote_record["children"][0].pop("descendants")
write_raw(remote_record)
report("truncated-remote")
remote_record = copy.deepcopy(blocked_record)
remote_record["daemon"] = copy.deepcopy(daemon_record["daemon"])
remote_record["children"] = [dict(
    identity, client_state=str(root / "private-client-state"), client_state_dev=3,
    descendants=[],
)]
write_raw(remote_record)
report("truncated-remote-client-state")
auth_stage_record.pop("auth_caller")
write_raw(auth_stage_record)
report("truncated-auth-stage")
guest_record = copy.deepcopy(blocked_record)
guest = copy.deepcopy(guest_base)
guest.update(state="published-pending", vm=identity, candidate=file_identity,
             published=file_identity)
guest_record.update(guest=identity, guest_bundle=guest)
write_raw(guest_record)
report("truncated-guest-ack")
guest["ack_sha256"] = "b" * 64
guest["state"] = "returned"
write_raw(guest_record)
report("invalid-guest-return")
record = copy.deepcopy(blocked_record)
record["state"] = "active"
record["guardian"] = {
    "pid": 99999999, "start": "synthetic", "binary": "/no-such-binary", "pgrp": 99999999,
}
with ExitStack() as stack:
    _root, _auth, owner = auth_owner._owner_directories(store, stack, create=False)
    auth_owner._write_owner(owner, record)
report("unverified")
PY
)"
assert_contains "missing auth link has bounded category" "$auth_categories" \
  "missing=codex mutable-link: missing; auth-owner: unverified"
assert_contains "valid auth link names recorded-owner scope" "$auth_categories" \
  "valid=codex mutable-link: valid; auth-owner: no recorded owner"
assert_contains "active lease has busy category" "$auth_categories" \
  "busy=codex mutable-link: valid; auth-owner: busy"
assert_contains "blocked guardian has a bounded blocked category" "$auth_categories" \
  "blocked=codex mutable-link: valid; auth-owner: blocked"
for transition in daemon remote remote-retained auth-stage guest-registered guest-starting \
  guest-running guest-quiescent \
  guest-published-pending guest-returned; do
  assert_contains "valid blocked nested owner transition stays trusted" "$auth_categories" \
    "blocked-$transition=codex mutable-link: valid; auth-owner: blocked"
done
assert_contains "malformed blocked record is unverified" "$auth_categories" \
  "malformed=codex mutable-link: valid; auth-owner: unverified"
for nested in truncated-daemon truncated-remote truncated-remote-client-state \
  truncated-auth-stage truncated-guest-ack invalid-guest-return; do
  assert_contains "truncated nested blocked owner is unverified" "$auth_categories" \
    "$nested=codex mutable-link: valid; auth-owner: unverified"
done
assert_contains "unproven lease has unverified category" "$auth_categories" \
  "unverified=codex mutable-link: valid; auth-owner: unverified"
for withheld in synthetic-token-not-for-output synthetic-owner-id malformed-owner-id \
  malformed-secret-value nested-secret-value \
  "$IHAR_TEST_TMP/auth-owner-categories/private-owner-path" \
  "$IHAR_TEST_TMP/auth-owner-categories/private-daemon.sock" \
  "$IHAR_TEST_TMP/auth-owner-categories/private-client-state" \
  "$IHAR_TEST_TMP/auth-owner-categories/private-auth-stage" \
  "$IHAR_TEST_TMP/auth-owner-categories/private-guest-bundle" \
  "$IHAR_TEST_TMP/auth-owner-categories/private-guest-image" \
  "$IHAR_TEST_TMP/auth-owner-categories"; do
  assert_exit "auth diagnostic withholds synthetic payload and metadata" 1 \
    grep -F -- "$withheld" <<<"$auth_categories"
done

# A selected generation is visible even when no rendered file differs. The
# effective MCP identity is already an input to that generation's hash.
_test_generation_diagnostic() (
  source "$ROOT/lib/cli/check.sh"
  ihar_profile_resolve() { IHAR_PROFILE_GATEWAY=off; }
  _ihar_project_state() { printf '%s\n' "$DIAGNOSTIC_ROOT/state"; }
  ihar_render_all() { mkdir -p "$2"; }
  _ihar_check_runtime() { printf '%s/r/abcdef12/%s\n' "$DIAGNOSTIC_ROOT/state" "$1"; }
  IHAR_FLAG_PROFILE=standard
  ihar_check_diff
)
generation_output="$(_test_generation_diagnostic)"
assert_contains "check diff names selected Claude generation" "$generation_output" \
  "claude selected runtime generation abcdef12"
assert_contains "check diff names selected Codex generation" "$generation_output" \
  "codex selected runtime generation abcdef12"
assert_contains "check diff says MCP identity is in selection" "$generation_output" \
  "effective-mcp-identity"

# Codex embeds MCP tables in config.toml. Once the existing file comparator has
# found drift, diagnostic classification must distinguish those tables from an
# unrelated managed setting without displaying either field's value.
CONFIG_DIAGNOSTIC_ROOT="$IHAR_TEST_TMP/config-diagnostics"
mkdir -p "$CONFIG_DIAGNOSTIC_ROOT"
printf '%s\n' '[mcp_servers.example]' 'url = "https://mcp.example/expected"' \
  '[sandbox]' 'mode = "safe"' > "$CONFIG_DIAGNOSTIC_ROOT/desired.toml"
printf '%s\n' '[mcp_servers.example]' 'url = "https://mcp.example/changed"' \
  '[sandbox]' 'mode = "safe"' > "$CONFIG_DIAGNOSTIC_ROOT/mcp-drift.toml"
printf '%s\n' '[mcp_servers.example]' 'url = "https://mcp.example/expected"' \
  '[sandbox]' 'mode = "changed"' > "$CONFIG_DIAGNOSTIC_ROOT/setting-drift.toml"
assert_eq "Codex MCP table drift has its own bounded category" "mcp-render-drift" \
  "$(python3 -m ihar.check_result config-diff-category \
    "$CONFIG_DIAGNOSTIC_ROOT/desired.toml" "$CONFIG_DIAGNOSTIC_ROOT/mcp-drift.toml")"
assert_eq "Codex non-MCP config drift stays managed-setting drift" "managed-setting-drift" \
  "$(python3 -m ihar.check_result config-diff-category \
    "$CONFIG_DIAGNOSTIC_ROOT/desired.toml" "$CONFIG_DIAGNOSTIC_ROOT/setting-drift.toml")"
_test_codex_config_diff() (
  source "$ROOT/lib/state/runtime.sh"
  source "$ROOT/lib/cli/check.sh"
  ihar_python() { python3 -m "$1" "${@:2}"; }
  ihar_profile_resolve() { IHAR_PROFILE_GATEWAY=off; }
  _ihar_project_state() { printf '%s\n' "$CONFIG_DIAGNOSTIC_ROOT/state"; }
  ihar_render_all() {
    mkdir -p "$2"
    [[ "$1" != codex ]] || cp "$CONFIG_DIAGNOSTIC_ROOT/desired.toml" "$2/config.toml"
  }
  _ihar_check_runtime() {
    printf '%s/r/abcdef12/%s\n' "$CONFIG_DIAGNOSTIC_ROOT/state" "$1"
  }
  IHAR_FLAG_PROFILE=standard
  ihar_check_diff
)
mkdir -p "$CONFIG_DIAGNOSTIC_ROOT/state/r/abcdef12/codex"
cp "$CONFIG_DIAGNOSTIC_ROOT/mcp-drift.toml" \
  "$CONFIG_DIAGNOSTIC_ROOT/state/r/abcdef12/codex/config.toml"
codex_mcp_diff="$(_test_codex_config_diff)"
assert_contains "check diff categorizes Codex MCP drift" "$codex_mcp_diff" "mcp-render-drift"
assert_exit "check diff does not print Codex MCP endpoint" 1 \
  grep -F 'https://mcp.example/changed' <<<"$codex_mcp_diff"
cp "$CONFIG_DIAGNOSTIC_ROOT/setting-drift.toml" \
  "$CONFIG_DIAGNOSTIC_ROOT/state/r/abcdef12/codex/config.toml"
codex_setting_diff="$(_test_codex_config_diff)"
assert_contains "check diff categorizes Codex managed setting drift" \
  "$codex_setting_diff" "managed-setting-drift"
mv "$CONFIG_DIAGNOSTIC_ROOT/state/r/abcdef12/codex/config.toml" \
  "$CONFIG_DIAGNOSTIC_ROOT/state/r/abcdef12/codex/config.saved.toml"
codex_missing_config_diff="$(_test_codex_config_diff)"
assert_contains "missing Codex config does not guess a managed or MCP cause" \
  "$codex_missing_config_diff" "rendered-config-missing"

finish
