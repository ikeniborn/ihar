#!/usr/bin/env python3
"""Exclusive Codex credential writer tests with synthetic runtimes."""

from __future__ import annotations

import json
import os
import signal
import socket as socket_module
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
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
