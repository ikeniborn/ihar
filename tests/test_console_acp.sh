#!/usr/bin/env bash
# The ACP chat tab's gate and its label (LLD 13.3). Failure class: mixed.
#
# The client itself is covered by tests/test_console_acp.py against a fake agent. What is
# asserted here is what a user is promised: where the tab may exist, and that the window
# and the terminal say the same thing about what it does not carry.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
export PYTHONPATH="$ROOT/lib/python"

project="$IHAR_TEST_TMP/project"
mkdir -p "$project"

# The shipped profiles decide where a chat tab can exist at all.
assert_contains "standard allows ACP" "$(cat "$ROOT/manifests/profiles/standard.json")" \
  '"acp": "allow"'
for name in protected isolated; do
  assert_contains "$name refuses ACP" "$(cat "$ROOT/manifests/profiles/$name.json")" \
    '"acp": "refuse"'
done

# The broker refuses the kind on its own, not only because the profile list says so.
ROOT="$ROOT" out="$(ROOT="$ROOT" python3 - <<'PY' 2>&1
import json, os, sys, tempfile
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
from ihar.console.broker import Broker, ACP_CAVEATS

root = Path(os.environ["ROOT"])
with tempfile.TemporaryDirectory() as raw:
    state = Path(raw) / "state"
    (state / "console").mkdir(parents=True)
    project = Path(raw) / "project"
    project.mkdir()
    broker = Broker(state, root, 4)
    (project / ".ihar_config").write_text("IHAR_PROFILE=protected\n", encoding="utf-8")
    try:
        broker.open_tab(str(project), "codex", None, "acp")
        print("REFUSAL-MISSING")
    except PermissionError as error:
        print(f"REFUSED {error}")
    print("CAVEATS", json.dumps(ACP_CAVEATS))
PY
)"
ROOT="$ROOT" true
assert_contains "an enforced profile never offers the chat tab" "$out" "REFUSED"
assert_contains "the refusal names the profile setting" "$out" "acp: refuse"
assert_contains "the refusal says why it cannot be offered" "$out" "cannot promise"

# Every caveat the tab carries is a line `ihar check` prints, so there is one wording.
report="$(cd "$project" && "$ROOT/ihar.sh" check 2>&1 || true)"
python3 - "$out" <<'PY' > "$IHAR_TEST_TMP/caveats"
import json, sys
line = [row for row in sys.argv[1].splitlines() if row.startswith("CAVEATS ")][0]
print("\n".join(json.loads(line[len("CAVEATS "):])))
PY
while IFS= read -r caveat; do
  [[ -n "$caveat" ]] || continue
  assert_contains "check repeats the tab's caveat: ${caveat:0:40}" "$report" "$caveat"
done < "$IHAR_TEST_TMP/caveats"

assert_contains "check names the console's own capability boundary" "$report" \
  "no filesystem or terminal capability"

finish
