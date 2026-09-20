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


def asset_entries(
    manifest: str | os.PathLike[str], vendor: str
) -> Iterator[tuple[str, str, str, bool, bool]]:
    document = jsonio.read("asset-manifest", manifest)
    for entry in document["entries"]:
        if vendor == "all" or entry["vendor"] in ("common", vendor):
            yield entry["source"], entry["target"], entry["kind"], entry["required"], entry["runtime"]


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[0] not in ("state", "assets"):
        return 2
    command, manifest, vendor = argv
    try:
        if command == "state":
            for path, kind in state_entries(manifest, vendor):
                print(f"{path}\t{kind}")
        else:
            for source, target, kind, required, runtime in asset_entries(manifest, vendor):
                print(f"{source}\t{target}\t{kind}\t{str(required).lower()}\t{str(runtime).lower()}")
    except (OSError, jsonio.SchemaError) as error:
        print(f"ihar: cannot read {command} inventory {manifest}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
