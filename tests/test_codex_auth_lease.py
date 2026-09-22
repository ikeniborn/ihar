#!/usr/bin/env python3
"""Exclusive Codex credential writer tests with synthetic runtimes."""

from __future__ import annotations

import array
import json
import os
import signal
import socket as socket_module
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib" / "python"))

from ihar.codex import auth_owner


class AuthLeaseTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.store = self.root / "store"
        self.store.mkdir(mode=0o700)
        self.runtime_a = self.root / "runtime-a"
        self.runtime_b = self.root / "runtime-b"
        self.runtime_a.mkdir()
        self.runtime_b.mkdir()
        patcher = mock.patch.dict(os.environ, {"IHAR_STORE": str(self.store)})
        patcher.start()
        self.addCleanup(patcher.stop)

    @property
    def record(self) -> Path:
        return self.store / "auth" / "codex" / ".owner.json"

    def _guardian(self, script: str) -> subprocess.Popen:
        process = subprocess.Popen(
            [sys.executable, "-m", "ihar.codex.guardian", str(self.store), "--",
             sys.executable, "-c", script],
            env=dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1] / "lib" / "python")),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True,
        )
        def cleanup() -> None:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()
        self.addCleanup(cleanup)
        return process

    def _wait_for(self, path: Path) -> None:
        for _ in range(100):
            if path.exists():
                return
            time.sleep(.02)
        self.fail(f"timed out waiting for {path.name}")

    def test_guardian_records_pending_before_child_exec_and_blocks_competitor(self) -> None:
        observed = self.root / "observed.json"
        script = ("import json, os, time; from pathlib import Path; "
                  f"Path({str(observed)!r}).write_text(Path({str(self.record)!r}).read_text()); "
                  "time.sleep(1)")
        first = self._guardian(script)
        self._wait_for(observed)
        snapshot = json.loads(observed.read_text())
        self.assertEqual(snapshot["schema"], 2)
        self.assertEqual(snapshot["state"], "pending")
        started = time.monotonic()
        second = self._guardian("raise SystemExit(23)")
        self.assertEqual(second.wait(timeout=3), 3)
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(first.wait(timeout=5), 0)
        self.assertFalse(self.record.exists())

    def test_spoofed_guard_environment_cannot_bind_owner(self) -> None:
        from ihar.codex import guardian
        owner = auth_owner.acquire(self.runtime_a, "foreground")
        original_record = self.record.read_bytes()
        try:
            with mock.patch.dict(os.environ, {"IHAR_GUARD_FD": "-1", "IHAR_OWNER_ID": owner}):
                with self.assertRaises(auth_owner.AuthOwnerError):
                    guardian.request(-1, "bind-runtime", {"runtime": str(self.runtime_a)})
            self.assertEqual(self.record.read_bytes(), original_record)
        finally:
            auth_owner.release(owner)

    def test_foreign_socket_cannot_forge_guardian_success(self) -> None:
        from ihar.codex import guardian
        ready = self.root / "real-guardian-ready"
        guarded = self._guardian(f"from pathlib import Path; import time; Path({str(ready)!r}).touch(); time.sleep(1.5)")
        self._wait_for(ready)
        self.assertEqual(json.loads(self.record.read_text())["schema"], 2)
        original = self.record.read_bytes()
        client, foreign = socket_module.socketpair(socket_module.AF_UNIX,
                                                     socket_module.SOCK_SEQPACKET)
        self.addCleanup(client.close)
        self.addCleanup(foreign.close)
        def forge_success() -> None:
            foreign.settimeout(.5)
            try:
                _payload, controls, _flags, _address = foreign.recvmsg(
                    4096, socket_module.CMSG_SPACE(array.array("i").itemsize))
            except (OSError, TimeoutError):
                return
            for level, kind, data in controls:
                if level == socket_module.SOL_SOCKET and kind == socket_module.SCM_RIGHTS:
                    descriptors = array.array("i")
                    descriptors.frombytes(data[:descriptors.itemsize])
                    with socket_module.socket(fileno=descriptors[0]) as reply:
                        reply.send(b'{"ok":true,"state":"active"}')
        responder = threading.Thread(target=forge_success, daemon=True)
        responder.start()
        try:
            with self.assertRaises(auth_owner.AuthOwnerError):
                guardian.request(client.fileno(), "bind-runtime",
                                 {"runtime": str(self.runtime_a), "config_hash": "forged"})
            self.assertEqual(self.record.read_bytes(), original)
        finally:
            client.close()
            foreign.close()
            responder.join(timeout=1)
        self.assertEqual(guarded.wait(timeout=5), 0, guarded.stderr.read())

    def test_guardian_authenticated_child_binds_runtime_and_hash(self) -> None:
        auth_owner.stage(self.store)
        (self.runtime_a / "auth.json").symlink_to(self.store / "auth" / "codex" / "auth.json")
        marker = self.root / "bound"
        script = ("import os; from pathlib import Path; from ihar.codex import guardian; "
                  "guardian.request(int(os.environ['IHAR_GUARD_FD']), 'bind-runtime', "
                  f"{{'runtime': {str(self.runtime_a)!r}, 'config_hash': 'hash-a'}}); "
                  f"Path({str(marker)!r}).touch()")
        process = self._guardian(script)
        self.assertEqual(process.wait(timeout=5), 0, process.stderr.read())
        self.assertTrue(marker.exists())
        self.assertFalse(self.record.exists())

    def test_guardian_child_can_request_without_inherited_store_variable(self) -> None:
        auth_owner.stage(self.store)
        (self.runtime_a / "auth.json").symlink_to(self.store / "auth" / "codex" / "auth.json")
        marker = self.root / "bound-without-store-env"
        script = ("import os; from pathlib import Path; from ihar.codex import guardian; "
                  "guardian.request(int(os.environ['IHAR_GUARD_FD']), 'bind-runtime', "
                  f"{{'runtime': {str(self.runtime_a)!r}, 'config_hash': 'hash-a'}}); "
                  f"Path({str(marker)!r}).touch()")
        environment = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1] / "lib" / "python"))
        environment.pop("IHAR_STORE", None)
        answer = subprocess.run([sys.executable, "-m", "ihar.codex.guardian", str(self.store),
                                 "--", sys.executable, "-c", script], env=environment,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(answer.returncode, 0, answer.stderr)
        self.assertTrue(marker.exists())

    def test_guardian_crash_retains_record_with_live_descendant(self) -> None:
        marker = self.root / "live"
        script = f"from pathlib import Path; import time; Path({str(marker)!r}).touch(); time.sleep(30)"
        process = self._guardian(script)
        self._wait_for(marker)
        process.kill()
        process.wait(timeout=5)
        original = self.record.read_bytes()
        second = self._guardian("raise SystemExit(23)")
        self.assertEqual(second.wait(timeout=3), 3)
        self.assertEqual(self.record.read_bytes(), original)
        self.assertIn("owns the shared login", second.stderr.read())
        child = json.loads(original)["child"]
        try:
            os.killpg(child["pgrp"], signal.SIGTERM)
        except ProcessLookupError:
            pass

    def test_schema_one_owner_record_blocks_new_guardian(self) -> None:
        owner = auth_owner.acquire(self.runtime_a, "foreground")
        original = self.record.read_bytes()
        try:
            contender = self._guardian("raise SystemExit(23)")
            self.assertEqual(contender.wait(timeout=3), 3)
            self.assertEqual(self.record.read_bytes(), original)
        finally:
            auth_owner.release(owner)

    def test_unsupported_guardian_platform_returns_three_without_record(self) -> None:
        from ihar.codex import guardian
        with mock.patch.object(guardian.sys, "platform", "darwin"):
            self.assertEqual(guardian.run(self.store, ["/bin/true"]), 3)
        self.assertFalse(self.record.exists())

    def test_replaced_daemon_socket_blocks_schema_two_release(self) -> None:
        from ihar.codex import guardian
        auth_owner.stage(self.store)
        socket_path = self.root / "daemon.sock"
        listener = socket_module.socket(socket_module.AF_UNIX)
        listener.bind(str(socket_path))
        self.addCleanup(listener.close)
        metadata = socket_path.stat()
        absent_pid = 2147483647
        record = {"schema": 2, "state": "active", "guardian": auth_owner._identity_for(os.getpid()),
                  "child": {"pid": absent_pid, "start": "absent", "binary": "/bin/false",
                            "pgrp": absent_pid},
                  "children": [], "daemon": {"pid": absent_pid, "start": "absent",
                                                  "binary": "/bin/false", "pgrp": absent_pid,
                                                  "socket": str(socket_path),
                                                  "socket_dev": metadata.st_dev,
                                                  "socket_ino": metadata.st_ino + 1},
                  "guest": None, "guest_reconciled": False, "runtime": None,
                  "config_hash": None}
        self.record.write_text(json.dumps(record))
        self.record.chmod(0o600)
        with self.assertRaises(auth_owner.AuthOwnerError):
            guardian._release_when_quiescent(self.store, SimpleNamespace(pid=absent_pid))
        self.assertTrue(self.record.exists())

    def test_legacy_acquire_never_mutates_schema_two_record(self) -> None:
        auth_owner.stage(self.store)
        socket_path = self.root / "control.sock"
        listener = socket_module.socket(socket_module.AF_UNIX)
        listener.bind(str(socket_path))
        self.addCleanup(listener.close)
        metadata = socket_path.stat()
        record = {"schema": 2, "state": "active", "guardian": auth_owner._identity_for(os.getpid()),
                  "runtime": str(self.runtime_a), "config_hash": "", "child": None,
                  "daemon": {"socket": str(socket_path), "socket_dev": metadata.st_dev,
                             "socket_ino": metadata.st_ino}}
        self.record.write_text(json.dumps(record))
        self.record.chmod(0o600)
        original = self.record.read_bytes()
        with self.assertRaises(auth_owner.AuthBusy):
            auth_owner.acquire(self.runtime_a, "foreground")
        self.assertEqual(self.record.read_bytes(), original)
        with self.assertRaises(auth_owner.AuthOwnerError):
            auth_owner.release(None)
        self.assertEqual(self.record.read_bytes(), original)

    def test_legacy_release_cannot_delete_pending_schema_two_record(self) -> None:
        auth_owner.stage(self.store)
        self.record.write_text(json.dumps({"schema": 2, "state": "pending",
                                           "guardian": auth_owner._identity_for(os.getpid()),
                                           "child": None, "daemon": None}))
        self.record.chmod(0o600)
        original = self.record.read_bytes()
        with self.assertRaises(auth_owner.AuthOwnerError):
            auth_owner.release(None)
        self.assertEqual(self.record.read_bytes(), original)

    def test_reused_child_pid_blocks_schema_two_release(self) -> None:
        from ihar.codex import guardian
        auth_owner.stage(self.store)
        absent_pid = 2147483647
        self.record.write_text(json.dumps({"schema": 2, "state": "active",
                                           "guardian": auth_owner._identity_for(os.getpid()),
                                           "child": {"pid": absent_pid, "start": "old-start",
                                                     "binary": "/bin/false", "pgrp": absent_pid},
                                           "guest": None, "daemon": None, "runtime": None}))
        self.record.chmod(0o600)
        original = self.record.read_bytes()
        table = auth_owner._process_table()
        table[absent_pid] = {"pid": absent_pid, "ppid": 1, "pgrp": 1, "status": "R",
                             "start": "reused-start", "exe": "/bin/false", "argv": [],
                             "name": "unrelated"}
        with mock.patch.object(auth_owner, "_process_table", return_value=table):
            with self.assertRaises(auth_owner.AuthOwnerError):
                guardian._release_when_quiescent(self.store, SimpleNamespace(pid=absent_pid))
        self.assertEqual(self.record.read_bytes(), original)

    def test_schema_two_pid_reuse_keeps_original_record(self) -> None:
        auth_owner.stage(self.store)
        record = {"schema": 2, "state": "pending",
                  "guardian": dict(auth_owner._identity_for(os.getpid()), start="reused-pid"),
                  "child": None}
        self.record.write_text(json.dumps(record))
        self.record.chmod(0o600)
        original = self.record.read_bytes()
        contender = self._guardian("raise SystemExit(23)")
        self.assertEqual(contender.wait(timeout=3), 3)
        self.assertEqual(self.record.read_bytes(), original)
        self.assertIn("cannot be verified", contender.stderr.read())

    def test_external_codex_without_explicit_home_uses_independent_default(self) -> None:
        binary = self.root / "default-home-codex"
        binary.write_text("#!/bin/sh\nsleep 30\n")
        binary.chmod(0o700)
        environment = dict(os.environ)
        environment.pop("CODEX_HOME", None)
        external = subprocess.Popen([str(binary)], env=environment, start_new_session=True)
        def stop_external() -> None:
            try:
                os.killpg(external.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            external.wait(timeout=5)
        self.addCleanup(stop_external)
        contender = self._guardian("raise SystemExit(23)")
        self.assertEqual(contender.wait(timeout=3), 23, contender.stderr.read())
        self.assertFalse(self.record.exists())

    def test_opaque_external_codex_consumer_blocks_admission(self) -> None:
        ready = self.root / "opaque-ready"
        binary = self.root / "opaque-codex"
        binary.write_text(f"#!/bin/sh\ntouch '{ready}'\nsleep 30\n")
        binary.chmod(0o700)
        environment = dict(os.environ)
        environment.pop("HOME", None)
        environment.pop("CODEX_HOME", None)
        external = subprocess.Popen([str(binary)], env=environment, start_new_session=True)
        def stop_external() -> None:
            try:
                os.killpg(external.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            external.wait(timeout=5)
        self.addCleanup(stop_external)
        self._wait_for(ready)
        contender = self._guardian("raise SystemExit(23)")
        self.assertEqual(contender.wait(timeout=3), 3)
        self.assertIn("external Codex consumer runtime cannot be verified",
                      contender.stderr.read())
        self.assertFalse(self.record.exists())

    def test_bound_daemon_survives_initiating_child_and_holds_owner(self) -> None:
        auth_owner.stage(self.store)
        (self.runtime_a / "auth.json").symlink_to(self.store / "auth" / "codex" / "auth.json")
        directory = self.runtime_a / "app-server-control"
        directory.mkdir()
        daemon_pid = self.root / "daemon.pid"
        socket_path = directory / "app-server-control.sock"
        daemon_code = ("import os,signal,socket,sys,time; s=socket.socket(socket.AF_UNIX); "
                       "s.bind(sys.argv[1]); s.listen(); "
                       "signal.signal(signal.SIGTERM, lambda *_: (s.close(),os.unlink(sys.argv[1]),sys.exit(0))); "
                       "time.sleep(30)")
        script = ("import os,subprocess,sys,time; from pathlib import Path; "
                  "from ihar.codex import guardian; "
                  "fd=int(os.environ['IHAR_GUARD_FD']); "
                  f"guardian.request(fd,'bind-runtime',{{'runtime':{str(self.runtime_a)!r},'config_hash':'hash-a'}}); "
                  f"p=subprocess.Popen([sys.executable,'-c',{daemon_code!r},{str(socket_path)!r}],"
                  "start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); "
                  f"Path({str(daemon_pid)!r}).write_text(str(p.pid)); "
                  f"sock=Path({str(socket_path)!r}); "
                  "[(time.sleep(.02)) for _ in range(100) if not sock.exists()]; "
                  f"guardian.request(fd,'bind-daemon',{{'pid':p.pid,'binary':sys.executable,'socket':{str(socket_path)!r}}})")
        process = self._guardian(script)
        self._wait_for(daemon_pid)
        self._wait_for(socket_path)
        try:
            for _ in range(100):
                if self.record.exists() and json.loads(self.record.read_text()).get("daemon"):
                    break
                time.sleep(.02)
            self.assertIsNotNone(json.loads(self.record.read_text())["daemon"])
            self.assertIsNone(process.poll())
            self.assertEqual(json.loads(process.stdout.readline())["initiating_status"], 0)
            def guardian_sockets() -> list[str]:
                found = []
                for path in (Path("/proc") / str(process.pid) / "fd").iterdir():
                    try:
                        target = os.readlink(path)
                    except FileNotFoundError:
                        continue
                    if target.startswith("socket:["):
                        found.append(target)
                return found
            for _ in range(50):
                if not guardian_sockets():
                    break
                time.sleep(.02)
            self.assertEqual(guardian_sockets(), [], "guardian retained child channel after EOF")
            self.assertIsNone(process.poll(), "guardian stopped supervising live daemon")
            contender = self._guardian("raise SystemExit(23)")
            self.assertEqual(contender.wait(timeout=3), 3)
            self.assertIn("owns the shared login", contender.stderr.read())
        finally:
            try:
                os.killpg(int(daemon_pid.read_text()), signal.SIGTERM)
            except ProcessLookupError:
                pass
        self.assertEqual(process.wait(timeout=5), 0, process.stderr.read())
        self.assertFalse(self.record.exists())

    def test_guest_without_reconciliation_blocks_after_exit(self) -> None:
        guest_pid = self.root / "guest.pid"
        script = ("import os,subprocess,sys; from pathlib import Path; "
                  "from ihar.codex import guardian; "
                  "p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],"
                  "start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); "
                  f"Path({str(guest_pid)!r}).write_text(str(p.pid)); "
                  "guardian.request(int(os.environ['IHAR_GUARD_FD']),'register-guest',"
                  "{'pid':p.pid,'binary':sys.executable})")
        process = self._guardian(script)
        self._wait_for(guest_pid)
        for _ in range(100):
            if self.record.exists() and json.loads(self.record.read_text()).get("guest"):
                break
            time.sleep(.02)
        self.assertIsNotNone(json.loads(self.record.read_text())["guest"])
        self.assertIsNone(process.poll())
        try:
            os.killpg(int(guest_pid.read_text()), signal.SIGTERM)
        except ProcessLookupError:
            pass
        self.assertEqual(process.wait(timeout=5), 3)
        self.assertEqual(json.loads(self.record.read_text())["state"], "blocked")

    def test_guest_release_claim_without_durable_proof_is_refused(self) -> None:
        refused = self.root / "guest-release-refused"
        script = f"""import os, subprocess, sys
from pathlib import Path
from ihar.codex import guardian
from ihar.codex.auth_owner import AuthOwnerError
fd = int(os.environ['IHAR_GUARD_FD'])
p = subprocess.Popen([sys.executable, '-c', 'import time;time.sleep(.3)'], start_new_session=True)
guardian.request(fd, 'register-guest', {{'pid': p.pid, 'binary': sys.executable}})
p.wait()
try:
    guardian.request(fd, 'release', {{'guest_reconciled': True}})
except AuthOwnerError:
    Path({str(refused)!r}).touch()
"""
        process = self._guardian(script)
        self.assertEqual(process.wait(timeout=5), 3, process.stderr.read())
        self.assertTrue(refused.exists())
        self.assertEqual(json.loads(self.record.read_text())["state"], "blocked")

    def test_second_runtime_cannot_own_login(self) -> None:
        first = auth_owner.acquire(self.runtime_a, "foreground")
        try:
            with self.assertRaises(auth_owner.AuthBusy):
                auth_owner.acquire(self.runtime_b, "foreground")
        finally:
            auth_owner.release(first)
        second = auth_owner.acquire(self.runtime_b, "foreground")
        auth_owner.release(second)

    def test_external_codex_using_shared_link_blocks_admission(self) -> None:
        auth_owner.stage(self.store)
        (self.runtime_a / "auth.json").symlink_to(self.store / "auth" / "codex" / "auth.json")
        binary = self.root / "external-codex"
        binary.write_text("#!/bin/sh\nsleep 30\n")
        binary.chmod(0o700)
        process = subprocess.Popen([str(binary)], env=dict(os.environ, CODEX_HOME=str(self.runtime_a)),
                                   start_new_session=True)
        def stop_external() -> None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            process.wait()
        self.addCleanup(stop_external)
        with self.assertRaises(auth_owner.AuthBusy):
            auth_owner.acquire(self.runtime_b, "foreground")
        self.assertFalse(self.record.exists())

    def test_unprovable_macos_descendants_refuse_before_vendor_start(self) -> None:
        auth_owner.stage(self.store)
        (self.runtime_a / "auth.json").symlink_to(self.store / "auth" / "codex" / "auth.json")
        marker = self.root / "macos-vendor-started"
        binary = self.root / "macos-codex"
        binary.write_text(f"#!/bin/sh\ntouch '{marker}'\n")
        binary.chmod(0o700)
        with mock.patch.object(auth_owner.sys, "platform", "darwin"):
            with self.assertRaisesRegex(auth_owner.AuthOwnerError, "descendant supervision"):
                auth_owner._main(["run", str(self.store), str(self.runtime_a), "hash-a",
                                  "foreground", "--", str(binary)])
            from ihar.codex import daemon
            with self.assertRaisesRegex(auth_owner.AuthOwnerError, "descendant supervision"):
                daemon.start(str(binary), str(self.runtime_a), auth_store=str(self.store),
                             config_hash="hash-a")
        self.assertFalse(marker.exists())
        self.assertFalse(self.record.exists())

    def test_same_runtime_does_not_create_a_second_writer(self) -> None:
        first = auth_owner.acquire(self.runtime_a, "foreground")
        try:
            with self.assertRaises(auth_owner.AuthBusy):
                auth_owner.acquire(self.runtime_a, "foreground")
        finally:
            auth_owner.release(first)

    def test_pid_start_reuse_refuses_without_deleting_record(self) -> None:
        first = auth_owner.acquire(self.runtime_a, "foreground")
        record = json.loads(self.record.read_text())
        record["guardian"]["start"] = "wrong-start"
        self.record.write_text(json.dumps(record))
        with self.assertRaisesRegex(auth_owner.AuthOwnerError, "cannot be verified"):
            auth_owner.acquire(self.runtime_b, "foreground")
        self.assertTrue(self.record.exists())

    def test_unreadable_process_table_refuses_without_deleting_record(self) -> None:
        first = auth_owner.acquire(self.runtime_a, "foreground")
        with mock.patch.object(auth_owner, "_process_table", side_effect=auth_owner.AuthOwnerError("unreadable")):
            with self.assertRaises(auth_owner.AuthOwnerError):
                auth_owner.acquire(self.runtime_b, "foreground")
        self.assertTrue(self.record.exists())
        auth_owner.release(first)

    def test_daemon_survives_launcher_and_attached_client_reuses_owner(self) -> None:
        binary = self.root / "fake-codex"
        binary.write_text("#!/bin/sh\nsleep 30\n")
        binary.chmod(0o700)
        process = subprocess.Popen([str(binary)], start_new_session=True)
        def stop_group() -> None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            process.wait()
        self.addCleanup(stop_group)
        socket = self.runtime_a / "app-server-control" / "app-server-control.sock"
        socket.parent.mkdir()
        listener = socket_module.socket(socket_module.AF_UNIX)
        listener.bind(str(socket))
        self.addCleanup(listener.close)
        first = auth_owner.acquire(self.runtime_a, "daemon")
        auth_owner.bind_daemon(first, process.pid, socket, binary)
        attached = auth_owner.acquire(self.runtime_a, "attached", attached_daemon_id=first)
        self.assertEqual(attached, first)
        with self.assertRaises(auth_owner.AuthBusy):
            auth_owner.acquire(self.runtime_b, "foreground")
        auth_owner.detach(attached)
        stop_group()
        auth_owner.mark_daemon_quiescent(first)
        auth_owner.release(first)
        second = auth_owner.acquire(self.runtime_b, "foreground")
        auth_owner.release(second)

    def test_release_refuses_while_child_is_live(self) -> None:
        first = auth_owner.acquire(self.runtime_a, "foreground")
        process = subprocess.Popen(["sleep", "30"], start_new_session=True)
        self.addCleanup(lambda: (process.terminate(), process.wait()) if process.poll() is None else None)
        auth_owner.bind_child(first, process.pid, Path("/usr/bin/sleep"))
        with self.assertRaises(auth_owner.AuthBusy):
            auth_owner.release(first)
        with self.assertRaises(auth_owner.AuthBusy):
            auth_owner.acquire(self.runtime_b, "foreground")
        process.terminate()
        process.wait()
        auth_owner.release(first)

    def test_foreground_guardian_prevents_second_vendor_start(self) -> None:
        marker = self.root / "vendor-starts"
        binary = self.root / "fake-codex"
        binary.write_text(f"#!/bin/sh\nprintf 'started\\n' >> '{marker}'\nsleep 30\n")
        binary.chmod(0o700)
        auth_owner.stage(self.store)
        (self.runtime_a / "auth.json").symlink_to(self.store / "auth" / "codex" / "auth.json")
        (self.runtime_b / "auth.json").symlink_to(self.store / "auth" / "codex" / "auth.json")
        base = [sys.executable, "-m", "ihar.codex.auth_owner", "run", str(self.store)]
        env = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1] / "lib" / "python"))
        first = subprocess.Popen(base + [str(self.runtime_a), "hash-a", "foreground", "--", str(binary)],
                                 env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                 start_new_session=True)
        def stop_first() -> None:
            if self.record.exists():
                child = json.loads(self.record.read_text()).get("child")
                if child:
                    try:
                        os.killpg(child["pgrp"], signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            try:
                os.killpg(first.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            first.wait(timeout=5)
            first.stderr.close()
        self.addCleanup(stop_first)
        for _ in range(100):
            if marker.exists():
                break
            time.sleep(0.02)
        self.assertTrue(marker.exists(), first.stderr.read(0))
        second = subprocess.run(base + [str(self.runtime_b), "hash-b", "foreground", "--", str(binary)],
                                env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(second.returncode, 3)
        self.assertIn("owns the shared login", second.stderr)
        self.assertEqual(marker.read_text().splitlines(), ["started"])
        os.kill(first.pid, signal.SIGKILL)
        first.wait(timeout=5)
        third = subprocess.run(base + [str(self.runtime_b), "hash-b", "foreground", "--", str(binary)],
                               env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(third.returncode, 3)
        self.assertEqual(marker.read_text().splitlines(), ["started"])

    def test_vendor_materialization_keeps_owner_blocked_after_exit(self) -> None:
        auth_owner.stage(self.store)
        canonical = self.store / "auth" / "codex" / "auth.json"
        canonical.write_text("synthetic-original")
        (self.runtime_a / "auth.json").symlink_to(canonical)
        binary = self.root / "bad-codex"
        binary.write_text("#!/bin/sh\nrm \"$CODEX_HOME/auth.json\"\nprintf 'synthetic-stray' > \"$CODEX_HOME/auth.json\"\n")
        binary.chmod(0o700)
        answer = subprocess.run(
            [sys.executable, "-m", "ihar.codex.auth_owner", "run", str(self.store),
             str(self.runtime_a), "hash-a", "foreground", "--", str(binary)],
            env=dict(os.environ, CODEX_HOME=str(self.runtime_a),
                     PYTHONPATH=str(Path(__file__).resolve().parents[1] / "lib" / "python")),
            capture_output=True, text=True, timeout=5)
        self.assertEqual(answer.returncode, 3)
        self.assertIn("mutable link", answer.stderr)
        self.assertEqual(canonical.read_text(), "synthetic-original")
        self.assertEqual((self.runtime_a / "auth.json").read_text(), "synthetic-stray")
        with self.assertRaises(auth_owner.AuthOwnerError):
            auth_owner.acquire(self.runtime_b, "foreground")

    def test_detached_descendant_keeps_guardian_until_quiescent(self) -> None:
        auth_owner.stage(self.store)
        canonical = self.store / "auth" / "codex" / "auth.json"
        (self.runtime_a / "auth.json").symlink_to(canonical)
        marker = self.root / "detached-ready"
        binary = self.root / "detaching-codex"
        binary.write_text(f"""#!/usr/bin/env python3
import os, subprocess, sys, time
if len(sys.argv) > 1:
    open({str(marker)!r}, 'w').close()
    time.sleep(1.5)
else:
    subprocess.Popen([sys.executable, __file__, 'child'], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
""")
        binary.chmod(0o700)
        env = dict(os.environ, CODEX_HOME=str(self.runtime_a),
                   PYTHONPATH=str(Path(__file__).resolve().parents[1] / "lib" / "python"))
        command = [sys.executable, "-m", "ihar.codex.auth_owner", "run", str(self.store),
                   str(self.runtime_a), "hash-a", "foreground", "--", str(binary)]
        guardian = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE)
        self.addCleanup(lambda: guardian.stderr.close())
        for _ in range(100):
            if marker.exists():
                break
            time.sleep(0.02)
        self.assertTrue(marker.exists())
        time.sleep(0.2)
        self.assertIsNone(guardian.poll(), "guardian exited while detached child was live")
        with self.assertRaises(auth_owner.AuthBusy):
            auth_owner.acquire(self.runtime_b, "foreground")
        self.assertEqual(guardian.wait(timeout=5), 0)

    def test_login_requires_tty_approval_before_replacing_canonical(self) -> None:
        binary = self.root / "fake-codex"
        binary.write_text("#!/bin/sh\nprintf 'synthetic-new' > \"$CODEX_HOME/auth.json\"\n")
        binary.chmod(0o700)
        first = subprocess.run(
            [sys.executable, "-m", "ihar.codex.auth_owner", "auth", str(self.store),
             str(self.runtime_a), "--", str(binary), "login"],
            env=dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1] / "lib" / "python")),
            capture_output=True, text=True, timeout=5)
        self.assertEqual(first.returncode, 0, first.stderr)
        canonical = self.store / "auth" / "codex" / "auth.json"
        self.assertEqual(canonical.read_text(), "synthetic-new")
        canonical.write_text("synthetic-old")
        second = subprocess.run(
            [sys.executable, "-m", "ihar.codex.auth_owner", "auth", str(self.store),
             str(self.runtime_a), "--", str(binary), "login"],
            env=dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1] / "lib" / "python"),
                     IHAR_ASSUME_YES="1"), capture_output=True, text=True, timeout=5)
        self.assertEqual(second.returncode, 3)
        self.assertIn("direct TTY approval", second.stderr)
        self.assertEqual(canonical.read_text(), "synthetic-old")

    def test_managed_daemon_holds_owner_after_start_command_exits(self) -> None:
        auth_owner.stage(self.store)
        (self.runtime_a / "auth.json").symlink_to(self.store / "auth" / "codex" / "auth.json")
        binary = self.root / "daemon-codex"
        binary.write_text("""#!/usr/bin/env python3
import json, os, signal, socket, subprocess, sys, time
home = os.environ['CODEX_HOME']
sock = home + '/app-server-control/app-server-control.sock'
pidfile = home + '/daemon.pid'
if sys.argv[1:] == ['app-server', 'daemon', 'start']:
    child = subprocess.Popen([sys.executable, __file__, 'serve'], start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        if os.path.exists(sock): break
        time.sleep(.01)
    print(json.dumps({'status':'started','pid':child.pid,'socketPath':sock,'managedCodexVersion':'0.154.0'}))
elif sys.argv[1:] == ['app-server', 'daemon', 'stop']:
    pid = int(open(pidfile).read())
    os.killpg(pid, signal.SIGTERM)
    print(json.dumps({'status':'stopped'}))
elif sys.argv[1:] == ['app-server', 'daemon', 'version']:
    if os.path.exists(sock):
        print(json.dumps({'status':'running','pid':int(open(pidfile).read()),'socketPath':sock,'managedCodexVersion':'0.154.0'}))
    else: print(json.dumps({'status':'absent'}))
elif sys.argv[1:] == ['--version']:
    print('codex-cli 0.154.0')
elif sys.argv[1:] == ['serve']:
    os.makedirs(os.path.dirname(sock), exist_ok=True)
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(sock)
    open(pidfile,'w').write(str(os.getpid()))
    def shutdown(*_):
        listener.close()
        os.unlink(sock)
        sys.exit(0)
    signal.signal(signal.SIGTERM, shutdown)
    while True: time.sleep(1)
""")
        binary.chmod(0o700)
        env = dict(os.environ, CODEX_HOME=str(self.runtime_a),
                   PYTHONPATH=str(Path(__file__).resolve().parents[1] / "lib" / "python"))
        base = [sys.executable, "-m", "ihar.codex.daemon"]
        common = ["--binary", str(binary), "--home", str(self.runtime_a),
                  "--state", str(self.root / "state"), "--auth-store", str(self.store)]
        started = subprocess.run(base + ["start"] + common + ["--config-hash", "aabbccdd"],
                                 env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(started.returncode, 0, started.stderr)
        self.assertTrue(self.record.exists())
        with self.assertRaises(auth_owner.AuthBusy):
            auth_owner.acquire(self.runtime_b, "foreground")
        attached = subprocess.run(
            [sys.executable, "-m", "ihar.codex.auth_owner", "run", str(self.store),
             str(self.runtime_a), "aabbccdd", "attached", "--", "/bin/sleep", "0.3"],
            env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(attached.returncode, 0, attached.stderr)
        restarted = subprocess.run(base + ["restart"] + common + ["--config-hash", "aabbccdd"],
                                   env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(restarted.returncode, 0, restarted.stderr)
        with self.assertRaises(auth_owner.AuthBusy):
            auth_owner.acquire(self.runtime_b, "foreground")
        stopped = subprocess.run(base + ["stop"] + common, env=env,
                                 capture_output=True, text=True, timeout=5)
        self.assertEqual(stopped.returncode, 0, stopped.stderr)
        next_owner = auth_owner.acquire(self.runtime_b, "foreground")
        auth_owner.release(next_owner)

    def _review_daemon(self, mode: str) -> tuple[Path, dict[str, str], list[str]]:
        auth_owner.stage(self.store)
        (self.runtime_a / "auth.json").symlink_to(self.store / "auth" / "codex" / "auth.json")
        binary = self.root / "review-codex"
        binary.write_text("""#!/usr/bin/env python3
import json, os, signal, socket, subprocess, sys, time
home = os.environ['CODEX_HOME']
sock = home + '/app-server-control/app-server-control.sock'
pidfile = home + '/daemon.pid'
detached = home + '/detached.pid'
mode = os.environ['FAKE_DAEMON_MODE']
if sys.argv[1:] == ['app-server', 'daemon', 'start']:
    child = subprocess.Popen([sys.executable, __file__, 'serve'], start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(200):
        if os.path.exists(sock) and (mode != 'detached' or os.path.exists(detached)): break
        time.sleep(.01)
    if mode == 'malformed': print('not-json')
    else: print(json.dumps({'status':'started','pid':child.pid,'socketPath':sock}))
elif sys.argv[1:] == ['app-server', 'daemon', 'stop']:
    os.killpg(int(open(pidfile).read()), signal.SIGTERM)
    print(json.dumps({'status':'stopped'}))
elif sys.argv[1:] == ['serve']:
    os.makedirs(os.path.dirname(sock), exist_ok=True)
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(sock)
    open(pidfile,'w').write(str(os.getpid()))
    if mode == 'detached':
        child = subprocess.Popen([sys.executable, __file__, 'descendant'],
                                 start_new_session=True, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
        open(detached,'w').write(str(child.pid))
    def shutdown(*_):
        listener.close()
        os.unlink(sock)
        sys.exit(0)
    signal.signal(signal.SIGTERM, shutdown)
    while True: time.sleep(1)
elif sys.argv[1:] == ['descendant']:
    time.sleep(30)
""")
        binary.chmod(0o700)
        def cleanup() -> None:
            for name in ("daemon.pid", "detached.pid"):
                path = self.runtime_a / name
                if path.exists():
                    try:
                        os.killpg(int(path.read_text()), signal.SIGTERM)
                    except ProcessLookupError:
                        pass
        self.addCleanup(cleanup)
        env = dict(os.environ, CODEX_HOME=str(self.runtime_a), FAKE_DAEMON_MODE=mode,
                   PYTHONPATH=str(Path(__file__).resolve().parents[1] / "lib" / "python"))
        common = ["--binary", str(binary), "--home", str(self.runtime_a),
                  "--state", str(self.root / "state"), "--auth-store", str(self.store)]
        return binary, env, common

    def test_malformed_start_response_retains_owner_after_daemon_spawn(self) -> None:
        _binary, env, common = self._review_daemon("malformed")
        answer = subprocess.run([sys.executable, "-m", "ihar.codex.daemon", "start"] + common,
                                env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(answer.returncode, 3)
        self.assertTrue((self.runtime_a / "daemon.pid").exists())
        self.assertTrue(self.record.exists(), "uncertain start must retain owner")
        with self.assertRaises(auth_owner.AuthOwnerError):
            auth_owner.acquire(self.runtime_b, "foreground")

    def test_detached_daemon_descendant_blocks_stop_release(self) -> None:
        _binary, env, common = self._review_daemon("detached")
        started = subprocess.run([sys.executable, "-m", "ihar.codex.daemon", "start"] + common,
                                 env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(started.returncode, 0, started.stderr)
        self.assertTrue((self.runtime_a / "detached.pid").exists())
        stopped = subprocess.run([sys.executable, "-m", "ihar.codex.daemon", "stop"] + common,
                                 env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(stopped.returncode, 3, "detached child still owns credential")
        self.assertTrue(self.record.exists())
        with self.assertRaises(auth_owner.AuthOwnerError):
            auth_owner.acquire(self.runtime_b, "foreground")
        os.killpg(int((self.runtime_a / "detached.pid").read_text()), signal.SIGTERM)
        for _ in range(100):
            if json.loads(self.record.read_text()).get("state") == "quiescent":
                break
            time.sleep(0.05)
        self.assertEqual(json.loads(self.record.read_text()).get("state"), "quiescent")
        retried = subprocess.run([sys.executable, "-m", "ihar.codex.daemon", "stop"] + common,
                                 env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(retried.returncode, 0, retried.stderr)
        next_owner = auth_owner.acquire(self.runtime_b, "foreground")
        auth_owner.release(next_owner)

    def test_daemon_refuses_missing_auth_link_before_vendor_start(self) -> None:
        marker = self.root / "started"
        binary = self.root / "fake-daemon"
        binary.write_text(f"#!/bin/sh\ntouch '{marker}'\nprintf '{{\"status\":\"absent\"}}\\n'\n")
        binary.chmod(0o700)
        answer = subprocess.run(
            [sys.executable, "-m", "ihar.codex.daemon", "start", "--binary", str(binary),
             "--home", str(self.runtime_a), "--state", str(self.root / "state"),
             "--auth-store", str(self.store)],
            env=dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1] / "lib" / "python")),
            capture_output=True, text=True, timeout=5)
        self.assertEqual(answer.returncode, 3)
        self.assertFalse(marker.exists())

    def test_login_status_reads_private_copy_without_publishing(self) -> None:
        auth_owner.stage(self.store)
        canonical = self.store / "auth" / "codex" / "auth.json"
        canonical.write_text("synthetic-original")
        binary = self.root / "status-codex"
        binary.write_text("#!/bin/sh\n[ \"$(cat \"$CODEX_HOME/auth.json\")\" = synthetic-original ]\n")
        binary.chmod(0o700)
        answer = subprocess.run(
            [sys.executable, "-m", "ihar.codex.auth_owner", "auth", str(self.store),
             str(self.runtime_a), "--", str(binary), "login", "status"],
            env=dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1] / "lib" / "python")),
            capture_output=True, text=True, timeout=5)
        self.assertEqual(answer.returncode, 0, answer.stderr)
        self.assertEqual(canonical.read_text(), "synthetic-original")

    def test_logout_needs_direct_tty_and_keeps_canonical_without_it(self) -> None:
        auth_owner.stage(self.store)
        canonical = self.store / "auth" / "codex" / "auth.json"
        canonical.write_text("synthetic-original")
        binary = self.root / "logout-codex"
        binary.write_text("#!/bin/sh\nrm \"$CODEX_HOME/auth.json\"\n")
        binary.chmod(0o700)
        answer = subprocess.run(
            [sys.executable, "-m", "ihar.codex.auth_owner", "auth", str(self.store),
             str(self.runtime_a), "--", str(binary), "logout"],
            env=dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1] / "lib" / "python"),
                     IHAR_ASSUME_YES="1"), capture_output=True, text=True, timeout=5)
        self.assertEqual(answer.returncode, 3)
        self.assertIn("direct TTY approval", answer.stderr)
        self.assertEqual(canonical.read_text(), "synthetic-original")


if __name__ == "__main__":
    unittest.main()
