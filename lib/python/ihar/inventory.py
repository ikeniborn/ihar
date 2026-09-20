"""Validated queries over ihar's canonical manifests."""

from __future__ import annotations

import os
import sys
from collections.abc import Iterator

from ihar import jsonio


def state_entries(
    manifest: str | os.PathLike[str], vendor: str
) -> Iterator[tuple[str, str]]:
    document = jsonio.read("state-manifest", manifest)
    for entry in document["entries"]:
        if entry["vendor"] == vendor:
            yield entry["path"], entry["kind"]


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[0] != "state":
        return 2
    _, manifest, vendor = argv
    try:
        for path, kind in state_entries(manifest, vendor):
            print(f"{path}\t{kind}")
    except (OSError, jsonio.SchemaError) as error:
        print(f"ihar: cannot read state inventory {manifest}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
