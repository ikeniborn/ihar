"""One field out of a JSON object on stdin, for shell callers.

`jq` is not a dependency ihar may take on a correctness path (CLAUDE.md): it is not
guaranteed installed and its absence is quiet. This reads the value the shell asked
for and prints nothing but that, looking one level into `status` as well, because the
daemon answers nest the vendor's own object there.
"""

from __future__ import annotations

import json
import sys


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: ihar.codex.field <key>", file=sys.stderr)
        return 2
    key = argv[0]
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        return 1
    if not isinstance(payload, dict):
        return 1
    if key in payload:
        value = payload[key]
    else:
        nested = payload.get("status")
        if not isinstance(nested, dict) or key not in nested:
            return 1
        value = nested[key]
    print(value if isinstance(value, str) else json.dumps(value))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
