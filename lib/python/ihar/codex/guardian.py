"""Continuous Linux Codex auth owner with descriptor-bound child admission.

This is a supervision primitive. Launchers must keep their existing integrity
checks and route every Codex executable through an owning guardian.
"""

from __future__ import annotations

import array
import json
import os
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import time
from contextlib import ExitStack
from pathlib import Path

from . import auth_owner


_MAX_MESSAGE = 4096
_FD_ENV = "IHAR_GUARD_FD"
_REPORT_ENV = "IHAR_GUARD_REPORT_FD"
_BOOT = (
    "import os,sys; fd=int(sys.argv[1]); "
    "ready=os.read(fd,1); "
    "sys.exit(3) if ready!=b'1' else None; "
    "os.execvpe(sys.argv[2],sys.argv[2:],os.environ)"
)


def _exchange(channel: socket.socket, store: Path, operation: str, fields: dict) -> dict:
    if not isinstance(fields, dict):
        raise auth_owner.AuthOwnerError("Codex guardian descriptor or request is invalid")
    try:
        message = json.dumps({"operation": operation, "fields": fields},
                             separators=(",", ":")).encode("ascii")
        if len(message) > _MAX_MESSAGE:
            raise auth_owner.AuthOwnerError("Codex guardian request is too large")
        with ExitStack() as stack:
            peer = struct.unpack("3i", channel.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                                            struct.calcsize("3i")))
            with ExitStack() as owner_stack:
                owner = auth_owner._locked_owner(store, owner_stack)
                record = auth_owner._read_owner(owner)
                if (record is None or record.get("schema") != 2
                    or peer[0] != record["guardian"]["pid"] or peer[1] != os.geteuid()
                    or not auth_owner._identity_matches(record["guardian"],
                                                        auth_owner._process_table())):
                    raise auth_owner.AuthOwnerError("Codex guardian peer identity is invalid")
            reply, receiver = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
            stack.enter_context(reply)
            stack.enter_context(receiver)
            reply.settimeout({"daemon-start": 125, "daemon-stop": 65,
                              "daemon-restart": 190}.get(operation, 5))
            rights = array.array("i", [receiver.fileno()])
            channel.sendmsg([message], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, rights)])
            answer = reply.recv(_MAX_MESSAGE + 1)
        if not answer or len(answer) > _MAX_MESSAGE:
            raise auth_owner.AuthOwnerError("Codex guardian response is invalid")
        parsed = json.loads(answer)
        if not isinstance(parsed, dict) or parsed.get("ok") is not True:
            raise auth_owner.AuthOwnerError("Codex guardian refused authenticated admission")
        return parsed
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        raise auth_owner.AuthOwnerError("Codex guardian channel cannot be verified") from error


def request(fd: int, operation: str, fields: dict) -> dict:
    """Send one bounded request through an inherited, authenticated socket."""
    if fd < 0:
        raise auth_owner.AuthOwnerError("Codex guardian descriptor or request is invalid")
    try:
        with socket.socket(fileno=os.dup(fd)) as channel:
            return _exchange(channel, auth_owner._lease_store(None), operation, fields)
    except OSError as error:
        raise auth_owner.AuthOwnerError("Codex guardian channel cannot be verified") from error


def call_owner(store: Path, operation: str, fields: dict) -> dict:
    """Use the original guardian's owner-only control socket, never a new lease."""
    selected = auth_owner._lease_store(store)
    with ExitStack() as stack:
        owner = auth_owner._locked_owner(selected, stack)
        record = auth_owner._read_owner(owner)
        control = record.get("control") if isinstance(record, dict) else None
        if (record is None or record.get("schema") != 2 or control is None
            or not auth_owner._identity_matches(record["guardian"], auth_owner._process_table())):
            raise auth_owner.AuthOwnerError("Codex daemon guardian cannot be verified")
        path = selected / "auth" / "codex" / ".guardian.sock"
        try:
            metadata = os.stat(path, follow_symlinks=False)
        except OSError as error:
            raise auth_owner.AuthOwnerError("Codex daemon guardian socket is missing") from error
        if (control != {"dev": metadata.st_dev, "ino": metadata.st_ino}
            or not stat.S_ISSOCK(metadata.st_mode)):
            raise auth_owner.AuthOwnerError("Codex daemon guardian socket changed")
    with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as channel:
        channel.settimeout(10)
        try:
            channel.connect(str(path))
        except OSError as error:
            raise auth_owner.AuthOwnerError("Codex daemon guardian socket cannot be reached") from error
        return _exchange(channel, selected, operation, fields)


def daemon_identity(store: Path, runtime: str) -> dict:
    """Return only a live exact daemon bound to the original schema-two guardian."""
    selected = auth_owner._lease_store(store)
    with ExitStack() as stack:
        owner = auth_owner._locked_owner(selected, stack)
        record = auth_owner._read_owner(owner)
        table = auth_owner._process_table()
        daemon = record.get("daemon") if isinstance(record, dict) else None
        if (record is None or record.get("schema") != 2
            or record.get("runtime") != os.path.abspath(runtime)
            or record.get("state") != "active" or daemon is None
            or not auth_owner._identity_matches(record["guardian"], table)
            or not auth_owner._identity_matches(daemon, table)
            or not auth_owner._daemon_socket_proven(record)):
            raise auth_owner.AuthOwnerError("Codex daemon original owner cannot be verified")
        return {"daemon": daemon, "config_hash": record["config_hash"]}


def owner_record_present(store: Path) -> bool:
    with ExitStack() as stack:
        owner = auth_owner._locked_owner(auth_owner._lease_store(store), stack)
        return auth_owner._read_owner(owner) is not None


def _descendant(pid: int, guardian_pid: int, table: dict[int, dict]) -> bool:
    seen: set[int] = set()
    while pid != guardian_pid:
        if pid in seen or pid not in table:
            return False
        seen.add(pid)
        pid = table[pid]["ppid"]
    return True


def _identity(pid: int, binary: str | None, guardian_pid: int,
              table: dict[int, dict]) -> dict:
    if pid <= 0 or not _descendant(pid, guardian_pid, table):
        raise auth_owner.AuthOwnerError("Codex guarded process ancestry cannot be verified")
    return auth_owner._identity_for(pid, binary)


def _cleanup_auth_stage(store: Path, staged: Path, *, used: bool = False,
                        retain_changed: bool = False) -> bool:
    """Remove a verified private stage, or retain an uncertain candidate for recovery."""
    token = staged.name
    if (staged.parent != store / "auth" / "codex" / "staging"
        or len(token) != 32 or any(char not in "0123456789abcdef" for char in token)
        or not shutil.rmtree.avoids_symlink_attacks):
        raise auth_owner.AuthOwnerError("Codex auth stage cleanup is unsafe")
    with ExitStack() as stack:
        root, _auth, owner = auth_owner._owner_directories(store, stack, create=False)
        stages = auth_owner._private_directory(owner, "staging", stack, create=False)
        stage = auth_owner._private_directory(stages, token, stack, create=False)
        marker_name = ".ihar-used" if used else ".ihar-stage"
        marker_fd = os.open(marker_name, auth_owner._FILE_FLAGS, dir_fd=stage)
        stack.callback(os.close, marker_fd)
        marker_stat = os.fstat(marker_fd)
        if (not stat.S_ISREG(marker_stat.st_mode) or marker_stat.st_uid != os.geteuid()
            or stat.S_IMODE(marker_stat.st_mode) != 0o600 or marker_stat.st_size > 4096):
            raise auth_owner.AuthOwnerError("Codex auth stage marker is unsafe")
        marker = json.loads(os.read(marker_fd, 4097))
        if (not isinstance(marker, dict) or marker.get("schema") != 1
            or marker.get("token") != token
            or marker.get("store") != [os.fstat(root).st_dev, os.fstat(root).st_ino]
            or marker.get("stage") != [os.fstat(stage).st_dev, os.fstat(stage).st_ino]
            or "baseline" not in marker):
            raise auth_owner.AuthOwnerError("Codex auth stage provenance is invalid")
        changed = False
        if retain_changed:
            if marker["baseline"] != auth_owner._canonical_identity(owner):
                raise auth_owner.AuthOwnerError("Codex credential owner changed during auth cleanup")
            try:
                candidate = os.open("auth.json", auth_owner._FILE_FLAGS, dir_fd=stage)
            except FileNotFoundError:
                pass
            else:
                stack.callback(os.close, candidate)
                identity = auth_owner._identity(candidate)
                baseline = marker["baseline"]
                changed = (baseline is None or identity["sha256"] != baseline["sha256"]
                           or identity["size"] != baseline["size"])
        if changed:
            recovery = auth_owner._private_directory(owner, "recovery", stack, create=True)
            try:
                os.stat(token, dir_fd=recovery, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise auth_owner.AuthOwnerError("Codex auth recovery stage already exists")
            os.rename(token, token, src_dir_fd=stages, dst_dir_fd=recovery)
            os.fsync(recovery)
        else:
            shutil.rmtree(token, dir_fd=stages)
        os.fsync(stages)
        return changed


def _clear_auth_stage(store: Path, staged: Path) -> None:
    with ExitStack() as stack:
        owner = auth_owner._locked_owner(store, stack)
        record = auth_owner._read_owner(owner)
        if record is None or record.get("auth_stage") != str(staged):
            raise auth_owner.AuthOwnerError("Codex authentication owner changed")
        for key in ("auth_stage", "auth_verb", "auth_caller"):
            record.pop(key, None)
        auth_owner._write_owner(owner, record)


def _direct_auth_approval(action: str) -> bool:
    prompt = ("Logging out removes the shared Codex login. Type logout to continue: "
              if action == "logout" else
              "Replacing the shared Codex login may invalidate the old token remotely. "
              "Type replace to continue: ")
    try:
        descriptor = os.open("/dev/tty", os.O_RDWR | os.O_CLOEXEC)
        try:
            pending = memoryview(prompt.encode("ascii"))
            while pending:
                pending = pending[os.write(descriptor, pending):]
            answer = bytearray()
            while len(answer) < 32:
                part = os.read(descriptor, 1)
                if not part or part == b"\n":
                    break
                answer.extend(part)
            return answer.strip() == action.encode("ascii")
        finally:
            os.close(descriptor)
    except OSError:
        return False


def _start_daemon(store: Path, runtime: str, config_hash: str, binary: str,
                  guardian_pid: int) -> dict:
    """Start and bind a daemon without creating a second credential owner."""
    from . import daemon

    auth_owner.verify_runtime_link(runtime, store)
    answer = daemon._daemon_call(binary, runtime, "start")
    if not daemon.running(answer):
        raise auth_owner.AuthOwnerError("Codex daemon start did not prove a running daemon")
    path = os.path.join(runtime, "app-server-control", "app-server-control.sock")
    if answer.get("socketPath") != path:
        raise auth_owner.AuthOwnerError("Codex daemon socket path is invalid")
    for _ in range(60):
        if os.path.exists(path):
            break
        time.sleep(0.05)
    table = auth_owner._process_table()
    identity = _identity(answer.get("pid"), binary, guardian_pid, table)
    metadata = os.stat(path, follow_symlinks=False)
    if identity["pgrp"] != identity["pid"] or not stat.S_ISSOCK(metadata.st_mode):
        raise auth_owner.AuthOwnerError("Codex daemon process or socket is invalid")
    with ExitStack() as stack:
        owner = auth_owner._locked_owner(store, stack)
        record = auth_owner._read_owner(owner)
        if (record is None or record.get("schema") != 2
            or record.get("runtime") != runtime or record.get("config_hash") != config_hash
            or record.get("daemon") is not None):
            raise auth_owner.AuthOwnerError("Codex daemon owner changed during start")
        record["daemon"] = dict(identity, socket=path,
                                socket_dev=metadata.st_dev, socket_ino=metadata.st_ino)
        record["state"] = "active"
        auth_owner._write_owner(owner, record)
    return answer


def _stop_daemon(store: Path, runtime: str, binary: str, guardian_pid: int) -> dict:
    from . import daemon

    answer = daemon._daemon_call(binary, runtime, "stop", timeout=60.0)
    if answer.get("status") != "stopped":
        raise auth_owner.AuthOwnerError("Codex daemon stop outcome is unverified")
    deadline = time.monotonic() + 3
    while True:
        auth_owner._reap_children()
        with ExitStack() as stack:
            owner = auth_owner._locked_owner(store, stack)
            record = auth_owner._read_owner(owner)
            identity = record.get("daemon") if isinstance(record, dict) else None
            if (record is None or record.get("schema") != 2 or identity is None
                or record.get("runtime") != runtime or identity["binary"] != binary):
                raise auth_owner.AuthOwnerError("Codex daemon owner changed during stop")
            table = auth_owner._process_table()
            observed = table.get(identity["pid"])
            if observed is not None and observed["start"] != identity["start"]:
                raise auth_owner.AuthOwnerError("Codex daemon PID was reused")
            try:
                metadata = os.stat(identity["socket"], follow_symlinks=False)
            except FileNotFoundError:
                socket_gone = True
            else:
                if (metadata.st_dev, metadata.st_ino) != (identity["socket_dev"],
                                                          identity["socket_ino"]):
                    raise auth_owner.AuthOwnerError("Codex daemon socket changed")
                socket_gone = False
            if (socket_gone and not auth_owner._group_active(identity)
                and not auth_owner._descendants_active(guardian_pid)):
                record["daemon"] = None
                auth_owner._write_owner(owner, record)
                return answer
        if time.monotonic() >= deadline:
            raise auth_owner.AuthBusy("Codex daemon did not become quiescent after stop")
        time.sleep(0.05)


def _handle(store: Path, channel: socket.socket, guardian_pid: int,
            *, external: bool = False) -> bool:
    control_space = socket.CMSG_SPACE(struct.calcsize("3i")) + socket.CMSG_SPACE(
        array.array("i").itemsize)
    message, ancillary, flags, _address = channel.recvmsg(_MAX_MESSAGE + 1, control_space)
    if not message and not ancillary:
        return False
    reply_fd = None
    credentials = None
    for level, kind, data in ancillary:
        if level != socket.SOL_SOCKET:
            continue
        if kind == socket.SCM_CREDENTIALS and len(data) >= struct.calcsize("3i"):
            credentials = struct.unpack("3i", data[:struct.calcsize("3i")])
        elif kind == socket.SCM_RIGHTS:
            descriptors = array.array("i")
            descriptors.frombytes(data[:len(data) - len(data) % descriptors.itemsize])
            if descriptors:
                reply_fd = descriptors[0]
                for extra in descriptors[1:]:
                    os.close(extra)
    if reply_fd is None:
        return True
    daemon_action = None
    try:
        if (not message or len(message) > _MAX_MESSAGE
            or flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC)
            or credentials is None or credentials[1] != os.geteuid()):
            raise auth_owner.AuthOwnerError("Codex guardian message identity is invalid")
        payload = json.loads(message)
        if not isinstance(payload, dict) or not isinstance(payload.get("fields"), dict):
            raise auth_owner.AuthOwnerError("Codex guardian request is invalid")
        operation, fields = payload.get("operation"), payload["fields"]
        if external and operation not in ("daemon-stop", "daemon-restart"):
            raise auth_owner.AuthOwnerError("Codex external guardian operation is invalid")
        auth_action = None
        with ExitStack() as stack:
            owner = auth_owner._locked_owner(store, stack)
            record = auth_owner._read_owner(owner)
            table = auth_owner._process_table()
            if (record is None or record.get("schema") != 2
                or not auth_owner._identity_matches(record["guardian"], table)
                or (not external and not _descendant(credentials[0], guardian_pid, table))
                or (not external and not auth_owner._identity_matches(record["child"], table))):
                raise auth_owner.AuthOwnerError("Codex guardian process identity is invalid")
            child_pid = record["child"]["pid"]
            if operation == "admit" and not fields:
                pass
            elif operation == "bind-runtime" and set(fields) == {"runtime", "config_hash"}:
                runtime, config_hash = fields["runtime"], fields["config_hash"]
                if (not isinstance(runtime, str)
                    or not os.path.isabs(runtime) or not isinstance(config_hash, str)
                    or len(config_hash) > 256):
                    raise auth_owner.AuthOwnerError("Codex runtime binding is invalid")
                if (record["runtime"] is not None and record["runtime"] != os.path.abspath(runtime)
                    or record["config_hash"] is not None
                    and record["config_hash"] != config_hash):
                    raise auth_owner.AuthOwnerError("Codex runtime owner changed")
                record["runtime"] = os.path.abspath(runtime)
                record["config_hash"] = config_hash
                record["state"] = "active"
            elif operation in ("bind-child", "bind-daemon", "register-guest"):
                expected = {"pid", "binary", "socket"} if operation == "bind-daemon" else {"pid", "binary"}
                if set(fields) != expected or not isinstance(fields["binary"], str):
                    raise auth_owner.AuthOwnerError("Codex guarded process binding is invalid")
                identity = _identity(fields["pid"], fields["binary"], guardian_pid, table)
                if operation == "bind-child":
                    if len(record["children"]) >= 32:
                        raise auth_owner.AuthOwnerError("Codex guardian child limit reached")
                    record["children"].append(identity)
                elif operation == "bind-daemon":
                    path = fields["socket"]
                    expected_socket = (os.path.join(record["runtime"], "app-server-control",
                                                    "app-server-control.sock")
                                       if record["runtime"] else None)
                    if (not isinstance(path, str) or os.path.abspath(path) != expected_socket
                        or identity["pgrp"] != identity["pid"] or record["daemon"] is not None):
                        raise auth_owner.AuthOwnerError("Codex daemon identity is invalid")
                    metadata = os.stat(path, follow_symlinks=False)
                    if not stat.S_ISSOCK(metadata.st_mode):
                        raise auth_owner.AuthOwnerError("Codex daemon socket is invalid")
                    record["daemon"] = dict(identity, socket=path,
                                            socket_dev=metadata.st_dev, socket_ino=metadata.st_ino)
                else:
                    if record["guest"] is not None:
                        raise auth_owner.AuthOwnerError("Codex guest is already registered")
                    record["guest"] = identity
                    record["guest_reconciled"] = False
                record["state"] = "active"
            elif operation == "release" and set(fields) <= {"guest_reconciled"}:
                if credentials[0] != child_pid:
                    raise auth_owner.AuthOwnerError("Codex release caller is invalid")
                if record["guest"] is not None:
                    raise auth_owner.AuthOwnerError("Codex guest return is not proven")
                record["state"] = "quiescing"
            elif operation == "auth-stage" and set(fields) == {"verb"}:
                if (fields["verb"] not in ("login", "status", "logout")
                    or record.get("auth_stage") is not None):
                    raise auth_owner.AuthOwnerError("Codex authentication verb is invalid")
                auth_action = "stage"
            elif operation in ("auth-finish", "auth-abort") and set(fields) == {"stage", "verb"}:
                if (record.get("auth_stage") != fields["stage"]
                    or record.get("auth_verb") != fields["verb"]
                    or not auth_owner._identity_matches(record.get("auth_caller", {}), table)
                    or record["auth_caller"]["pid"] != credentials[0]):
                    raise auth_owner.AuthOwnerError("Codex authentication stage changed")
                auth_action = "finish" if operation == "auth-finish" else "abort"
            elif operation == "daemon-start" and set(fields) == {"runtime", "config_hash", "binary"}:
                if (external or record.get("daemon") is not None
                    or fields["runtime"] != record["runtime"]
                    or fields["config_hash"] != record["config_hash"]
                    or not isinstance(fields["binary"], str)
                    or not os.path.isabs(fields["binary"])):
                    raise auth_owner.AuthOwnerError("Codex daemon start owner is invalid")
                daemon_action = "start"
            elif (operation in ("daemon-stop", "daemon-restart") and external
                  and set(fields) == ({"runtime", "binary"} if operation == "daemon-stop"
                                      else {"runtime", "binary", "config_hash"})):
                daemon = record.get("daemon")
                if (daemon is None or fields["runtime"] != record["runtime"]
                    or fields["binary"] != daemon["binary"]
                    or (operation == "daemon-restart"
                        and fields["config_hash"] != record["config_hash"])
                    or not auth_owner._identity_matches(daemon, table)
                    or not auth_owner._daemon_socket_proven(record)):
                    raise auth_owner.AuthOwnerError("Codex daemon stop identity is invalid")
                daemon_action = "stop" if operation == "daemon-stop" else "restart"
            else:
                raise auth_owner.AuthOwnerError("Codex guardian operation is invalid")
            if auth_action is None and daemon_action is None:
                auth_owner._write_owner(owner, record)
        answer = {"ok": True, "state": record["state"]}
        if daemon_action == "start":
            answer["answer"] = _start_daemon(store, fields["runtime"],
                                             fields["config_hash"], fields["binary"],
                                             guardian_pid)
        elif daemon_action in ("stop", "restart"):
            answer["answer"] = _stop_daemon(store, fields["runtime"], fields["binary"],
                                            guardian_pid)
            if daemon_action == "restart":
                answer["answer"] = _start_daemon(store, fields["runtime"],
                                                 fields["config_hash"], fields["binary"],
                                                 guardian_pid)
        elif auth_action == "stage":
            staged = auth_owner.stage(store)
            existing = (store / "auth" / "codex" / "auth.json").exists()
            verb = fields["verb"]
            with ExitStack() as stack:
                owner = auth_owner._locked_owner(store, stack)
                record = auth_owner._read_owner(owner)
                if record is None or record.get("auth_stage") is not None:
                    raise auth_owner.AuthOwnerError("Codex authentication owner changed")
                record["auth_stage"] = str(staged)
                record["auth_verb"] = verb
                record["auth_caller"] = auth_owner._identity_for(credentials[0])
                auth_owner._write_owner(owner, record)
            try:
                if verb == "logout" and not existing:
                    raise auth_owner.AuthOwnerError("Codex shared login is already absent")
                if existing and verb != "status" and not _direct_auth_approval(
                        "logout" if verb == "logout" else "replace"):
                    raise auth_owner.ApprovalRequired(
                        "existing Codex credential needs direct TTY approval")
                if existing and verb in ("status", "logout"):
                    auth_owner._seed_stage_from_canonical(staged, store)
            except (auth_owner.AuthOwnerError, OSError):
                _cleanup_auth_stage(store, staged, retain_changed=True)
                _clear_auth_stage(store, staged)
                raise
            answer.update(stage=str(staged))
        elif auth_action == "finish":
            verb = fields["verb"]
            staged = Path(fields["stage"])
            if verb == "login":
                auth_owner.publish(staged, store, approve_existing=True)
            elif verb == "logout":
                auth_owner._logout_canonical(staged, store)
            changed = _cleanup_auth_stage(store, staged, used=verb == "login",
                                          retain_changed=verb == "status")
            if changed:
                raise auth_owner.AuthOwnerError("Codex login status changed staged credentials")
            _clear_auth_stage(store, staged)
        elif auth_action == "abort":
            staged = Path(fields["stage"])
            _cleanup_auth_stage(store, staged, retain_changed=True)
            _clear_auth_stage(store, staged)
    except (auth_owner.AuthOwnerError, OSError, ValueError, TypeError, KeyError,
            subprocess.SubprocessError):
        if daemon_action is not None:
            with ExitStack() as stack:
                owner = auth_owner._locked_owner(store, stack)
                record = auth_owner._read_owner(owner)
                if record is not None and record.get("schema") == 2:
                    record["state"] = "blocked"
                    auth_owner._write_owner(owner, record)
        answer = {"ok": False}
    try:
        with socket.socket(fileno=reply_fd) as reply:
            reply.send(json.dumps(answer).encode("ascii"))
    except OSError:
        pass
    return True


def _release_when_quiescent(store: Path, child: subprocess.Popen) -> bool:
    auth_owner._reap_children()
    with ExitStack() as stack:
        owner = auth_owner._locked_owner(store, stack)
        record = auth_owner._read_owner(owner)
        if record is None or record.get("schema") != 2:
            raise auth_owner.AuthOwnerError("Codex guardian owner record changed")
        table = auth_owner._process_table()
        if not auth_owner._identity_matches(record["guardian"], table):
            raise auth_owner.AuthOwnerError("Codex guardian identity changed")
        if record["child"]["pid"] != child.pid:
            raise auth_owner.AuthOwnerError("Codex guarded child identity changed")
        identities = [record["child"], *record.get("children", [])]
        identities.extend(identity for identity in (record.get("daemon"), record.get("guest"))
                          if identity is not None)
        for identity in identities:
            observed = table.get(identity["pid"])
            if observed is not None and observed["start"] != identity["start"]:
                raise auth_owner.AuthOwnerError("Codex guarded process PID was reused")
        if (auth_owner._group_active(record["child"])
            or auth_owner._descendants_active(os.getpid())):
            return False
        if record["state"] == "blocked":
            raise auth_owner.AuthOwnerError("Codex daemon outcome remains unverified")
        if record.get("auth_stage") is not None:
            record["state"] = "blocked"
            auth_owner._write_owner(owner, record)
            raise auth_owner.AuthOwnerError("Codex auth stage cleanup remains unverified")
        if record["guest"] is not None and not record["guest_reconciled"]:
            record["state"] = "blocked"
            auth_owner._write_owner(owner, record)
            raise auth_owner.AuthOwnerError("Codex guest return remains unverified")
        if record["daemon"] is not None:
            try:
                os.stat(record["daemon"]["socket"], follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                record["state"] = "blocked"
                auth_owner._write_owner(owner, record)
                raise auth_owner.AuthOwnerError("Codex daemon socket remains after process exit")
        auth_owner._guard_no_pending(owner)
        if record["runtime"] is not None:
            auth_owner.verify_runtime_link(record["runtime"], store)
        if auth_owner._external_consumer_present(store, table):
            raise auth_owner.AuthBusy("external Codex consumer may own the shared login")
        control = record.get("control")
        if control is not None:
            path = store / "auth" / "codex" / ".guardian.sock"
            metadata = os.stat(path, follow_symlinks=False)
            if (not stat.S_ISSOCK(metadata.st_mode)
                or control != {"dev": metadata.st_dev, "ino": metadata.st_ino}):
                raise auth_owner.AuthOwnerError("Codex daemon guardian socket changed")
            path.unlink()
        os.unlink(auth_owner._OWNER_RECORD, dir_fd=owner)
        os.fsync(owner)
        return True


def run(store: Path, argv: list[str]) -> int:
    """Start one guarded child; retain ownership until all work is quiescent."""
    if not sys.platform.startswith("linux"):
        return 3
    if not argv:
        raise auth_owner.AuthOwnerError("Codex guardian requires a child command")
    auth_owner.require_descendant_supervision()
    selected = auth_owner._lease_store(store)
    with ExitStack() as stack:
        owner = auth_owner._locked_owner(selected, stack)
        auth_owner._guard_no_pending(owner)
        previous = auth_owner._read_owner(owner)
        if previous is not None:
            if auth_owner.owner_identity_proven(previous):
                raise auth_owner.AuthBusy("another Codex runtime owns the shared login")
            raise auth_owner.AuthOwnerError("Codex auth owner cannot be verified")
        if auth_owner._external_consumer_present(selected, auth_owner._process_table()):
            raise auth_owner.AuthBusy("external Codex consumer may own the shared login")
        record = {"schema": 2, "state": "pending", "guardian": auth_owner._identity_for(os.getpid()),
                  "child": None, "children": [], "daemon": None, "guest": None,
                  "guest_reconciled": False, "runtime": None, "config_hash": None}
        auth_owner._write_owner(owner, record)
    with ExitStack() as sockets:
        server, client = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        sockets.enter_context(server)
        sockets.enter_context(client)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_PASSCRED, 1)
        control_path = selected / "auth" / "codex" / ".guardian.sock"
        listener = sockets.enter_context(socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET))
        listener.bind(str(control_path))
        os.chmod(control_path, 0o600)
        listener.listen(8)
        metadata = os.stat(control_path, follow_symlinks=False)
        with ExitStack() as stack:
            owner = auth_owner._locked_owner(selected, stack)
            record = auth_owner._read_owner(owner)
            record["control"] = {"dev": metadata.st_dev, "ino": metadata.st_ino}
            auth_owner._write_owner(owner, record)
        gate_read, gate_write = os.pipe2(os.O_CLOEXEC)
        try:
            environment = dict(os.environ, IHAR_STORE=str(selected),
                               **{_FD_ENV: str(client.fileno())})
            environment.pop(_REPORT_ENV, None)
            child = subprocess.Popen([sys.executable, "-c", _BOOT, str(gate_read), *argv],
                                     env=environment, pass_fds=(client.fileno(), gate_read),
                                     start_new_session=True)
            with ExitStack() as stack:
                owner = auth_owner._locked_owner(selected, stack)
                record = auth_owner._read_owner(owner)
                if record is None or record.get("schema") != 2:
                    raise auth_owner.AuthOwnerError("Codex guardian owner record changed")
                record["child"] = auth_owner._identity_for(child.pid, argv[0])
                auth_owner._write_owner(owner, record)
            os.write(gate_write, b"1")
        finally:
            os.close(gate_read)
            os.close(gate_write)
        client.close()
        previous_handlers = {}
        def forward(number: int, _frame: object) -> None:
            try:
                os.killpg(child.pid, number)
            except ProcessLookupError:
                pass
        for number in (signal.SIGINT, signal.SIGTERM):
            previous_handlers[number] = signal.signal(number, forward)
        try:
            status = None
            reported = False
            channel_open = True
            while True:
                if status is None:
                    status = child.poll()
                if status is not None:
                    if _release_when_quiescent(selected, child):
                        return 128 - status if status < 0 else status
                    if not reported:
                        with ExitStack() as stack:
                            owner = auth_owner._locked_owner(selected, stack)
                            record = auth_owner._read_owner(owner)
                        if record and (record.get("state") == "blocked"
                                       or record.get("daemon") and auth_owner.owner_is_active(
                                           {"daemon": record["daemon"]})):
                            report_fd = os.environ.get(_REPORT_ENV)
                            if report_fd is not None:
                                result = 128 - status if status < 0 else status
                                os.write(int(report_fd), f"{result}\n".encode("ascii"))
                                os.close(int(report_fd))
                            else:
                                print(json.dumps({"initiating_status": status}), flush=True)
                            reported = True
                            descriptor = os.open(os.devnull, os.O_WRONLY)
                            os.dup2(descriptor, sys.stdout.fileno())
                            os.dup2(descriptor, sys.stderr.fileno())
                            os.close(descriptor)
                readable, _, _ = select.select(([server] if channel_open else []) + [listener],
                                               [], [], .05 if channel_open else .2)
                if server in readable:
                    channel_open = _handle(selected, server, os.getpid())
                    if not channel_open:
                        server.close()
                if listener in readable:
                    connection, _ = listener.accept()
                    with connection:
                        connection.setsockopt(socket.SOL_SOCKET, socket.SO_PASSCRED, 1)
                        _handle(selected, connection, os.getpid(), external=True)
        finally:
            for number, handler in previous_handlers.items():
                signal.signal(number, handler)


def _run_auth_vendor(fd: int, command: list[str], environment: dict[str, str]) -> int:
    auth_owner.require_descendant_supervision()
    gate_read, gate_write = os.pipe2(os.O_CLOEXEC)
    process = None
    interrupted = 0
    status = None
    def forward(number: int, _frame: object) -> None:
        nonlocal interrupted
        interrupted = number
        if process is not None:
            try:
                os.killpg(process.pid, number)
            except ProcessLookupError:
                pass
    previous = {number: signal.signal(number, forward)
                for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        try:
            if interrupted:
                raise auth_owner.AuthOwnerError("Codex authentication was interrupted")
            process = subprocess.Popen([sys.executable, "-c", _BOOT, str(gate_read), *command],
                                       env=environment, pass_fds=(gate_read,),
                                       start_new_session=True)
            request(fd, "bind-child", {"pid": process.pid, "binary": command[0]})
            if interrupted:
                raise auth_owner.AuthOwnerError("Codex authentication was interrupted")
            os.write(gate_write, b"1")
        finally:
            os.close(gate_read)
            os.close(gate_write)
        status = process.wait()
    finally:
        try:
            if process is not None and process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                process.wait()
            if process is not None:
                while True:
                    auth_owner._reap_children()
                    try:
                        active = (auth_owner._group_active({"pgrp": process.pid})
                                  or auth_owner._descendants_active(os.getpid()))
                    except auth_owner.AuthOwnerError:
                        # A disappearing /proc entry is uncertainty, never proof of exit.
                        time.sleep(0.05)
                        continue
                    if not active:
                        break
                    time.sleep(0.05)
        finally:
            for number, handler in previous.items():
                signal.signal(number, handler)
    if interrupted:
        return 128 + interrupted
    return 128 - status if status < 0 else status


def _supervise(store: str, command: list[str]) -> int:
    """Return the initiating result while the original owner keeps a daemon alive."""
    read_fd, write_fd = os.pipe2(os.O_CLOEXEC)
    try:
        environment = dict(os.environ, **{_REPORT_ENV: str(write_fd)})
        process = subprocess.Popen([sys.executable, "-m", "ihar.codex.guardian",
                                    store, "--", *command], env=environment,
                                   pass_fds=(write_fd,))
        os.close(write_fd)
        write_fd = -1
        report = os.read(read_fd, 64)
        if report:
            try:
                return int(report.strip())
            except ValueError as error:
                raise auth_owner.AuthOwnerError("Codex guardian result is invalid") from error
        return process.wait()
    finally:
        os.close(read_fd)
        if write_fd >= 0:
            os.close(write_fd)


def _main(arguments: list[str]) -> int:
    if len(arguments) >= 4 and arguments[0] == "supervise" and arguments[2] == "--":
        return _supervise(arguments[1], arguments[3:])
    if len(arguments) == 2 and arguments[0] == "admit":
        request(int(arguments[1]), "admit", {})
        return 0
    if len(arguments) == 4 and arguments[0] == "bind-runtime":
        request(int(arguments[1]), "bind-runtime",
                {"runtime": arguments[2], "config_hash": arguments[3]})
        return 0
    if len(arguments) >= 5 and arguments[:1] == ["auth"] and arguments[2] == "--":
        fd = int(arguments[1])
        command = arguments[3:]
        if command[1:] == ["login"]:
            verb = "login"
        elif command[1:] == ["login", "status"]:
            verb = "status"
        elif command[1:] == ["logout"]:
            verb = "logout"
        else:
            raise auth_owner.AuthOwnerError("Codex authentication verb is invalid")
        answer = request(fd, "auth-stage", {"verb": verb})
        stage = answer.get("stage")
        if not isinstance(stage, str):
            raise auth_owner.AuthOwnerError("Codex authentication stage is invalid")
        environment = dict(os.environ, CODEX_HOME=stage)
        environment.pop(_FD_ENV, None)
        environment.pop("PYTHONPATH", None)
        try:
            status = _run_auth_vendor(fd, command, environment)
        except (auth_owner.AuthOwnerError, OSError, subprocess.SubprocessError):
            request(fd, "auth-abort", {"stage": stage, "verb": verb})
            raise
        if status == 0:
            request(fd, "auth-finish", {"stage": stage, "verb": verb})
        else:
            request(fd, "auth-abort", {"stage": stage, "verb": verb})
        return status
    if len(arguments) < 3 or arguments[1] != "--":
        raise auth_owner.AuthOwnerError("Codex guardian invocation is invalid")
    return run(Path(arguments[0]), arguments[2:])


if __name__ == "__main__":
    try:
        raise SystemExit(_main(sys.argv[1:]))
    except (auth_owner.AuthOwnerError, OSError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(3)
