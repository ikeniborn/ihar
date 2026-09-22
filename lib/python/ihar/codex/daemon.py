"""The managed Codex app-server daemon (LLD 5.5).

The daemon is long-lived and shared, and Codex does not isolate per-client
environment: every client sees the environment the daemon inherited when it started.
So a daemon started for one configuration will happily serve a launch that asked for
another, and the only defence is to compare what is running against what this launch
needs, before the launch happens.

Slice S8 measured the vendor's daemon against the pinned 0.154.0 and found two things
the LLD did not say.

First, `codex app-server daemon start` refuses unless a *managed standalone install*
exists at `$CODEX_HOME/packages/standalone/current/codex`, the layout the official
installer produces — ihar installs a release tarball into its own store instead. A
symlink at that path pointing at the store binary is accepted, so the renderer makes
one; see `ihar_render_standalone_link`.

Second, `daemon start`, `daemon version` and `daemon stop` all answer with a JSON
object on stdout carrying `status`, `pid`, `socketPath`, `managedCodexPath`,
`managedCodexVersion`, `cliVersion` and `appServerVersion`. Reconciliation reads the
running version from there rather than inferring it, because the daemon may be running
a binary that has since been replaced on disk.

Failure class: the caller's. `reconcile` returns a decision; `ihar_codex_daemon_reconcile`
in lib/codex/daemon.sh is what aborts.
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import hashlib
import json
import os
import select
import subprocess
import sys
import time

from .. import jsonio
from . import auth_owner

RECORD_NAME = "codex.json"
STANDALONE_RELATIVE = os.path.join("packages", "standalone", "current", "codex")


def record_path(state: str) -> str:
    return os.path.join(state, "daemons", RECORD_NAME)


def _now() -> str:
    return _datetime.datetime.now(_datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


# --------------------------------------------------------------------------- #
# The vendor's own daemon subcommands
# --------------------------------------------------------------------------- #


def _daemon_call(binary: str, home: str, action: str, timeout: float = 120.0) -> dict:
    """`codex app-server daemon <action>`, whose answer is a JSON object on stdout.

    A non-zero exit is not raised here: `daemon version` exits non-zero precisely when
    no daemon is running, which is an answer rather than a failure.
    """
    completed = subprocess.run(
        [binary, "app-server", "daemon", action],
        env=dict(os.environ, CODEX_HOME=home),
        capture_output=True, text=True, timeout=timeout,
    )
    text = (completed.stdout or "").strip()
    if text:
        try:
            parsed = json.loads(text.splitlines()[-1])
            if isinstance(parsed, dict):
                return parsed
        except (json.JSONDecodeError, IndexError):
            pass
    return {"status": "absent", "error": (completed.stderr or "").strip()[:300],
            "exit": completed.returncode}


def status(binary: str, home: str) -> dict:
    return _daemon_call(binary, home, "version", timeout=30.0)


def start(binary: str, home: str, *, auth_store: str | None = None,
          config_hash: str = "") -> dict:
    if auth_store is None:
        return _daemon_call(binary, home, "start")
    auth_owner.require_descendant_supervision()
    auth_owner.verify_runtime_link(home, auth_store)
    guardian = subprocess.Popen(
        [sys.executable, "-m", "ihar.codex.auth_owner", "daemon-guardian",
         auth_store, home, config_hash, binary],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    assert guardian.stdout is not None
    try:
        if not select.select([guardian.stdout], [], [], 125)[0]:
            raise auth_owner.AuthOwnerError("Codex daemon guardian start timed out; owner retained")
        line = guardian.stdout.readline()
        if not line:
            raise auth_owner.AuthOwnerError("Codex daemon guardian exited without a start proof")
        result = json.loads(line)
        if not isinstance(result, dict) or "answer" not in result:
            raise auth_owner.AuthOwnerError(
                str(result.get("error", "Codex daemon start proof is invalid")))
        return result["answer"]
    except (ValueError, AttributeError) as error:
        raise auth_owner.AuthOwnerError("Codex daemon guardian start proof is invalid") from error
    finally:
        guardian.stdout.close()


def stop(binary: str, home: str, *, auth_store: str | None = None) -> dict:
    owner_id = (auth_owner.daemon_stop_owner_id(home, store=auth_store)
                if auth_store is not None else None)
    answer = _daemon_call(binary, home, "stop", timeout=60.0)
    if owner_id is not None:
        auth_owner.verify_runtime_link(home, auth_store)
        deadline = time.monotonic() + 3
        while True:
            try:
                auth_owner.release(owner_id, store=auth_store)
                break
            except auth_owner.AuthBusy:
                if time.monotonic() >= deadline:
                    raise auth_owner.AuthBusy("Codex daemon did not become quiescent after stop")
                time.sleep(0.05)
    return answer


def running(answer: dict) -> bool:
    return answer.get("status") in ("running", "started")


# --------------------------------------------------------------------------- #
# The record
# --------------------------------------------------------------------------- #


def read_record(state: str) -> dict | None:
    path = record_path(state)
    if not os.path.exists(path):
        return None
    try:
        return jsonio.read("daemon-record", path)
    except (OSError, jsonio.SchemaError):
        # A record ihar cannot read is a record ihar cannot claim the daemon from, and
        # claiming one it did not start is the mistake §5.5 exists to prevent.
        return None


def write_record(state: str, *, pid: int, socket_path: str, binary: str,
                 codex_version: str, config_hash: str, remote_control: bool = False) -> dict:
    record = {
        "schema": 1,
        "pid": pid,
        "socket": socket_path,
        "binary_sha256": sha256(binary),
        "codex_version": codex_version,
        "config_hash": config_hash,
        "started_at": _now(),
        "remote_control": remote_control,
    }
    path = record_path(state)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    jsonio.write("daemon-record", path, record)
    return record


def clear_record(state: str) -> None:
    try:
        os.unlink(record_path(state))
    except FileNotFoundError:
        pass


def mark_remote(state: str) -> dict:
    """Mark an existing managed daemon record as Remote Control enabled."""
    record = read_record(state)
    if record is None:
        raise ValueError("no managed daemon record")
    record["remote_control"] = True
    jsonio.write("daemon-record", record_path(state), record)
    return record


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


# --------------------------------------------------------------------------- #
# Reconciliation
# --------------------------------------------------------------------------- #

# The decisions, as data rather than as control flow, so the shell wrapper and the
# tests read the same four words the document uses.
NOTHING_TO_DO = "none"
RESTART = "restart"
REFUSE = "refuse"


def reconcile(binary: str, home: str, state: str, config_hash: str,
              *, auth_store: str | None = None) -> dict:
    """What this launch must do about whatever daemon is running.

    `none` — no daemon, or one that already matches.
    `restart` — a mismatch on a daemon ihar started, which ihar may stop.
    `refuse` — a mismatch on a daemon ihar did not start. Stopping someone else's
               daemon would take down their sessions, and serving the launch from it
               would apply a configuration nobody chose, so the launch aborts instead.
    """
    answer = status(binary, home)
    if not running(answer):
        # Nothing is listening, so a record is a leftover rather than a claim.
        clear_record(state)
        return {"action": NOTHING_TO_DO, "reason": "no daemon is running", "status": answer}

    if auth_store is not None:
        try:
            auth_owner.daemon_owner_id(home, store=auth_store)
        except auth_owner.AuthOwnerError:
            return {"action": REFUSE, "reason": "running daemon has no verified Codex auth owner",
                    "status": answer}

    record = read_record(state)
    ours = record is not None and alive(int(record.get("pid", 0) or 0))

    mismatches = []
    running_version = answer.get("managedCodexVersion") or answer.get("appServerVersion") or ""
    wanted_version = _cli_version(binary)
    if running_version and wanted_version and running_version != wanted_version:
        mismatches.append(f"version {running_version} running, {wanted_version} installed")
    if record is not None and record.get("config_hash") != config_hash:
        mismatches.append(f"configuration {record.get('config_hash')} running, {config_hash} wanted")
    if record is not None and os.path.exists(binary):
        try:
            if record.get("binary_sha256") != sha256(binary):
                mismatches.append("the binary on disk is not the one the daemon was started from")
        except OSError:
            pass
    if record is None:
        mismatches.append("a daemon is running that ihar has no record of")

    if not mismatches:
        return {"action": NOTHING_TO_DO, "reason": "the running daemon matches", "status": answer}
    if ours:
        return {"action": RESTART, "reason": "; ".join(mismatches), "status": answer}
    return {"action": REFUSE, "reason": "; ".join(mismatches), "status": answer}


def _cli_version(binary: str) -> str:
    try:
        completed = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return ""
    return (completed.stdout or "").strip().split()[-1] if completed.stdout.strip() else ""


def apply(binary: str, home: str, state: str, config_hash: str, decision: dict,
          *, auth_store: str | None = None) -> dict:
    """Carry out a `restart`. `none` and `refuse` are the caller's to act on."""
    if decision["action"] != RESTART:
        return decision
    stop(binary, home, auth_store=auth_store)
    clear_record(state)
    answer = start(binary, home, auth_store=auth_store, config_hash=config_hash)
    if not running(answer):
        return {"action": REFUSE, "reason": f"the daemon did not restart: {answer}", "status": answer}
    write_record(state, pid=int(answer.get("pid", 0) or 0),
                 socket_path=answer.get("socketPath", ""), binary=binary,
                 codex_version=answer.get("managedCodexVersion", "") or "unknown",
                 config_hash=config_hash)
    return {"action": "restarted", "reason": decision["reason"], "status": answer}


# --------------------------------------------------------------------------- #
# Update: stop what is running, put back only what was
# --------------------------------------------------------------------------- #

PENDING_NAME = "daemons-pending.json"


def _home_of(record: dict) -> str:
    """The CODEX_HOME a record's daemon serves, from the socket it recorded.

    Derived rather than stored, because the socket path is what the vendor itself
    reported at start: `<home>/app-server-control/app-server-control.sock`.
    """
    socket_path = record.get("socket") or ""
    return os.path.dirname(os.path.dirname(socket_path)) if socket_path else ""


def stop_all(binary: str, state_root: str, *, auth_store: str | None = None) -> list[dict]:
    """Stop every daemon ihar recorded, and leave a note of what to put back.

    The note is written before anything is stopped and removed only once everything
    has been restarted, so an update that dies halfway leaves evidence of the daemons
    it took down rather than silently losing them.
    """
    stopped = []
    for entry in sorted(os.listdir(state_root)) if os.path.isdir(state_root) else []:
        state = os.path.join(state_root, entry)
        record = read_record(state)
        if record is None:
            continue
        home = _home_of(record)
        if not home or not alive(int(record.get("pid", 0) or 0)):
            clear_record(state)
            continue
        stopped.append({"state": state, "home": home,
                        "config_hash": record.get("config_hash", "00000000")})

    pending = os.path.join(state_root, PENDING_NAME)
    if stopped:
        os.makedirs(state_root, exist_ok=True)
        with open(pending, "w", encoding="utf-8") as handle:
            json.dump(stopped, handle)
    for item in stopped:
        stop(binary, item["home"], auth_store=auth_store)
        clear_record(item["state"])
    return stopped


def start_pending(binary: str, state_root: str, *, auth_store: str | None = None) -> list[dict]:
    """Restart exactly the daemons `stop_all` took down, and nothing else."""
    pending = os.path.join(state_root, PENDING_NAME)
    if not os.path.exists(pending):
        return []
    try:
        with open(pending, encoding="utf-8") as handle:
            items = json.load(handle)
    except (OSError, json.JSONDecodeError):
        os.unlink(pending)
        return []

    restarted = []
    for item in items if isinstance(items, list) else []:
        answer = start(binary, item["home"], auth_store=auth_store,
                       config_hash=item.get("config_hash", "00000000"))
        if running(answer):
            write_record(item["state"], pid=int(answer.get("pid", 0) or 0),
                         socket_path=answer.get("socketPath", ""), binary=binary,
                         codex_version=answer.get("managedCodexVersion", "") or "unknown",
                         config_hash=item.get("config_hash", "00000000"))
        restarted.append({"home": item["home"], "status": answer.get("status", "absent")})
    os.unlink(pending)
    return restarted


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="ihar.codex.daemon")
    parser.add_argument("action", choices=("status", "start", "stop", "restart",
                                           "reconcile", "stop-all", "start-pending",
                                           "mark-remote"))
    parser.add_argument("--binary", required=True)
    parser.add_argument("--home")
    parser.add_argument("--state")
    parser.add_argument("--state-root")
    parser.add_argument("--config-hash", default="00000000")
    parser.add_argument("--auth-store")
    args = parser.parse_args(argv)

    if args.action in ("stop-all", "start-pending"):
        if not args.state_root:
            parser.error(f"{args.action} needs --state-root")
        worker = stop_all if args.action == "stop-all" else start_pending
        try:
            result = worker(args.binary, args.state_root, auth_store=args.auth_store)
        except auth_owner.AuthOwnerError as error:
            print(str(error), file=sys.stderr)
            return 3
        json.dump(result, sys.stdout)
        sys.stdout.write("\n")
        return 0

    if not args.home or not args.state:
        parser.error(f"{args.action} needs --home and --state")

    if args.action == "mark-remote":
        try:
            if args.auth_store is not None:
                auth_owner.daemon_owner_id(args.home, store=args.auth_store)
            answer = mark_remote(args.state)
        except (ValueError, auth_owner.AuthOwnerError) as error:
            print(str(error), file=sys.stderr)
            return 3
        json.dump(answer, sys.stdout)
        sys.stdout.write("\n")
        return 0

    if args.action == "status":
        answer = status(args.binary, args.home)
        record = read_record(args.state)
        json.dump({"status": answer, "record": record}, sys.stdout)
        sys.stdout.write("\n")
        return 0 if running(answer) else 1

    if args.action == "stop":
        try:
            answer = stop(args.binary, args.home, auth_store=args.auth_store)
        except auth_owner.AuthOwnerError as error:
            print(str(error), file=sys.stderr)
            return 3
        clear_record(args.state)
        json.dump(answer, sys.stdout)
        sys.stdout.write("\n")
        return 0

    if args.action in ("start", "restart"):
        try:
            if args.action == "restart":
                stop(args.binary, args.home, auth_store=args.auth_store)
                clear_record(args.state)
            answer = start(args.binary, args.home, auth_store=args.auth_store,
                           config_hash=args.config_hash)
        except auth_owner.AuthOwnerError as error:
            print(str(error), file=sys.stderr)
            return 3
        if not running(answer):
            json.dump(answer, sys.stdout)
            sys.stdout.write("\n")
            return 3
        write_record(args.state, pid=int(answer.get("pid", 0) or 0),
                     socket_path=answer.get("socketPath", ""), binary=args.binary,
                     codex_version=answer.get("managedCodexVersion", "") or "unknown",
                     config_hash=args.config_hash)
        json.dump(answer, sys.stdout)
        sys.stdout.write("\n")
        return 0

    decision = reconcile(args.binary, args.home, args.state, args.config_hash,
                         auth_store=args.auth_store)
    if decision["action"] == RESTART:
        try:
            decision = apply(args.binary, args.home, args.state, args.config_hash, decision,
                             auth_store=args.auth_store)
        except auth_owner.AuthOwnerError as error:
            print(str(error), file=sys.stderr)
            return 3
    json.dump(decision, sys.stdout)
    sys.stdout.write("\n")
    return 3 if decision["action"] == REFUSE else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
