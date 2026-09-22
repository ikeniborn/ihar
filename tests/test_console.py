#!/usr/bin/env python3
"""Console broker boundary, records and tab lifecycle (LLD 13.2, gate G6).

Every condition of G6 is a case here: a non-loopback bind is refused, a request
without the token cookie or with a foreign Origin is refused, a tab receives the base
environment only, and no terminal output reaches disk.
"""

import base64
import hashlib
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from ihar import jsonio

PASS = FAIL = 0
ROOT = Path(__file__).resolve().parent.parent


def check(label, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
    else:
        FAIL += 1
        print(f"FAIL {label}")


def fake_root(tmp: Path) -> Path:
    """A checkout whose `ihar.sh` records its environment and prints a marker."""
    root = tmp / "fake-root"
    (root / "manifests" / "profiles").mkdir(parents=True)
    for name, console in (("standard", "allow"), ("locked", "refuse")):
        (root / "manifests" / "profiles" / f"{name}.json").write_text(json.dumps({
            "schema": 1, "name": name, "guarantee": "none, this is a test profile",
            "hooks": "best-effort", "gateway": "off",
            "masking_level": "off", "sandbox": "vendor-default", "netpolicy": None,
            "remote": ["claude", "codex"], "mcp": {"strict": False}, "acp": "allow",
            "console": console, "env_passthrough": [], "handoff": {"system_prompt": False},
        }), encoding="utf-8")
    real = Path(__file__).resolve().parent.parent
    (root / "console" / "vendor").mkdir(parents=True)
    for name in ("index.html", "app.js", "app.css"):
        (root / "console" / name).write_bytes((real / "console" / name).read_bytes())
    for name in ("xterm.js", "xterm.css"):
        (root / "console" / "vendor" / name).write_bytes(
            (real / "console" / "vendor" / name).read_bytes())
    (root / ".ihar-lockfile.json").write_bytes((real / ".ihar-lockfile.json").read_bytes())
    script = root / "ihar.sh"
    script.write_text(
        "#!/usr/bin/env bash\n"
        'if [[ "$1" == sessions ]]; then printf "%s\\n" "$*" >> "$HOME/rename.log"; exit 0; fi\n'
        'if [[ "$1" == check ]]; then printf "profile      standard\\nconsole      running\\n"; exit 0; fi\n'
        'env > "$HOME/env-dump.$$"\n'
        'printf "tab-ready vendor=%s\\n" "$1"\n'
        "sleep 30\n", encoding="utf-8")
    script.chmod(0o755)
    return root


def start_broker(tmp: Path, root: Path, port="0", bind="127.0.0.1", max_sessions="2"):
    state_root = tmp / "state-root"
    state_root.mkdir(exist_ok=True)
    environment = {
        "PATH": os.environ["PATH"], "HOME": str(tmp / "home"), "TERM": "xterm",
        "PYTHONPATH": str(ROOT / "lib" / "python"),
        "IHAR_ROOT": str(root), "IHAR_STATE_ROOT": str(state_root),
        "IHAR_CONSOLE_MAX_SESSIONS": max_sessions,
        # An ambient secret the broker must not pass into any tab.
        "GITHUB_TOKEN": "ghp_aaaaaaaaaaaaaaaaaaaaaa",
    }
    process = subprocess.Popen(
        [sys.executable, "-m", "ihar.console.broker", "--port", port, "--bind", bind],
        env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return process, state_root


def wait_for(path: Path, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.is_file():
            return json.loads(path.read_text(encoding="utf-8"))
        time.sleep(0.05)
    return None


def request(port, method, target, cookie=None, body=None, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    head = dict(headers or {})
    if cookie:
        head["Cookie"] = f"ihar_console={cookie}"
    if body is not None:
        head["Content-Type"] = "application/json"
        body = json.dumps(body).encode()
    connection.request(method, target, body=body, headers=head)
    response = connection.getresponse()
    payload = response.read()
    connection.close()
    return response.status, dict(response.getheaders()), payload


def websocket(port, target, cookie, origin):
    """Open a WebSocket and return the socket, or the refusing status line."""
    key = base64.b64encode(os.urandom(16)).decode()
    stream = socket.create_connection(("127.0.0.1", port), timeout=10)
    stream.sendall((
        f"GET {target} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
        f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
        f"Origin: {origin}\r\nCookie: ihar_console={cookie}\r\n\r\n"
    ).encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = stream.recv(4096)
        if not chunk:
            break
        head += chunk
    status = head.split(b"\r\n", 1)[0].decode(errors="replace")
    if " 101 " not in status:
        stream.close()
        return None, status
    expected = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-5AB0DC85B11F").encode()).digest()).decode()
    return (stream, status) if expected.encode() in head else (None, "bad accept")


def read_frames(stream, deadline=6.0):
    """Collect text payloads until the deadline; server frames are never masked."""
    stream.settimeout(0.4)
    end = time.time() + deadline
    buffer = b""
    out = []
    while time.time() < end:
        try:
            chunk = stream.recv(8192)
        except socket.timeout:
            continue
        if not chunk:
            break
        buffer += chunk
        while len(buffer) >= 2:
            length = buffer[1] & 0x7F
            offset = 2
            if length == 126:
                if len(buffer) < 4:
                    break
                length = int.from_bytes(buffer[2:4], "big")
                offset = 4
            elif length == 127:
                if len(buffer) < 10:
                    break
                length = int.from_bytes(buffer[2:10], "big")
                offset = 10
            if len(buffer) < offset + length:
                break
            out.append(buffer[offset:offset + length])
            buffer = buffer[offset + length:]
    return out


def send_text(stream, text: bytes) -> None:
    mask = os.urandom(4)
    payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(text))
    header = bytes([0x81, 0x80 | len(text)]) if len(text) < 126 else \
        bytes([0x81, 0xFE]) + len(text).to_bytes(2, "big")
    stream.sendall(header + mask + payload)


def main():
    global PASS, FAIL
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as raw:
        tmp = Path(raw)
        (tmp / "home").mkdir()
        root = fake_root(tmp)

        # G6: a configured bind that is not loopback is refused, never downgraded.
        refused, _ = start_broker(tmp, root, bind="10.11.12.13")
        refused.wait(timeout=10)
        check("a non-loopback bind is exit 2", refused.returncode == 2)
        check("the refusal names the bind", "loopback" in (refused.stderr.read() or ""))

        broker, state_root = start_broker(tmp, root)
        record = wait_for(state_root / "console" / "daemon.json")
        check("the broker records itself", record is not None)
        if record is None:
            print(broker.stderr.read())
            broker.kill()
            print(f"PASS={PASS} FAIL={FAIL}")
            return 1
        port = record["port"]
        try:
            jsonio.check("console-daemon", record)
            check("the daemon record validates", True)
        except jsonio.SchemaError as error:
            check(f"the daemon record validates ({error})", False)

        token_path = state_root / "console" / "token"
        token = token_path.read_text(encoding="utf-8").strip()
        check("the token is owner-only", oct(token_path.stat().st_mode & 0o777) == "0o600")
        check("the record keeps only the token digest",
              record["token_sha256"] == hashlib.sha256(token.encode()).hexdigest())

        # G6: no cookie, no service.
        status, _, _ = request(port, "GET", "/")
        check("a request without the cookie is 401", status == 401)
        status, _, _ = request(port, "GET", "/api/state", cookie="wrong-token")
        check("a wrong cookie is 401", status == 401)

        status, headers, _ = request(port, "GET", f"/?t={token}")
        cookie_header = headers.get("Set-Cookie", "")
        check("the token exchanges for a cookie", status == 302)
        check("the cookie is HttpOnly", "HttpOnly" in cookie_header)
        check("the cookie is SameSite=Strict", "SameSite=Strict" in cookie_header)
        status, _, _ = request(port, "GET", "/", cookie=token)
        check("the cookie serves the page", status == 200)

        # G6: a foreign Origin cannot open the socket even with a stolen-looking cookie.
        stream, line = websocket(port, "/ws/none", token, "http://evil.example")
        check("a foreign Origin is refused", stream is None and " 403 " in line)

        # A project whose profile refuses the console fails that tab, not the broker.
        locked = tmp / "locked-project"
        locked.mkdir()
        (locked / ".ihar_config").write_text("IHAR_PROFILE=locked\n", encoding="utf-8")
        status, _, payload = request(port, "POST", "/api/tabs", cookie=token,
                                     body={"project_root": str(locked), "vendor": "codex"})
        check("a console: refuse profile is refused", status == 403)
        check("the refusal names the profile", b"locked" in payload)
        status, _, _ = request(port, "GET", "/api/state", cookie=token)
        check("the broker keeps serving after a refused tab", status == 200)

        # A tab runs the ordinary CLI under a pseudo-terminal.
        project = tmp / "project"
        project.mkdir()
        status, _, payload = request(port, "POST", "/api/tabs", cookie=token,
                                     body={"project_root": str(project), "vendor": "codex"})
        check("a tab is created", status == 201)
        sid = json.loads(payload)["sid"] if status == 201 else ""
        session = wait_for(state_root / "console" / "s" / f"{sid}.json") if sid else None
        check("the session record exists", session is not None)
        if session:
            try:
                jsonio.check("console-session", session)
                check("the session record validates", True)
            except jsonio.SchemaError as error:
                check(f"the session record validates ({error})", False)
            check("the record carries the resolved profile", session["profile"] == "standard")
            check("the record carries no transcript field",
                  "output" not in session and "scrollback" not in session)

        stream, line = websocket(port, f"/ws/{sid}", token, f"http://127.0.0.1:{port}")
        check(f"the tab attaches over a WebSocket ({line})", stream is not None)
        if stream:
            frames = read_frames(stream)
            joined = b"".join(frames)
            check("the tab replays the vendor output", b"tab-ready vendor=codex" in joined)
            send_text(stream, b'{"type":"resize","cols":100,"rows":30}')
            stream.close()

        # G6: the tab gets the base environment, so an ambient secret cannot follow it.
        dumps = list((tmp / "home").glob("env-dump.*"))
        check("the tab environment was captured", bool(dumps))
        if dumps:
            dumped = dumps[0].read_text(encoding="utf-8", errors="replace")
            check("an ambient secret is absent from the tab",
                  "ghp_aaaaaaaaaaaaaaaaaaaaaa" not in dumped)
            check("the tab knows it is a console tab", "IHAR_CONSOLE=1" in dumped)
            check("the tab carries a launch id", "IHAR_CONSOLE_LAUNCH_ID=" in dumped)

        # G6: terminal output never reaches disk.
        written = [path for path in (state_root / "console").rglob("*")
                   if path.is_file() and path.suffix not in (".json", ".sock")
                   and path.name != "token"]
        check(f"no terminal output is written to disk ({written})", not written)

        # The session cap is a refusal, not an unbounded window.
        for index in range(2):
            extra = tmp / f"extra-{index}"
            extra.mkdir()
            status, _, _ = request(port, "POST", "/api/tabs", cookie=token,
                                   body={"project_root": str(extra), "vendor": "claude"})
        check("the session cap refuses the third tab", status == 409)

        # The sidebar is every project state on the machine, not this one's.
        other = tmp / "other-project"
        other.mkdir()
        other_state = state_root / "beefcafe"
        (other_state / "st" / "claude").mkdir(parents=True)
        (other_state / "st" / "codex").mkdir(parents=True)
        (other_state / "home.json").write_text(json.dumps({
            "schema": 3, "project_root": str(other), "created": "2026-09-22T06:00:00Z",
            "vendors": ["claude"], "runtimes": {}, "migrated_from": {}}), encoding="utf-8")
        first = "0199f3a1-7c2e-7a41-9b0d-3f9a1cbd2e51"
        second = "0199f3a1-7c2e-7a41-9b0d-3f9a1cbd2e52"
        index = other_state / "sessions.jsonl"
        with index.open("w", encoding="utf-8") as stream:
            for row in (
                {"schema": 1, "ihar_id": first, "vendor": "claude",
                 "vendor_session_id": "claude-one", "project": "other", "cwd": str(other),
                 "git_branch": None, "title": "first leg", "model": None, "profile": "standard",
                 "started_at": "2026-09-22T06:00:00Z", "updated_at": "2026-09-22T06:00:00Z",
                 "parent_ihar_id": None, "handoff_from": None, "handoff_to": second,
                 "tags": [], "source": "launch"},
                {"schema": 1, "ihar_id": second, "vendor": "codex",
                 "vendor_session_id": "codex-two", "project": "other", "cwd": str(other),
                 "git_branch": None, "title": "second leg", "model": None, "profile": "standard",
                 "started_at": "2026-09-22T06:05:00Z", "updated_at": "2026-09-22T06:05:00Z",
                 "parent_ihar_id": first, "handoff_from": first, "handoff_to": None,
                 "tags": [], "source": "launch"},
            ):
                stream.write(json.dumps(row) + "\n")

        # Two vendor transcripts, one on each side of the handoff.
        claude_home = other_state / "st" / "claude" / "projects" / "x"
        claude_home.mkdir(parents=True)
        (claude_home / "claude-one.jsonl").write_text("\n".join(json.dumps(record) for record in (
            {"timestamp": "2026-09-22T06:01:00Z", "message": {"role": "user", "content": "start here"}},
            {"timestamp": "2026-09-22T06:02:00Z", "message": {"role": "assistant", "content": "done the first half"}},
        )), encoding="utf-8")
        codex_home = other_state / "st" / "codex" / "sessions"
        codex_home.mkdir(parents=True)
        (codex_home / "rollout-codex-two.jsonl").write_text(json.dumps(
            {"timestamp": "2026-09-22T06:06:00Z",
             "message": {"role": "assistant", "content": "continued after the handoff"}}), encoding="utf-8")
        (other_state / "handoff").mkdir()
        (other_state / "handoff" / f"{first}.json").write_text(json.dumps({
            "bytes": 4096, "masking_level": "standard", "target_vendor": "codex",
            "history": {"mode": "transcript", "file": "/dev/null"}}), encoding="utf-8")

        # A badge the status hook would have written.
        (other_state / "status").mkdir()
        (other_state / "status" / "codex-codex-two.json").write_text(json.dumps({
            "schema": 1, "vendor": "codex", "vendor_session_id": "codex-two",
            "state": "waiting-approval", "at": "2026-09-22T06:07:00Z"}), encoding="utf-8")

        status, _, payload = request(port, "GET", "/api/sidebar?refresh=1", cookie=token)
        view = json.loads(payload) if status == 200 else {}
        check("the sidebar answers", status == 200)
        listed = {project["state_id"]: project for project in view.get("projects", [])}
        check("the sidebar spans every project state", "beefcafe" in listed)
        rows = {row["ihar_id"]: row for row in listed.get("beefcafe", {}).get("sessions", [])}
        check("the sidebar lists both legs", {first, second} <= set(rows))
        check("the badge reaches the sidebar",
              rows.get(second, {}).get("status") == "waiting-approval")
        check("a session with no badge is unknown, not running",
              rows.get(first, {}).get("status") == "unknown")

        status, _, payload = request(port, "GET", f"/api/thread/beefcafe/{second}", cookie=token)
        projection = json.loads(payload) if status == 200 else {}
        items = projection.get("items", [])
        kinds = [item["kind"] for item in items]
        texts = [item.get("text") for item in items if item["kind"] == "message"]
        check("the projection answers", status == 200)
        check("the projection walks back to the first leg",
              projection.get("sessions") == [first, second])
        check("the projection orders both vendors",
              texts[:1] == ["start here"] and texts[-1:] == ["continued after the handoff"])
        check("the projection marks the handoff", "handoff" in kinds)
        marker_item = next((item for item in items if item["kind"] == "handoff"), {})
        check("the marker says what the package carried", marker_item.get("bytes") == 4096)
        check("the projection keeps nothing on disk",
              not list((other_state / "handoff").glob("*-projection*")))

        # A rotated vendor session is a labelled gap, never invented content.
        (claude_home / "claude-one.jsonl").unlink()
        status, _, payload = request(port, "GET", f"/api/thread/beefcafe/{second}", cookie=token)
        projection = json.loads(payload)
        check("a missing transcript is reported as a gap",
              any(gap["ihar_id"] == first for gap in projection.get("gaps", [])))

        # Renaming goes through the CLI, which is where the adapters live.
        status, _, _ = request(port, "POST", f"/api/sessions/beefcafe/{second}/name",
                               cookie=token, body={"title": "renamed leg"})
        check("a rename is accepted", status == 200)
        log = (tmp / "home" / "rename.log")
        check("the rename reached the CLI",
              log.is_file() and "sessions name" in log.read_text(encoding="utf-8"))

        # The window and its assets are served from the pinned tree, never from a network.
        status, headers, page = request(port, "GET", "/", cookie=token)
        check("the window is served", status == 200 and b"ihar console" in page)
        check("the window loads its terminal locally", b'src="/static/xterm.js"' in page)
        check("the window fetches nothing remote",
              b"//cdn." not in page and b"https://" not in page)
        status, headers, script = request(port, "GET", "/static/xterm.js", cookie=token)
        check("the terminal asset is served", status == 200 and len(script) > 100000)
        check("the terminal asset is javascript",
              headers.get("Content-Type", "").startswith("text/javascript"))
        status, _, _ = request(port, "GET", "/static/xterm.js")
        check("an asset needs the cookie too", status == 401)
        status, _, _ = request(port, "GET", "/static/../etc/passwd", cookie=token)
        check("an asset outside the map is refused", status == 404)
        status, _, app = request(port, "GET", "/static/app.js", cookie=token)
        check("the window script is served", status == 200)
        check("the window script fetches nothing remote",
              b"http://" not in app.replace(b"http://${location.host}", b"") and
              b"https://" not in app)

        # A terminal that is not the reviewed one is refused rather than served.
        tampered = root / "console" / "vendor" / "xterm.js"
        original = tampered.read_bytes()
        tampered.write_bytes(original + b"\n/* tampered */\n")
        status, _, refusal = request(port, "GET", "/static/xterm.js", cookie=token)
        check("a tampered terminal asset is refused", status == 503)
        check("the refusal names the digest", b"reviewed digest" in refusal)
        tampered.write_bytes(original)
        status, _, _ = request(port, "GET", "/static/xterm.js", cookie=token)
        check("restoring the asset restores the service", status == 200)

        # The check panel reads the project's own report through the CLI.
        status, _, payload = request(port, "GET", "/api/check/beefcafe", cookie=token)
        report = json.loads(payload) if status == 200 else {}
        check("the check panel answers", status == 200)
        check("the check panel carries the project's report",
              "console      running" in (report.get("text") or ""))

        # The handoff button runs `ihar switch` in a tab rather than reimplementing it.
        status, _, payload = request(port, "POST", f"/api/sessions/beefcafe/{second}/switch",
                                     cookie=token, body={"to": "claude", "history": "transcript"})
        check("a switch tab is created", status == 201)
        switch_sid = json.loads(payload)["sid"] if status == 201 else ""
        switch_record = wait_for(state_root / "console" / "s" / f"{switch_sid}.json") if switch_sid else None
        check("the switch tab names the source session",
              bool(switch_record) and switch_record["ihar_id"] == second)
        status, _, payload = request(port, "POST", f"/api/sessions/beefcafe/{second}/switch",
                                     cookie=token, body={"to": "gemini", "history": "summary"})
        check("an unknown vendor is refused", status == 400)
        status, _, payload = request(port, "POST", f"/api/sessions/beefcafe/{second}/switch",
                                     cookie=token, body={"to": "claude", "history": "everything"})
        check("an unknown history mode is refused", status == 400)

        broker.terminate()
        broker.wait(timeout=10)
        # A supervisor outlives its broker: that is why it exists.
        alive = session and Path(f"/proc/{session['pid']}").exists()
        check("the supervisor survives the broker", bool(alive))
        for record in (state_root / "console" / "s").glob("*.json"):
            try:
                pid = int(json.loads(record.read_text(encoding="utf-8")).get("pid") or 0)
            except ValueError:
                continue
            if pid:
                subprocess.run(["kill", "-TERM", str(pid)], check=False)
        time.sleep(1.0)

    print(f"PASS={PASS} FAIL={FAIL}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
