"""Protected Codex credential publication and supervised vendor ownership.

Publication needs the exclusive auth-owner lease and proven vendor quiescence.
"""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import stat
import sys
import time
import fcntl
import signal
import subprocess
import ctypes
from contextlib import ExitStack
from pathlib import Path


class AuthOwnerError(RuntimeError):
    """Credential ownership or publication could not be proved; fail closed."""


class ApprovalRequired(AuthOwnerError):
    """Replacing an existing credential needs direct human approval."""


class AuthBusy(AuthOwnerError):
    """Another verified Codex process still owns the shared login."""


_DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
_FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
_CREATE_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
_MARKER = ".ihar-stage"
_PENDING = ".auth-publish-pending"
_COMPLETE = ".auth-publish-complete"
_OWNER_RECORD = ".owner.json"
_OWNER_LOCK = ".owner.lock"


def _process_table() -> dict[int, dict]:
    """Observe process identities; an opaque table is never evidence of exit."""
    if sys.platform.startswith("linux"):
        result = {}
        try:
            entries = list(Path("/proc").iterdir())
        except OSError as error:
            raise AuthOwnerError("Codex process table cannot be read") from error
        for entry in entries:
            if not entry.name.isdecimal():
                continue
            try:
                raw = (entry / "stat").read_text()
                name = raw[raw.find("(") + 1 : raw.rfind(")")]
                tail = raw[raw.rfind(")") + 2 :].split()
                status, ppid, pgrp, start = tail[0], int(tail[1]), int(tail[2]), tail[19]
                uid = (entry / "status").read_text().split("Uid:\t", 1)[1].split()[0]
                if int(uid) != os.geteuid():
                    continue
                try:
                    exe = os.readlink(entry / "exe")
                    argv = (entry / "cmdline").read_bytes().split(b"\0")
                except PermissionError:
                    exe, argv = "", []
            except FileNotFoundError:
                continue
            except (OSError, ValueError, IndexError) as error:
                raise AuthOwnerError("Codex process identity cannot be verified") from error
            result[int(entry.name)] = {
                "pid": int(entry.name), "ppid": ppid, "pgrp": pgrp,
                "name": name,
                "start": start, "exe": exe.removesuffix(" (deleted)"),
                "argv": [os.fsdecode(arg) for arg in argv if arg], "status": status,
            }
        return result
    if sys.platform == "darwin":
        try:
            answer = subprocess.run(
                ["/bin/ps", "-axo", "pid=,uid=,ppid=,pgid=,lstart=,comm=,command="],
                capture_output=True, text=True, timeout=5, check=True,
            )
            result = {}
            for line in answer.stdout.splitlines():
                fields = line.split(None, 10)
                if len(fields) != 11 or int(fields[1]) != os.geteuid():
                    continue
                pid, _uid, ppid, pgrp = map(int, fields[:4])
                result[pid] = {
                    "pid": pid, "ppid": ppid, "pgrp": pgrp,
                    "name": Path(fields[9]).name,
                    "start": " ".join(fields[4:9]), "exe": fields[9],
                    "argv": fields[10].split(), "status": "R",
                }
            return result
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            raise AuthOwnerError("Codex process table cannot be read") from error
    raise AuthOwnerError("Codex process observation is unsupported on this platform")


def _identity_for(pid: int, binary: str | os.PathLike[str] | None = None) -> dict:
    observation = _process_table().get(pid)
    if observation is None or observation["status"] == "Z":
        raise AuthOwnerError("Codex process identity cannot be verified")
    expected = os.fspath(binary) if binary is not None else observation["exe"]
    if expected != observation["exe"] and expected not in observation["argv"]:
        raise AuthOwnerError("Codex process binary cannot be verified")
    return {"pid": pid, "start": observation["start"], "binary": expected,
            "pgrp": observation["pgrp"]}


def _identity_matches(identity: dict, table: dict[int, dict]) -> bool:
    item = table.get(identity.get("pid"))
    return bool(item and item["status"] != "Z"
                and item["start"] == identity.get("start")
                and (item["exe"] == identity.get("binary")
                     or identity.get("binary") in item["argv"]))


def owner_identity_proven(record: dict) -> bool:
    """A live guardian, child, or daemon must match start identity and binary."""
    table = _process_table()
    guardian = record.get("guardian")
    attached_guardian = record.get("attached_guardian")
    daemon = record.get("daemon")
    child = record.get("child")
    return bool((guardian and _identity_matches(guardian, table))
                or (attached_guardian and _identity_matches(attached_guardian, table))
                or (daemon and _identity_matches(daemon, table))
                or (child and _identity_matches(child, table)))


def owner_is_active(record: dict) -> bool:
    table = _process_table()
    for identity in (record.get("guardian"), record.get("attached_guardian"),
                     record.get("child"), record.get("daemon")):
        if identity and _identity_matches(identity, table):
            return True
    for identity in (record.get("child"), record.get("daemon")):
        if identity and any(item["pgrp"] == identity["pgrp"] and item["status"] != "Z"
                            for item in table.values()):
            return True
    return False


def _daemon_socket_proven(record: dict) -> bool:
    identity = record.get("daemon")
    if not identity:
        return False
    try:
        metadata = os.stat(identity["socket"], follow_symlinks=False)
    except (OSError, KeyError):
        return False
    return (stat.S_ISSOCK(metadata.st_mode)
            and (metadata.st_dev, metadata.st_ino)
            == (identity.get("socket_dev"), identity.get("socket_ino")))


def verify_runtime_link(runtime: str | os.PathLike[str], store: str | os.PathLike[str]) -> None:
    target = Path(os.path.abspath(runtime)) / "auth.json"
    canonical = _lease_store(store) / "auth" / "codex" / "auth.json"
    try:
        metadata = os.lstat(target)
        linked = os.readlink(target)
    except OSError as error:
        raise AuthOwnerError("Codex runtime mutable link cannot be verified") from error
    if not stat.S_ISLNK(metadata.st_mode) or linked != str(canonical):
        raise AuthOwnerError("Codex runtime mutable link changed; preserved for recovery")
    with ExitStack() as stack:
        _root, _auth, owner = _owner_directories(_lease_store(store), stack, create=False)
        _guard_no_pending(owner)
        _canonical_identity(owner)


def _external_consumer_present(store: Path, table: dict[int, dict]) -> bool:
    canonical = str(store / "auth" / "codex" / "auth.json")
    for pid, item in table.items():
        if pid == os.getpid() or item["status"] == "Z":
            continue
        names = [item.get("name", ""), Path(item["exe"]).name]
        names.extend(Path(argument).name for argument in item["argv"][:3])
        if not any(name == "codex" or name.startswith("codex-")
                   or name.endswith("-codex") for name in names):
            continue
        try:
            if sys.platform.startswith("linux"):
                environment = (Path("/proc") / str(pid) / "environ").read_bytes().split(b"\0")
                home = next((os.fsdecode(value[11:]) for value in environment
                             if value.startswith(b"CODEX_HOME=")), None)
            else:
                answer = subprocess.run(["/bin/ps", "-Eww", "-p", str(pid), "-o", "command="],
                                        capture_output=True, text=True, timeout=5)
                if answer.returncode != 0:
                    raise AuthOwnerError("external Codex consumer cannot be verified")
                marker = "CODEX_HOME="
                home = next((part[len(marker):] for part in answer.stdout.split()
                             if part.startswith(marker)), None)
        except FileNotFoundError:
            continue
        except (OSError, subprocess.SubprocessError) as error:
            raise AuthOwnerError("external Codex consumer cannot be verified") from error
        if not home:
            continue
        if not os.path.isabs(home):
            raise AuthOwnerError("external Codex consumer runtime cannot be verified")
        if os.path.abspath(home) == str(store / "auth" / "codex"):
            return True
        try:
            if os.readlink(os.path.join(home, "auth.json")) == canonical:
                return True
        except FileNotFoundError:
            continue
        except OSError as error:
            if os.path.exists(os.path.join(home, "auth.json")):
                raise AuthOwnerError("external Codex consumer auth path cannot be verified") from error
    return False


def _lease_store(store: str | os.PathLike[str] | None) -> Path:
    selected = store or os.environ.get("IHAR_STORE")
    if not selected:
        raise AuthOwnerError("Codex auth store is not configured")
    return Path(os.path.abspath(selected))


def _locked_owner(store: Path, stack: ExitStack) -> int:
    _root, _auth, owner = _owner_directories(store, stack, create=True)
    descriptor = os.open(_OWNER_LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
                         0o600, dir_fd=owner)
    stack.callback(os.close, descriptor)
    metadata = os.fstat(descriptor)
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600):
        raise AuthOwnerError("Codex auth lock is unsafe")
    deadline = time.monotonic() + 2
    while True:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise AuthBusy("Codex auth owner is busy (2-second admission bound)")
            time.sleep(0.05)
    return owner


def _read_owner(owner: int) -> dict | None:
    try:
        descriptor = os.open(_OWNER_RECORD, _FILE_FLAGS, dir_fd=owner)
    except FileNotFoundError:
        return None
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_size > 8192):
            raise AuthOwnerError("Codex auth owner record is unsafe")
        record = json.loads(os.read(descriptor, 8193))
        if not isinstance(record, dict) or record.get("schema") != 1:
            raise AuthOwnerError("Codex auth owner record is invalid")
        return record
    except (ValueError, OSError) as error:
        raise AuthOwnerError("Codex auth owner record cannot be verified") from error
    finally:
        os.close(descriptor)


def _write_owner(owner: int, record: dict) -> None:
    temporary = f".owner-{secrets.token_hex(8)}"
    descriptor = os.open(temporary, _CREATE_FLAGS, 0o600, dir_fd=owner)
    try:
        _write_all(descriptor, json.dumps(record, sort_keys=True).encode("ascii"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, _OWNER_RECORD, src_dir_fd=owner, dst_dir_fd=owner)
    os.fsync(owner)


def acquire(runtime: str | os.PathLike[str], mode: str, *,
            store: str | os.PathLike[str] | None = None,
            attached_daemon_id: str | None = None, config_hash: str = "") -> str:
    """Admit one writer, or attach only to the exact verified daemon owner."""
    if mode not in ("foreground", "daemon", "attached", "auth"):
        raise AuthOwnerError("Codex auth lease mode is invalid")
    runtime_path = os.path.abspath(runtime)
    with ExitStack() as stack:
        owner = _locked_owner(_lease_store(store), stack)
        _guard_no_pending(owner)
        existing = _read_owner(owner)
        if existing is not None:
            if not owner_identity_proven(existing):
                raise AuthOwnerError("Codex auth owner cannot be verified")
            if owner_is_active(existing):
                if (attached_daemon_id != existing.get("id")
                    or runtime_path != existing.get("runtime")
                    or not _daemon_socket_proven(existing)
                    or (config_hash and config_hash != existing.get("config_hash"))):
                    raise AuthBusy("another Codex runtime owns the shared login")
                if existing.get("attached_guardian") or existing.get("child"):
                    raise AuthBusy("another attached Codex client is unresolved")
                existing["attached_guardian"] = _identity_for(os.getpid())
                _write_owner(owner, existing)
                return existing["id"]
            if attached_daemon_id is not None:
                raise AuthOwnerError("Codex daemon auth owner is no longer active")
            raise AuthOwnerError("Codex auth owner quiescence cannot be verified")
        if mode == "attached":
            raise AuthOwnerError("Codex daemon auth owner is missing")
        if _external_consumer_present(_lease_store(store), _process_table()):
            raise AuthBusy("external Codex consumer may own the shared login")
        owner_id = secrets.token_hex(16)
        record = {"schema": 1, "id": owner_id, "runtime": runtime_path,
                  "config_hash": config_hash, "mode": mode,
                  "guardian": _identity_for(os.getpid()), "child": None, "daemon": None,
                  "attached_guardian": None,
                  "state": "active"}
        _write_owner(owner, record)
        return owner_id


def _update_owner(owner_id: str, update, *, store: str | os.PathLike[str] | None = None) -> None:
    with ExitStack() as stack:
        owner = _locked_owner(_lease_store(store), stack)
        record = _read_owner(owner)
        if record is None or record.get("id") != owner_id:
            raise AuthOwnerError("Codex auth owner ID does not match")
        update(record, owner)


def bind_child(owner_id: str, pid: int, binary: str | os.PathLike[str], *,
               store: str | os.PathLike[str] | None = None) -> None:
    def update(record: dict, owner: int) -> None:
        table = _process_table()
        if not (_identity_matches(record["guardian"], table)
                or (record.get("attached_guardian")
                    and _identity_matches(record["attached_guardian"], table))):
            raise AuthOwnerError("Codex auth guardian cannot be verified")
        record["child"] = _identity_for(pid, binary)
        _write_owner(owner, record)
    _update_owner(owner_id, update, store=store)


def daemon_owner_id(runtime: str | os.PathLike[str], *,
                    store: str | os.PathLike[str] | None = None) -> str:
    with ExitStack() as stack:
        owner = _locked_owner(_lease_store(store), stack)
        record = _read_owner(owner)
        if (record is None or record.get("runtime") != os.path.abspath(runtime)
            or not owner_identity_proven(record) or not _daemon_socket_proven(record)
            or not owner_is_active(record)):
            raise AuthOwnerError("Codex daemon auth owner cannot be verified")
        return record["id"]


def daemon_stop_owner_id(runtime: str | os.PathLike[str], *,
                         store: str | os.PathLike[str] | None = None) -> str:
    """Allow a bounded stop retry after daemon exit while retaining the lease."""
    with ExitStack() as stack:
        owner = _locked_owner(_lease_store(store), stack)
        record = _read_owner(owner)
        if (record is None or record.get("runtime") != os.path.abspath(runtime)
            or record.get("mode") != "daemon" or not record.get("daemon")
            or (record.get("state") != "quiescent" and not owner_identity_proven(record))):
            raise AuthOwnerError("Codex daemon auth owner cannot be verified")
        return record["id"]


def bind_daemon(owner_id: str, pid: int, socket: str | os.PathLike[str],
                binary: str | os.PathLike[str], *,
                store: str | os.PathLike[str] | None = None) -> None:
    def update(record: dict, owner: int) -> None:
        if not _identity_matches(record["guardian"], _process_table()):
            raise AuthOwnerError("Codex auth guardian cannot be verified")
        identity = _identity_for(pid, binary)
        expected_socket = os.path.join(record["runtime"], "app-server-control",
                                       "app-server-control.sock")
        if os.path.abspath(socket) != expected_socket or identity["pgrp"] != pid:
            raise AuthOwnerError("Codex daemon process or socket identity is not isolated")
        socket_stat = os.stat(socket, follow_symlinks=False)
        if not stat.S_ISSOCK(socket_stat.st_mode):
            raise AuthOwnerError("Codex daemon socket cannot be verified")
        record["daemon"] = dict(identity, socket=os.path.abspath(socket),
                                socket_dev=socket_stat.st_dev, socket_ino=socket_stat.st_ino)
        record["mode"] = "daemon"
        _write_owner(owner, record)
    _update_owner(owner_id, update, store=store)


def mark_daemon_quiescent(owner_id: str, *,
                          store: str | os.PathLike[str] | None = None) -> None:
    """Only the live guardian may certify daemon and descendant exit."""
    def update(record: dict, owner: int) -> None:
        guardian = record.get("guardian")
        if (not guardian or guardian["pid"] != os.getpid()
            or not _identity_matches(guardian, _process_table())
            or not record.get("daemon")):
            raise AuthOwnerError("Codex daemon guardian cannot be verified")
        _reap_children()
        if (_group_active(record["daemon"])
            or _descendants_active(os.getpid())):
            raise AuthBusy("Codex daemon descendants are still active")
        record["state"] = "quiescent"
        _write_owner(owner, record)
    _update_owner(owner_id, update, store=store)


def release(owner_id: str, *, store: str | os.PathLike[str] | None = None) -> None:
    def update(record: dict, owner: int) -> None:
        if record.get("daemon") and record.get("state") != "quiescent":
            raise AuthBusy("Codex daemon quiescence has not been verified")
        if record.get("attached_guardian"):
            raise AuthBusy("Codex attached client is unresolved")
        if record.get("child") and owner_is_active(dict(record, guardian=None, daemon=None)):
            raise AuthBusy("Codex auth child is still active")
        if record.get("daemon") and owner_is_active(dict(record, guardian=None, child=None)):
            raise AuthBusy("Codex daemon is still active")
        os.unlink(_OWNER_RECORD, dir_fd=owner)
        os.fsync(owner)
    _update_owner(owner_id, update, store=store)


def detach(owner_id: str, *, store: str | os.PathLike[str] | None = None) -> None:
    def update(record: dict, owner: int) -> None:
        identity = record.get("attached_guardian")
        if not identity or identity["pid"] != os.getpid() or not _identity_matches(identity, _process_table()):
            raise AuthOwnerError("Codex attached client guardian cannot be verified")
        if record.get("child") and owner_is_active(dict(record, guardian=None,
                                                          attached_guardian=None, daemon=None)):
            raise AuthBusy("Codex attached client is still active")
        record["attached_guardian"] = None
        record["child"] = None
        _write_owner(owner, record)
    _update_owner(owner_id, update, store=store)


def _group_active(identity: dict) -> bool:
    return any(item["pgrp"] == identity["pgrp"] and item["status"] != "Z"
               for item in _process_table().values())


def require_descendant_supervision() -> None:
    """Refuse vendor launch when escaped descendants cannot be accounted for."""
    if not sys.platform.startswith("linux"):
        raise AuthOwnerError("Codex descendant supervision cannot be proved on this platform")
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
            raise AuthOwnerError("Codex descendant supervision cannot be enabled")
    except (OSError, AttributeError) as error:
        raise AuthOwnerError("Codex descendant supervision cannot be enabled") from error


def _descendants_active(guardian_pid: int) -> bool:
    table = _process_table()
    known = {guardian_pid}
    found = False
    changed = True
    while changed:
        changed = False
        for item in table.values():
            if item["ppid"] in known and item["pid"] not in known:
                known.add(item["pid"])
                found = found or item["status"] != "Z"
                changed = True
    return found


def _reap_children() -> None:
    while True:
        try:
            pid, _status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            return


def _daemon_guardian(arguments: list[str]) -> int:
    """Start a managed daemon, answer once, then remain its subreaper."""
    if len(arguments) != 4:
        raise AuthOwnerError("Codex daemon guardian invocation is invalid")
    store_name, runtime, config_hash, binary = arguments
    store = _lease_store(store_name)
    owner_id = None
    bound = False
    try:
        require_descendant_supervision()
        verify_runtime_link(runtime, store)
        owner_id = acquire(runtime, "daemon", store=store, config_hash=config_hash)
        from . import daemon
        answer = daemon._daemon_call(binary, runtime, "start")
        if not daemon.running(answer):
            raise AuthOwnerError("Codex daemon start did not prove a running daemon")
        socket_path = answer.get("socketPath", "")
        for _ in range(60):
            if os.path.exists(socket_path):
                break
            time.sleep(0.05)
        bind_daemon(owner_id, int(answer.get("pid", 0) or 0), socket_path,
                    binary, store=store)
        verify_runtime_link(runtime, store)
        bound = True
        print(json.dumps({"answer": answer}), flush=True)
    except (AuthOwnerError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({"error": str(error)}), flush=True)
    finally:
        # The caller's captured pipe must close while the guardian keeps running.
        sys.stdout.flush()
        descriptor = os.open(os.devnull, os.O_WRONLY)
        os.dup2(descriptor, sys.stdout.fileno())
        os.close(descriptor)
    if owner_id is None:
        return 3
    if not bound:
        # Unknown start outcome is never a release proof, even after child exit.
        while True:
            _reap_children()
            if not _descendants_active(os.getpid()):
                return 3
            time.sleep(0.05)
    while True:
        _reap_children()
        try:
            mark_daemon_quiescent(owner_id, store=store)
        except AuthBusy:
            time.sleep(0.05)
        except AuthOwnerError:
            return 3
        else:
            return 0


def _run_vendor(owner_id: str, command: list[str], *, store: Path,
                environment: dict[str, str]) -> int:
    require_descendant_supervision()
    process = subprocess.Popen(command, env=environment, start_new_session=True)
    try:
        try:
            bind_child(owner_id, process.pid, command[0], store=store)
        except AuthOwnerError:
            try:
                process.wait(timeout=0.05)
            except subprocess.TimeoutExpired:
                pass
            if _group_active({"pgrp": process.pid}):
                raise
        def forward(number: int, _frame: object) -> None:
            try:
                os.killpg(process.pid, number)
            except ProcessLookupError:
                pass
        previous = {number: signal.signal(number, forward) for number in (signal.SIGINT, signal.SIGTERM)}
        try:
            status = process.wait()
            while True:
                _reap_children()
                if not (_group_active({"pgrp": process.pid}) or _descendants_active(os.getpid())):
                    break
                time.sleep(0.05)
        finally:
            for number, handler in previous.items():
                signal.signal(number, handler)
        return 128 - status if status < 0 else status
    finally:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            process.wait()


def _direct_approval(action: str) -> bool:
    try:
        with open("/dev/tty", "r+", encoding="utf-8") as terminal:
            if action == "logout":
                terminal.write("Logging out removes the shared Codex login. Type logout to continue: ")
            else:
                terminal.write("Replacing the shared Codex login may invalidate the old token remotely. Type replace to continue: ")
            terminal.flush()
            return terminal.readline().strip() == action
    except OSError:
        return False


def _seed_stage_from_canonical(staged: Path, store: Path) -> None:
    with ExitStack() as stack:
        root, _auth, owner = _owner_directories(store, stack, create=False)
        stage_fd, _token, _record = _validated_stage(staged, store, root, owner, stack)
        source = os.open("auth.json", _FILE_FLAGS, dir_fd=owner)
        stack.callback(os.close, source)
        _identity(source)
        target = os.open("auth.json", _CREATE_FLAGS, 0o600, dir_fd=stage_fd)
        stack.callback(os.close, target)
        _copy_file(source, target)
        os.fsync(stage_fd)


def _logout_canonical(staged: Path, store: Path) -> None:
    with ExitStack() as stack:
        root, _auth, owner = _owner_directories(store, stack, create=False)
        _guard_no_pending(owner)
        stage_fd, token, marker = _validated_stage(staged, store, root, owner, stack)
        if marker["baseline"] != _canonical_identity(owner):
            raise AuthOwnerError("Codex credential owner changed before logout")
        try:
            os.stat("auth.json", dir_fd=stage_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise AuthOwnerError("Codex logout did not remove staged credential")
        recovery_root = _private_directory(owner, "recovery", stack, create=True)
        recovery = _private_directory(recovery_root, token, stack, create=True)
        source = os.open("auth.json", _FILE_FLAGS, dir_fd=owner)
        stack.callback(os.close, source)
        source_identity = _identity(source)
        backup = os.open("auth.json", _CREATE_FLAGS, 0o600, dir_fd=recovery)
        stack.callback(os.close, backup)
        _copy_file(source, backup)
        os.fsync(recovery)
        os.fsync(recovery_root)
        if source_identity != _identity(source) or marker["baseline"] != _canonical_identity(owner):
            raise AuthOwnerError("Codex credential owner changed during logout")
        _write_pending(owner, token)
        os.unlink("auth.json", dir_fd=owner)
        os.fsync(owner)
        os.replace(_PENDING, _COMPLETE, src_dir_fd=owner, dst_dir_fd=owner)
        os.fsync(owner)
        os.unlink(_COMPLETE, dir_fd=owner)
        os.fsync(owner)


def _main(arguments: list[str]) -> int:
    if arguments and arguments[0] == "daemon-guardian":
        return _daemon_guardian(arguments[1:])
    if len(arguments) < 6 or arguments[0] not in ("run", "auth") or "--" not in arguments:
        raise AuthOwnerError("Codex auth owner invocation is invalid")
    action, store_name, runtime_name = arguments[:3]
    separator = arguments.index("--")
    command = arguments[separator + 1 :]
    if not command:
        raise AuthOwnerError("Codex command is missing")
    store = _lease_store(store_name)
    require_descendant_supervision()
    environment = dict(os.environ)
    environment.pop("PYTHONPATH", None)
    if action == "run":
        if separator != 5:
            raise AuthOwnerError("Codex owner run arguments are invalid")
        config_hash, mode = arguments[3:5]
        verify_runtime_link(runtime_name, store)
        attached_id = daemon_owner_id(runtime_name, store=store) if mode == "attached" else None
        owner_id = acquire(runtime_name, mode, store=store,
                           attached_daemon_id=attached_id, config_hash=config_hash)
        status = _run_vendor(owner_id, command, store=store, environment=environment)
        verify_runtime_link(runtime_name, store)
        if mode == "attached":
            detach(owner_id, store=store)
        else:
            release(owner_id, store=store)
        return status
    if separator != 3 or command[1:2] not in (["login"], ["logout"]):
        raise AuthOwnerError("Codex authentication verb is invalid")
    owner_id = acquire(runtime_name, "auth", store=store)
    try:
        staged = stage(store)
        canonical = store / "auth" / "codex" / "auth.json"
        existing = canonical.exists()
        verb = "status" if command[1:3] == ["login", "status"] else command[1]
        if verb == "logout" and not existing:
            raise AuthOwnerError("Codex shared login is already absent")
        if existing and verb != "status" and not _direct_approval("logout" if verb == "logout" else "replace"):
            raise ApprovalRequired("existing Codex credential needs direct TTY approval")
        if verb in ("status", "logout") and existing:
            _seed_stage_from_canonical(staged, store)
        environment["CODEX_HOME"] = str(staged)
        status = _run_vendor(owner_id, command, store=store, environment=environment)
        if status != 0:
            return status
        if verb == "login":
            publish(staged, store, approve_existing=existing)
        elif verb == "logout":
            _logout_canonical(staged, store)
        return 0
    finally:
        release(owner_id, store=store)


def _open_store(store: Path, stack: ExitStack) -> int:
    path = Path(os.path.abspath(store))
    descriptor = os.open(os.path.sep, _DIR_FLAGS)
    stack.callback(os.close, descriptor)
    for part in path.parts[1:]:
        child = os.open(part, _DIR_FLAGS, dir_fd=descriptor)
        stack.callback(os.close, child)
        descriptor = child
    metadata = os.fstat(descriptor)
    if metadata.st_uid != os.geteuid():
        raise AuthOwnerError("Codex credential store must belong to current user")
    return descriptor


def _private_directory(parent: int, name: str, stack: ExitStack, *, create: bool) -> int:
    made = False
    if create:
        try:
            os.mkdir(name, mode=0o700, dir_fd=parent)
            made = True
        except FileExistsError:
            pass
    descriptor = os.open(name, _DIR_FLAGS, dir_fd=parent)
    stack.callback(os.close, descriptor)
    if made:
        os.fchmod(descriptor, 0o700)
        os.fsync(parent)
    metadata = os.fstat(descriptor)
    if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise AuthOwnerError("Codex credential owner directory must be mode 0700")
    return descriptor


def _owner_directories(store: Path, stack: ExitStack, *, create: bool) -> tuple[int, int, int]:
    root = _open_store(store, stack)
    auth = _private_directory(root, "auth", stack, create=create)
    owner = _private_directory(auth, "codex", stack, create=create)
    return root, auth, owner


def _identity(descriptor: int) -> dict[str, int | str]:
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid() or before.st_nlink != 1:
        raise AuthOwnerError("Codex credential must be an owned regular file")
    digest = hashlib.sha256()
    os.lseek(descriptor, 0, os.SEEK_SET)
    while chunk := os.read(descriptor, 65536):
        digest.update(chunk)
    after = os.fstat(descriptor)
    fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, field) != getattr(after, field) for field in fields):
        raise AuthOwnerError("Codex credential changed while being checked")
    return {
        "dev": after.st_dev,
        "ino": after.st_ino,
        "size": after.st_size,
        "mtime_ns": after.st_mtime_ns,
        "ctime_ns": after.st_ctime_ns,
        "sha256": digest.hexdigest(),
    }


def _canonical_identity(owner: int) -> dict[str, int | str] | None:
    try:
        descriptor = os.open("auth.json", _FILE_FLAGS, dir_fd=owner)
    except FileNotFoundError:
        return None
    with os.fdopen(descriptor, "rb", closefd=True) as handle:
        result = _identity(handle.fileno())
        metadata = os.stat("auth.json", dir_fd=owner, follow_symlinks=False)
        if (metadata.st_dev, metadata.st_ino) != (result["dev"], result["ino"]):
            raise AuthOwnerError("Codex credential owner changed during inspection")
        return result


def _copy_file(source: int, target: int) -> None:
    os.lseek(source, 0, os.SEEK_SET)
    while chunk := os.read(source, 65536):
        _write_all(target, chunk)
    os.fsync(target)


def _write_all(descriptor: int, content: bytes) -> None:
    view = memoryview(content)
    while view:
        view = view[os.write(descriptor, view):]


def _write_marker(stage_fd: int, record: dict) -> None:
    descriptor = os.open(_MARKER, _CREATE_FLAGS, 0o600, dir_fd=stage_fd)
    try:
        payload = json.dumps(record, sort_keys=True).encode("ascii")
        _write_all(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.fsync(stage_fd)


def _guard_no_pending(owner: int) -> None:
    for name in (_PENDING, _COMPLETE):
        try:
            os.stat(name, dir_fd=owner, follow_symlinks=False)
        except FileNotFoundError:
            continue
        raise AuthOwnerError("Codex auth publication needs manual recovery")


def _write_pending(owner: int, token: str) -> None:
    descriptor = os.open(_PENDING, _CREATE_FLAGS, 0o600, dir_fd=owner)
    try:
        _write_all(descriptor, token.encode("ascii"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.fsync(owner)


def _read_marker(stage_fd: int) -> dict:
    descriptor = os.open(_MARKER, _FILE_FLAGS, dir_fd=stage_fd)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid():
            raise AuthOwnerError("Codex auth stage marker is not an owned regular file")
        if metadata.st_size > 4096 or stat.S_IMODE(metadata.st_mode) != 0o600:
            raise AuthOwnerError("Codex auth stage marker is invalid")
        record = json.loads(os.read(descriptor, 4097))
        if not isinstance(record, dict):
            raise ValueError("invalid marker")
        return record
    finally:
        os.close(descriptor)


def stage(store: str | os.PathLike[str]) -> Path:
    """Create a private real-file CODEX_HOME for one human login attempt.

    Raises AuthOwnerError without returning a staging path on unsafe topology.
    """
    store_path = Path(os.path.abspath(store))
    try:
        with ExitStack() as stack:
            root, _auth, owner = _owner_directories(store_path, stack, create=True)
            _guard_no_pending(owner)
            stages = _private_directory(owner, "staging", stack, create=True)
            baseline = _canonical_identity(owner)
            token = secrets.token_hex(16)
            stage_fd = _private_directory(stages, token, stack, create=True)
            record = {
                "schema": 1,
                "token": token,
                "store": [os.fstat(root).st_dev, os.fstat(root).st_ino],
                "stage": [os.fstat(stage_fd).st_dev, os.fstat(stage_fd).st_ino],
                "baseline": baseline,
            }
            _write_marker(stage_fd, record)
            os.fsync(stages)
            return store_path / "auth" / "codex" / "staging" / token
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise AuthOwnerError("Codex auth staging topology or durability check failed") from error


def _validated_stage(
    stage_path: Path, store_path: Path, root: int, owner: int, stack: ExitStack
) -> tuple[int, str, dict]:
    expected_parent = store_path / "auth" / "codex" / "staging"
    token = stage_path.name
    if (
        stage_path.parent != expected_parent
        or len(token) != 32
        or any(c not in "0123456789abcdef" for c in token)
    ):
        raise AuthOwnerError("Codex auth stage does not belong to this owner")
    stages = _private_directory(owner, "staging", stack, create=False)
    stage_fd = _private_directory(stages, token, stack, create=False)
    record = _read_marker(stage_fd)
    if (
        record.get("schema") != 1
        or record.get("token") != token
        or record.get("store") != [os.fstat(root).st_dev, os.fstat(root).st_ino]
        or record.get("stage") != [os.fstat(stage_fd).st_dev, os.fstat(stage_fd).st_ino]
        or "baseline" not in record
    ):
        raise AuthOwnerError("Codex auth stage provenance is invalid")
    return stage_fd, token, record


def _same_published_file(owner: int, published: os.stat_result) -> bool:
    try:
        current = os.stat("auth.json", dir_fd=owner, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return (current.st_dev, current.st_ino) == (published.st_dev, published.st_ino)


def _rollback(
    owner: int,
    recovery: int | None,
    token: str,
    published: os.stat_result,
    baseline: dict[str, int | str] | None,
) -> None:
    if not _same_published_file(owner, published):
        raise AuthOwnerError("Codex auth owner changed; manual recovery required")
    if recovery is None:
        os.unlink("auth.json", dir_fd=owner)
    else:
        rollback_name = f".auth-rollback-{token}"
        source = os.open("auth.json", _FILE_FLAGS, dir_fd=recovery)
        try:
            source_identity = _identity(source)
            if baseline is None or any(
                source_identity[field] != baseline[field] for field in ("size", "sha256")
            ):
                raise AuthOwnerError("Codex auth recovery copy changed")
            target = os.open(rollback_name, _CREATE_FLAGS, 0o600, dir_fd=owner)
            try:
                _copy_file(source, target)
            finally:
                os.close(target)
            if _identity(source) != source_identity:
                raise AuthOwnerError("Codex auth recovery copy changed during rollback")
        finally:
            os.close(source)
        os.replace(rollback_name, "auth.json", src_dir_fd=owner, dst_dir_fd=owner)
    os.fsync(owner)


def publish(
    stage_path: str | os.PathLike[str], store: str | os.PathLike[str], *, approve_existing: bool
) -> None:
    """Publish a quiescent staged credential, retaining prior bytes for recovery.

    Existing credentials need ``approve_existing is True``. A missing staged
    file never means logout. A failed commit restores the prior owner when it
    can prove the exact published inode; otherwise the pending marker blocks
    reuse for manual recovery. The caller owns the exclusive writer lease.
    """
    store_path = Path(os.path.abspath(store))
    supplied_stage = Path(os.path.abspath(stage_path))
    try:
        with ExitStack() as stack:
            root, _auth, owner = _owner_directories(store_path, stack, create=False)
            _guard_no_pending(owner)
            stage_fd, token, record = _validated_stage(
                supplied_stage, store_path, root, owner, stack
            )
            baseline = record["baseline"]
            if baseline != _canonical_identity(owner):
                raise AuthOwnerError("Codex credential owner changed since staging")
            if baseline is not None and approve_existing is not True:
                raise ApprovalRequired("existing Codex credential requires direct user approval")
            candidate_fd = os.open("auth.json", _FILE_FLAGS, dir_fd=stage_fd)
            stack.callback(os.close, candidate_fd)
            candidate_before = _identity(candidate_fd)
            candidate_stat = os.stat("auth.json", dir_fd=stage_fd, follow_symlinks=False)
            if not stat.S_ISREG(candidate_stat.st_mode) or stat.S_ISLNK(candidate_stat.st_mode):
                raise AuthOwnerError("staged Codex credential is not a regular file")
            if (candidate_stat.st_dev, candidate_stat.st_ino) != (
                candidate_before["dev"], candidate_before["ino"]
            ):
                raise AuthOwnerError("staged Codex credential changed during inspection")
            os.fsync(candidate_fd)
            os.fsync(stage_fd)
            if _identity(candidate_fd) != candidate_before:
                raise AuthOwnerError("staged Codex credential changed during sync")

            recovery_fd = None
            if baseline is not None:
                recovery_root = _private_directory(owner, "recovery", stack, create=True)
                recovery_fd = _private_directory(recovery_root, token, stack, create=True)
                old_fd = os.open("auth.json", _FILE_FLAGS, dir_fd=owner)
                stack.callback(os.close, old_fd)
                if _identity(old_fd) != baseline:
                    raise AuthOwnerError("Codex credential owner changed before recovery")
                backup_fd = os.open("auth.json", _CREATE_FLAGS, 0o600, dir_fd=recovery_fd)
                stack.callback(os.close, backup_fd)
                _copy_file(old_fd, backup_fd)
                if _identity(old_fd) != baseline:
                    raise AuthOwnerError("Codex credential owner changed during recovery")
                os.fsync(recovery_fd)
                os.fsync(recovery_root)

            temporary = f".auth-publish-{token}"
            published_fd = os.open(temporary, _CREATE_FLAGS, 0o600, dir_fd=owner)
            stack.callback(os.close, published_fd)
            _copy_file(candidate_fd, published_fd)
            published = os.fstat(published_fd)
            if _identity(candidate_fd) != candidate_before:
                raise AuthOwnerError("staged Codex credential changed during publication")
            if baseline != _canonical_identity(owner):
                raise AuthOwnerError("Codex credential owner changed before publication")

            _write_pending(owner, token)
            os.replace(_MARKER, ".ihar-used", src_dir_fd=stage_fd, dst_dir_fd=stage_fd)
            os.fsync(stage_fd)
            committed = False
            try:
                if baseline is None:
                    os.link(
                        temporary, "auth.json",
                        src_dir_fd=owner, dst_dir_fd=owner, follow_symlinks=False,
                    )
                else:
                    os.replace(temporary, "auth.json", src_dir_fd=owner, dst_dir_fd=owner)
                committed = True
                if baseline is None:
                    os.unlink(temporary, dir_fd=owner)
                os.fsync(owner)
            except OSError as error:
                if committed:
                    try:
                        _rollback(owner, recovery_fd, token, published, baseline)
                    except (OSError, AuthOwnerError) as rollback_error:
                        raise AuthOwnerError(
                            "Codex auth publication and rollback failed; recovery retained"
                        ) from rollback_error
                raise AuthOwnerError(
                    "Codex auth publication failed; staged and recovery bytes retained"
                ) from error
            try:
                os.replace(_PENDING, _COMPLETE, src_dir_fd=owner, dst_dir_fd=owner)
                os.fsync(owner)
                # A crash after this unlink may resurrect the marker, which
                # fails closed. Canonical publication is already durable.
                os.unlink(_COMPLETE, dir_fd=owner)
            except OSError as error:
                raise AuthOwnerError(
                    "Codex credential published; transaction cleanup needs manual review"
                ) from error
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise AuthOwnerError(
            "Codex auth publication topology or durability check failed"
        ) from error


if __name__ == "__main__":
    try:
        sys.exit(_main(sys.argv[1:]))
    except AuthOwnerError as error:
        print(str(error), file=sys.stderr)
        sys.exit(3)
