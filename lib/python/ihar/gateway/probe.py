"""Ask a gateway whether it is really ours (LLD 8.1, 8.5).

Exit 0 only when the answer carries the marker header. In transparent mode this is
the check that proves the interception is in place rather than the request having
reached the vendor: the probe path is in the gateway's local class precisely so it is
never forwarded.

Usage: python3 -m ihar.gateway.probe <port> [--url <url>]
"""

from __future__ import annotations

import sys
import urllib.error
import urllib.request


def probe(url: str, timeout: float = 2.0) -> int:
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if response.headers.get("x-ihar-gateway") != "1":
                print("the answer carries no ihar marker", file=sys.stderr)
                return 1
            return 0
    except (urllib.error.URLError, OSError, ValueError) as error:
        print(f"{error}", file=sys.stderr)
        return 1


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    if argv[0] == "--url" and len(argv) > 1:
        return probe(argv[1])
    return probe(f"http://127.0.0.1:{argv[0]}/api/ihar-probe")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
