"""Discover vendor sessions and merge them into the canonical index (LLD 10.4)."""

from __future__ import annotations

import argparse
import json
import os

from ihar.codex.appserver import AppServer, AppServerError, DaemonClient
from ihar.sessions import claude, codex, index


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", required=True); parser.add_argument("--ephemeral")
    parser.add_argument("--cwd", required=True); parser.add_argument("--claude-home", required=True)
    parser.add_argument("--codex-home", required=True); parser.add_argument("--codex-binary")
    parser.add_argument("--daemon-socket")
    args = parser.parse_args(argv)
    claude_rows = claude.list_sessions(args.claude_home, args.cwd)
    codex_rows = []
    if args.daemon_socket and os.path.exists(args.daemon_socket):
        try:
            with DaemonClient(args.daemon_socket) as client: codex_rows = codex.list_appserver(client, args.cwd)
        except AppServerError:
            codex_rows = []
    if not codex_rows and args.codex_binary and os.path.isfile(args.codex_binary):
        try:
            with AppServer(args.codex_binary, args.codex_home) as client: codex_rows = codex.list_appserver(client, args.cwd)
        except (AppServerError, OSError):
            codex_rows = []
    if not codex_rows:
        codex_rows = codex.list_sqlite(os.path.join(args.codex_home, "state_5.sqlite"), args.cwd)
    rows = index.merge(args.index, claude_rows, codex_rows, index.ephemeral_ids(args.ephemeral))
    print(json.dumps(rows, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
