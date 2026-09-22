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

finish
