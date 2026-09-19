#!/usr/bin/env bash
# Session CLI and launch claims (LLD 10). Failure class: fail-soft.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
export PYTHONPATH="$ROOT/lib/python"

STATE="$IHAR_TEST_TMP/state"
mkdir -p "$STATE"

id="$(python3 -m ihar.ids)"
python3 -m ihar.sessions.index append "$STATE/sessions.jsonl" <<EOF
{"schema":1,"ihar_id":"$id","vendor":"claude","vendor_session_id":"vendor-1","project":"ihar","cwd":"/work/ihar","git_branch":"main","title":"session one","model":null,"profile":"standard","started_at":"2026-09-19T10:00:00Z","updated_at":"2026-09-19T10:01:00Z","parent_ihar_id":null,"handoff_from":null,"handoff_to":null,"tags":[],"source":"launch"}
EOF

out="$(python3 -m ihar.sessions.index list "$STATE/sessions.jsonl")"
assert_contains "the list carries the canonical id" "$out" "$id"
assert_contains "and the title" "$out" "session one"
assert_eq "resume resolves canonical id to vendor id and profile" $'claude\tvendor-1\tstandard' \
  "$(python3 -m ihar.sessions.index resolve "$STATE/sessions.jsonl" "$id")"

python3 -m ihar.sessions.index name "$STATE/sessions.jsonl" "$id" "renamed"
assert_contains "name appends an index override" \
  "$(python3 -m ihar.sessions.index list "$STATE/sessions.jsonl")" "renamed"

ephemeral="$IHAR_TEST_TMP/ephemeral.jsonl"
printf '{"ihar_id":"%s"}\n' "$id" > "$ephemeral"
assert_eq "ephemeral sessions are excluded" "[]" \
  "$(python3 -m ihar.sessions.index list "$STATE/sessions.jsonl" --ephemeral "$ephemeral")"

claim_id="$(python3 -m ihar.ids)"
claim="$(python3 -m ihar.sessions.index claim codex protected deadbeef "$STATE/launches" --ihar-id "$claim_id")"
assert_exit "a launch claim is written" 0 test -f "$claim"
assert_contains "the claim records its runtime" "$(cat "$claim")" '"runtime_hash": "deadbeef"'
assert_contains "the claim preserves the launch canonical id" "$(cat "$claim")" "\"ihar_id\": \"$claim_id\""

HOME_DIR="$IHAR_TEST_TMP/runtime"
mkdir -p "$HOME_DIR"
cat > "$HOME_DIR/ihar-policy.json" <<EOF
{"vendor":"codex","profile":"protected","runtime_hash":"deadbeef","state":"$STATE"}
EOF
CODEX_HOME="$HOME_DIR" python3 -I "$ROOT/hooks/session-register.py" --vendor codex <<'EOF'
{"hook_event_name":"SessionStart","session_id":"codex-session","tool_input":{}}
EOF
assert_exit "the hook consumes the matching launch claim" 1 test -f "$claim"
assert_contains "and records the payload session id" "$(cat "$STATE/sessions.jsonl")" "codex-session"

claim_ids="$IHAR_TEST_TMP/claim-ids"
: > "$claim_ids"
for n in $(seq 1 10); do
  parallel_id="$(python3 -m ihar.ids)"
  printf '%s\n' "$parallel_id" >> "$claim_ids"
  python3 -m ihar.sessions.index claim codex protected deadbeef "$STATE/launches" \
    --ihar-id "$parallel_id" >/dev/null
  CODEX_HOME="$HOME_DIR" python3 -I "$ROOT/hooks/session-register.py" --vendor codex <<EOF &
{"hook_event_name":"SessionStart","session_id":"parallel-$n","tool_input":{}}
EOF
done
wait
assert_eq "parallel hooks append ten intact records" "10" \
  "$(grep -c 'parallel-' "$STATE/sessions.jsonl")"
assert_eq "parallel hooks consume every claim exactly once" "10" \
  "$(python3 - "$STATE/sessions.jsonl" "$claim_ids" <<'PY'
import json, sys
wanted = set(open(sys.argv[2], encoding="utf-8").read().splitlines())
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
print(sum(row.get("ihar_id") in wanted for row in rows))
PY
)"
assert_eq "parallel hooks leave no claim behind" "0" \
  "$(find "$STATE/launches" -type f | wc -l)"

finish
