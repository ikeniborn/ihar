#!/usr/bin/env bash
# Handoff control-plane and per-target injection (LLD 11). Failure class: mixed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
export PYTHONPATH="$ROOT/lib/python"
ihar_python() { if [[ "$1" == -c ]]; then python3 "$@"; else python3 -m "$@"; fi; }

project="$IHAR_TEST_TMP/project"
mkdir -p "$project"
out="$(cd "$project" && IHAR_LAUNCH_ID=missing "$ROOT/ihar.sh" switch --to codex 2>&1 || true)"
assert_contains "switch is a delivered command" "$out" "unknown source session 'missing'"

state="$IHAR_TEST_TMP/state"
runtime="$IHAR_TEST_TMP/runtime"
mkdir -p "$state/handoff/pending" "$runtime"
cat > "$runtime/ihar-policy.json" <<EOF
{"vendor":"codex","profile":"standard","runtime_hash":"deadbeef","state":"$state"}
EOF

one="$(python3 -m ihar.ids)"
two="$(python3 -m ihar.ids)"
for row in "$one codex-one first-package" "$two codex-two second-package"; do
  read -r ihar_id vendor_id payload <<< "$row"
  python3 -m ihar.sessions.index append "$state/sessions.jsonl" <<EOF
{"schema":1,"ihar_id":"$ihar_id","vendor":"codex","vendor_session_id":"$vendor_id","profile":"standard","source":"hook"}
EOF
  python3 - "$payload" <<'PY' > "$state/handoff/pending/$ihar_id.md"
import sys
print("x" * 2048 + sys.argv[1], end="")
PY
done

CODEX_HOME="$runtime" python3 -I "$ROOT/hooks/handoff-inject.py" --vendor codex <<'EOF' > "$IHAR_TEST_TMP/one.out"
{"hook_event_name":"SessionStart","session_id":"codex-one","tool_input":{}}
EOF
CODEX_HOME="$runtime" python3 -I "$ROOT/hooks/handoff-inject.py" --vendor codex <<'EOF' > "$IHAR_TEST_TMP/two.out"
{"hook_event_name":"SessionStart","session_id":"codex-two","tool_input":{}}
EOF

assert_contains "first target receives only its package" "$(cat "$IHAR_TEST_TMP/one.out")" "first-package"
assert_contains "second target receives only its package" "$(cat "$IHAR_TEST_TMP/two.out")" "second-package"
assert_exit "first pending package is consumed" 1 test -f "$state/handoff/pending/$one.md"
assert_exit "second pending package is consumed" 1 test -f "$state/handoff/pending/$two.md"

source "$ROOT/lib/handoff/handoff.sh"
ihar_warn() { printf 'warning: %s\n' "$*" >&2; }
IHAR_STATE="$state"
carrier_id="$(python3 -m ihar.ids)"
IHAR_LAUNCH_ID="$carrier_id"
python3 - <<'PY' > "$state/handoff/pending/$carrier_id.md"
print("A" * 2048 + "TAIL", end="")
PY
python3 -m ihar.sessions.index append "$state/sessions.jsonl" <<EOF
{"schema":1,"ihar_id":"$carrier_id","vendor":"codex","vendor_session_id":"codex-carrier","profile":"standard","source":"hook"}
EOF
IHAR_FLAG_PROMPT=""
ihar_handoff_prepare codex
assert_contains "codex initial prompt points to hook continuation" "$IHAR_FLAG_PROMPT" "remaining handoff context"
assert_exit "codex leaves package for SessionStart" 0 test -f "$state/handoff/pending/$carrier_id.md"
CODEX_HOME="$runtime" python3 -I "$ROOT/hooks/handoff-inject.py" --vendor codex <<'EOF' > "$IHAR_TEST_TMP/carrier.out"
{"hook_event_name":"SessionStart","session_id":"codex-carrier","tool_input":{}}
EOF
remainder="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' < "$IHAR_TEST_TMP/carrier.out")"
assert_eq "codex hook carries only the remainder" TAIL "$remainder"
utf8_id="$(python3 -m ihar.ids)"
python3 - <<'PY' > "$state/handoff/pending/$utf8_id.md"
print("я" * 1024 + "TAIL", end="")
PY
python3 -m ihar.sessions.index append "$state/sessions.jsonl" <<EOF
{"schema":1,"ihar_id":"$utf8_id","vendor":"codex","vendor_session_id":"codex-utf8","profile":"standard","source":"hook"}
EOF
IHAR_LAUNCH_ID="$utf8_id"
IHAR_FLAG_PROMPT=""
ihar_handoff_prepare codex
CODEX_HOME="$runtime" python3 -I "$ROOT/hooks/handoff-inject.py" --vendor codex <<'EOF' > "$IHAR_TEST_TMP/utf8.out"
{"hook_event_name":"SessionStart","session_id":"codex-utf8","tool_input":{}}
EOF
remainder="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' < "$IHAR_TEST_TMP/utf8.out")"
assert_eq "codex split preserves UTF-8 after 2048 bytes" TAIL "$remainder"
newline_id="$(python3 -m ihar.ids)"
python3 - <<'PY' > "$state/handoff/pending/$newline_id.md"
print("A" * 2047 + "\nTAIL", end="")
PY
IHAR_LAUNCH_ID="$newline_id"
IHAR_FLAG_PROMPT=""
ihar_handoff_prepare codex
assert_eq "codex prefix preserves a boundary newline" $'\n\n\n' "${IHAR_FLAG_PROMPT:2047:3}"
IHAR_LAUNCH_ID="claude-carrier"
printf '%2500s' x > "$state/handoff/pending/claude-carrier.md"
IHAR_FLAG_PROMPT=""
ihar_handoff_prepare claude
assert_eq "claude carries the whole package in its initial prompt" "2500" "${#IHAR_FLAG_PROMPT}"
IHAR_VENDOR=claude
ihar_handoff_consume_claude
assert_exit "claude consumes its initial-prompt package" 1 test -f "$state/handoff/pending/claude-carrier.md"

source_id="$(python3 -m ihar.ids)"
expected_target="$(python3 -m ihar.ids)"
python3 -m ihar.sessions.index append "$state/sessions.jsonl" <<EOF
{"schema":1,"ihar_id":"$source_id","vendor":"claude","vendor_session_id":"source-vendor","project":"project","cwd":"$project","git_branch":null,"title":null,"model":null,"profile":"standard","started_at":"2026-09-19T12:00:00Z","updated_at":"2026-09-19T12:00:00Z","parent_ihar_id":null,"handoff_from":null,"handoff_to":null,"tags":[],"source":"launch"}
EOF
ihar_state_setup() { IHAR_STATE="$state"; export IHAR_STATE; }
ihar_uuid() { printf '%s\n' "$expected_target"; }
ihar_adapter() { printf '%s\n' '{"open_items":[],"decisions":[],"decisions_heuristic":[],"recent_messages":[]}'; }
ihar_cmd_launch() { launched_vendor="$1"; }
ihar_profile_resolve() { resolved_profile="$1"; IHAR_GATEWAY_MASKING_LEVEL=off; }
IHAR_PROJECT_ROOT="$project"
IHAR_LAUNCH_ID="$source_id"
IHAR_FLAG_TO=codex
IHAR_SUBCOMMAND=""
IHAR_ARGS=()
IHAR_DISTILLER=off
IHAR_GATEWAY_MASKING_LEVEL=off
launched_vendor=""
resolved_profile=""
ihar_cmd_switch
assert_eq "switch dispatches the target vendor" codex "$launched_vendor"
assert_eq "switch resolves the source profile before packaging" standard "$resolved_profile"
assert_exit "switch writes a target-specific pending package" 0 test -f "$state/handoff/pending/$expected_target.md"
linked="$(python3 -m ihar.sessions.index show "$state/sessions.jsonl" "$source_id")"
assert_contains "switch links source to target" "$linked" "\"handoff_to\": \"$expected_target\""
linked="$(python3 -m ihar.sessions.index show "$state/sessions.jsonl" "$expected_target")"
assert_contains "switch links target back to source" "$linked" "\"handoff_from\": \"$source_id\""

package="$(cat "$state/handoff/$source_id.json")"
assert_contains "switch defaults to summary history" "$package" '"mode":"summary"'
assert_exit "summary mode writes no transcript export" 1 \
  test -f "$state/handoff/$source_id-transcript.md"

# An unknown --history value is a usage error, not a silent fallback to summary: a user who
# asked for the transcript and got a summary would never learn the history did not travel.
out="$(cd "$project" && IHAR_LAUNCH_ID=missing "$ROOT/ihar.sh" switch --to codex --history all 2>&1 || true)"
assert_contains "an unknown history mode is refused" "$out" "--history must be summary or transcript"

# transcript mode reads the source session through the adapter and points at the export.
ihar_adapter() {
  if [[ "$2" == get_session ]]; then
    printf '%s\n' '[{"role":"user","text":"first question","at":"2026-09-21T10:00:00Z"},{"role":"assistant","text":"first answer","at":"2026-09-21T10:01:00Z"}]'
  else
    printf '%s\n' '{"open_items":[],"decisions":[],"decisions_heuristic":[],"recent_messages":[]}'
  fi
}
IHAR_FLAG_HISTORY=transcript
ihar_cmd_switch
assert_exit "transcript mode writes the export" 0 test -f "$state/handoff/$source_id-transcript.md"
package="$(cat "$state/handoff/$source_id.json")"
assert_contains "transcript mode is recorded" "$package" '"mode":"transcript"'
assert_contains "the package points at the export" \
  "$(cat "$state/handoff/pending/$expected_target.md")" "$source_id-transcript.md"
assert_contains "the export carries the conversation" \
  "$(cat "$state/handoff/$source_id-transcript.md")" "first answer"

# An unreadable source transcript degrades the mode; it never aborts the switch.
rm -f "$state/handoff/$source_id-transcript.md"
ihar_adapter() { [[ "$2" == get_session ]] && return 1; printf '%s\n' '{"open_items":[],"decisions":[],"decisions_heuristic":[],"recent_messages":[]}'; }
launched_vendor=""
ihar_cmd_switch
assert_eq "an unreadable transcript still switches" codex "$launched_vendor"
package="$(cat "$state/handoff/$source_id.json")"
assert_contains "an unreadable transcript degrades to summary" "$package" '"mode":"summary"'
assert_exit "a degraded switch writes no export" 1 test -f "$state/handoff/$source_id-transcript.md"

finish
