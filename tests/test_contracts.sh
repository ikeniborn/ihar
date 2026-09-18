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

# --- the four profiles of LLD 12.1 are all present ------------------------------

for name in standard protected remote-protected isolated; do
  assert_exit "profile $name is shipped" 0 test -f "$ROOT/manifests/profiles/$name.json"
done

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
        print(f"{obj[\"name\"]} -> {policy}")
' "$ROOT")"
assert_eq "every named netpolicy exists" "" "$missing"

# --- semantic rules reject the configurations the LLD forbids --------------------

reject() { # <desc> <kind> <python dict literal>
  local desc="$1" kind="$2" doc="$3"
  assert_exit "$desc" 1 py "
import sys
from ihar import jsonio
try:
    jsonio.check(sys.argv[1], $doc)
except jsonio.SchemaError:
    sys.exit(1)
sys.exit(0)
" "$kind"
}

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
reject "unknown key is rejected" profile "{**$base, 'extra':1}"
reject "wrong enum value is rejected" profile "{**$base, 'gateway':'sideways'}"
reject "deny-by-default with an empty allow list is rejected" netpolicy \
  "{'schema':1,'name':'x','default':'deny','allow':[]}"

assert_exit "a valid minimal profile is accepted" 0 py "
from ihar import jsonio
jsonio.check('profile', $base)
"

# --- the hook manifest linter ----------------------------------------------------

entry="{'id':'a','event':'PreToolUse','tools':['shell'],'script':'s.py','args':[],
        'timeout':10,'vendors':['codex'],'profiles':['*']}"

reject "two input-rewriting hooks on one event and tool set are rejected" hook-manifest \
  "{'schema':1,'entries':[{**$entry,'rewrites_input':True},
                          {**$entry,'id':'b','rewrites_input':True}]}"
reject "duplicate hook ids are rejected" hook-manifest \
  "{'schema':1,'entries':[$entry, $entry]}"

assert_exit "one rewriting hook beside a non-rewriting one is accepted" 0 py "
from ihar import jsonio
jsonio.check('hook-manifest', {'schema':1,'entries':[{**$entry,'rewrites_input':True},
                                                     {**$entry,'id':'b'}]})
"

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
