"""Render the resolved launch as JSON, launching nothing (LLD 3.2).

The adapter tests assert against this, so the exact argv can be proven without a
vendor binary installed. Environment values are never printed: this output is pasted
into issues and pull requests, and a dry run that leaks a token would be a worse
defect than the one it was diagnosing. Only names and counts appear.

Usage: python3 -m ihar.dryrun <vendor> <profile> <runtime> <kept> <dropped> -- <argv...>
"""

from __future__ import annotations

import json
import sys


def main(argv: list[str]) -> int:
    if "--" not in argv:
        print(__doc__, file=sys.stderr)
        return 2
    split = argv.index("--")
    head, command = argv[:split], argv[split + 1:]
    if len(head) != 5:
        print(__doc__, file=sys.stderr)
        return 2

    vendor, profile, runtime, kept, dropped = head
    report = {
        "vendor": vendor,
        "profile": profile,
        "runtime": runtime,
        "argv": command,
        "env": {
            "mode": "allowlist" if int(kept) else "inherit",
            "kept": int(kept),
            "dropped": sorted(name for name in dropped.split() if name),
        },
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
