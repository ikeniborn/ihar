"""Continuous Linux Codex auth owner with descriptor-bound child admission.

This is a supervision primitive. Launchers must keep their existing integrity
checks and route every Codex executable through an owning guardian.
"""

from __future__ import annotations

import array
import json
import os
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
from contextlib import ExitStack
from pathlib import Path

from . import auth_owner


_MAX_MESSAGE = 4096
_FD_ENV = "IHAR_GUARD_FD"
_BOOT = (
    "import os,sys; fd=int(sys.argv[1]); "
    "ready=os.read(fd,1); "
    "sys.exit(3) if ready!=b'1' else None; "
    "os.execvpe(sys.argv[2],sys.argv[2:],os.environ)"
)


def request(fd: int, operation: str, fields: dict) -> dict:
    """Send one bounded request through an inherited, authenticated socket."""
    if fd < 0 or not isinstance(fields, dict):
        raise auth_owner.AuthOwnerError("Codex guardian descriptor or request is invalid")
    try:
        message = json.dumps({"operation": operation, "fields": fields},
                             separators=(",", ":")).encode("ascii")
        if len(message) > _MAX_MESSAGE:
            raise auth_owner.AuthOwnerError("Codex guardian request is too large")
        with ExitStack() as stack:
            channel = stack.enter_context(socket.socket(fileno=os.dup(fd)))
            peer = struct.unpack("3i", channel.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                                            struct.calcsize("3i")))
            with ExitStack() as owner_stack:
                owner = auth_owner._locked_owner(auth_owner._lease_store(None), owner_stack)
                record = auth_owner._read_owner(owner)
                if (record is None or record.get("schema") != 2
                    or peer[0] != record["guardian"]["pid"] or peer[1] != os.geteuid()
                    or not auth_owner._identity_matches(record["guardian"],
                                                        auth_owner._process_table())):
                    raise auth_owner.AuthOwnerError("Codex guardian peer identity is invalid")
            reply, receiver = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
            stack.enter_context(reply)
            stack.enter_context(receiver)
            reply.settimeout(5)
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


def _handle(store: Path, channel: socket.socket, guardian_pid: int) -> bool:
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
    try:
        if (not message or len(message) > _MAX_MESSAGE
            or flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC)
            or credentials is None or credentials[1] != os.geteuid()):
            raise auth_owner.AuthOwnerError("Codex guardian message identity is invalid")
        payload = json.loads(message)
        if not isinstance(payload, dict) or not isinstance(payload.get("fields"), dict):
            raise auth_owner.AuthOwnerError("Codex guardian request is invalid")
        operation, fields = payload.get("operation"), payload["fields"]
        auth_action = None
        with ExitStack() as stack:
            owner = auth_owner._locked_owner(store, stack)
            record = auth_owner._read_owner(owner)
            table = auth_owner._process_table()
            if (record is None or record.get("schema") != 2
                or not auth_owner._identity_matches(record["guardian"], table)
                or not _descendant(credentials[0], guardian_pid, table)
                or not auth_owner._identity_matches(record["child"], table)):
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
                if record["runtime"] is not None and record["runtime"] != os.path.abspath(runtime):
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
            elif operation == "auth-finish" and set(fields) == {"stage", "verb"}:
                if (record.get("auth_stage") != fields["stage"]
                    or record.get("auth_verb") != fields["verb"]
                    or not auth_owner._identity_matches(record.get("auth_caller", {}), table)
                    or record["auth_caller"]["pid"] != credentials[0]):
                    raise auth_owner.AuthOwnerError("Codex authentication stage changed")
                auth_action = "finish"
            else:
                raise auth_owner.AuthOwnerError("Codex guardian operation is invalid")
            if auth_action is None:
                auth_owner._write_owner(owner, record)
        answer = {"ok": True, "state": record["state"]}
        if auth_action == "stage":
            staged = auth_owner.stage(store)
            existing = (store / "auth" / "codex" / "auth.json").exists()
            verb = fields["verb"]
            if verb == "logout" and not existing:
                raise auth_owner.AuthOwnerError("Codex shared login is already absent")
            if existing and verb != "status" and not auth_owner._direct_approval(
                    "logout" if verb == "logout" else "replace"):
                raise auth_owner.ApprovalRequired(
                    "existing Codex credential needs direct TTY approval")
            if existing and verb in ("status", "logout"):
                auth_owner._seed_stage_from_canonical(staged, store)
            with ExitStack() as stack:
                owner = auth_owner._locked_owner(store, stack)
                record = auth_owner._read_owner(owner)
                if record is None or record.get("auth_stage") is not None:
                    raise auth_owner.AuthOwnerError("Codex authentication owner changed")
                record["auth_stage"] = str(staged)
                record["auth_verb"] = verb
                record["auth_caller"] = auth_owner._identity_for(credentials[0])
                auth_owner._write_owner(owner, record)
            answer.update(stage=str(staged))
        elif auth_action == "finish":
            verb = fields["verb"]
            staged = Path(fields["stage"])
            if verb == "login":
                auth_owner.publish(staged, store, approve_existing=True)
            elif verb == "logout":
                auth_owner._logout_canonical(staged, store)
            with ExitStack() as stack:
                owner = auth_owner._locked_owner(store, stack)
                record = auth_owner._read_owner(owner)
                if record is None or record.get("auth_stage") != str(staged):
                    raise auth_owner.AuthOwnerError("Codex authentication owner changed")
                for key in ("auth_stage", "auth_verb", "auth_caller"):
                    record.pop(key, None)
                auth_owner._write_owner(owner, record)
    except (auth_owner.AuthOwnerError, OSError, ValueError, TypeError, KeyError):
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
        gate_read, gate_write = os.pipe2(os.O_CLOEXEC)
        try:
            environment = dict(os.environ, IHAR_STORE=str(selected),
                               **{_FD_ENV: str(client.fileno())})
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
                        if record and record.get("daemon") and auth_owner.owner_is_active(
                                {"daemon": record["daemon"]}):
                            print(json.dumps({"initiating_status": status}), flush=True)
                            reported = True
                            descriptor = os.open(os.devnull, os.O_WRONLY)
                            os.dup2(descriptor, sys.stdout.fileno())
                            os.close(descriptor)
                readable, _, _ = select.select([server] if channel_open else [], [], [],
                                               .05 if channel_open else .2)
                if readable:
                    channel_open = _handle(selected, server, os.getpid())
                    if not channel_open:
                        server.close()
        finally:
            for number, handler in previous_handlers.items():
                signal.signal(number, handler)


def _main(arguments: list[str]) -> int:
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
        status = subprocess.call(command, env=environment, close_fds=True)
        if status == 0:
            request(fd, "auth-finish", {"stage": stage, "verb": verb})
        return 128 - status if status < 0 else status
    if len(arguments) < 3 or arguments[1] != "--":
        raise auth_owner.AuthOwnerError("Codex guardian invocation is invalid")
    return run(Path(arguments[0]), arguments[2:])


if __name__ == "__main__":
    try:
        raise SystemExit(_main(sys.argv[1:]))
    except (auth_owner.AuthOwnerError, OSError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(3)
