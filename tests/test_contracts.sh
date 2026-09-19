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
       "mcp":{"strict":False},"acp":"allow","env_passthrough":[],
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
            launch-claim handoff daemon-record conformance home-marker lockfile; do
  assert_exit "contract kind '$kind' is registered" 0 py "
import sys
from ihar import jsonio
sys.exit(0 if sys.argv[1] in jsonio.KINDS else 1)
" "$kind"
done

finish
