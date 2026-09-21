#!/usr/bin/env bash
# Run every test file, one summary line each, non-zero on any failure.
#
# Failure class: runtime. A test file that cannot start is a failure, never a skip;
# a test that needs an absent vendor binary skips inside itself and says so.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

failed=0
total=0

inventory="${IHAR_TEST_INVENTORY:-$ROOT/manifests/tests.json}"
inventory_paths="$(PYTHONPATH="$ROOT/lib/python" python3 - "$inventory" <<'PY'
import sys
from ihar import jsonio

try:
    document = jsonio.read("test-inventory", sys.argv[1])
except (OSError, jsonio.SchemaError) as error:
    print(f"test inventory invalid: {error}", file=sys.stderr)
    raise SystemExit(3)
print("\n".join(document["paths"]))
PY
)" || exit 3

shopt -s nullglob
discovered=(tests/test_*.sh tests/test_*.py)
shopt -u nullglob

for file in $inventory_paths; do
  [[ -f "$file" ]] || { echo "test inventory missing path: $file" >&2; exit 3; }
  found=false
  for candidate in "${discovered[@]}"; do
    [[ "$candidate" == "$file" ]] && { found=true; break; }
  done
  [[ "$found" == true ]] \
    || { echo "test inventory path is not discovered by tests/run.sh: $file" >&2; exit 3; }
done

for file in "${discovered[@]}"; do
  grep -qxF "$file" <<<"$inventory_paths" \
    || { echo "discovered test is absent from closed inventory: $file" >&2; exit 3; }
done

for file in tests/test_*.sh; do
  [[ -e "$file" ]] || continue
  total=$((total + 1))
  if output="$(bash "$file" 2>&1)"; then
    printf 'ok   %-40s %s\n' "$file" "$(tail -1 <<<"$output")"
  else
    failed=$((failed + 1))
    printf 'FAIL %-40s %s\n' "$file" "$(tail -1 <<<"$output")"
    sed 's/^/     | /' <<<"$output"
  fi
done

for file in tests/test_*.py; do
  [[ -e "$file" ]] || continue
  total=$((total + 1))
  if output="$(PYTHONPATH="$ROOT/lib/python" python3 "$file" 2>&1)"; then
    printf 'ok   %-40s %s\n' "$file" "${output##*$'\n'}"
  else
    failed=$((failed + 1))
    printf 'FAIL %-40s\n' "$file"
    sed 's/^/     | /' <<<"$output"
  fi
done

echo "---"
echo "files=$total failed=$failed"
[[ "$failed" -eq 0 ]]
