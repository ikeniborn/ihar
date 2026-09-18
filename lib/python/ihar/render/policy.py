"""Render the effective policy a hook reads from disk (LLD 6.2).

Usage:
    python3 -m ihar.render.policy <vendor> <profile> <hooks> <masking>
                                  <state> <store> <state-root>
"""

from __future__ import annotations

import json
import sys


def render(vendor, profile, hooks, masking, state, store, state_root) -> dict:
    return {
        "vendor": vendor,
        "profile": profile,
        "hooks": hooks,
        "masking_level": masking,
        "state": state,
        # Directories an agent may not write. Verifying a hook's digest at launch
        # does not stop an agent from rewriting it before the next hook runs, so the
        # security hook refuses these paths as well.
        "protected_paths": sorted({path for path in (store, state_root, state) if path}),
    }


def main(argv: list[str]) -> int:
    if len(argv) != 7:
        print(__doc__, file=sys.stderr)
        return 2
    print(json.dumps(render(*argv), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
