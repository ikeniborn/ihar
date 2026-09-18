"""Report which masking engine would actually run.

`ihar check` prints this because "standard" backed by regexes alone is a weaker
promise than the same word backed by named-entity recognition, and a user comparing
two machines deserves to see which one they have.

Usage: python3 -m ihar.mask.describe [level]
"""

from __future__ import annotations

import sys

from .engine import Masker


def main(argv: list[str]) -> int:
    level = argv[0] if argv else "standard"
    try:
        print(Masker(level=level).describe()["engine"])
    except ValueError as error:
        print(f"ihar: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
