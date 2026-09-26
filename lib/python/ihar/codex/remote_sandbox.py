"""Linux mount-namespace boundary for a daemon-attached Codex client."""

from __future__ import annotations

import ctypes
import errno
import json
import os
import secrets
import stat
import sys
from pathlib import Path


_MS_RDONLY = 1
_MS_NOSUID = 2
_MS_NODEV = 4
_MS_NOEXEC = 8
_MS_BIND = 4096
_MS_REC = 16384
_MS_PRIVATE = 1 << 18
_AT_FDCWD = -100
_AT_RECURSIVE = 0x8000
_MOUNT_ATTR_RDONLY = 1
_PR_CAPBSET_DROP = 24
_PR_CAPBSET_READ = 23
_PR_SET_NO_NEW_PRIVS = 38
_PR_GET_NO_NEW_PRIVS = 39
_LINUX_CAPABILITY_VERSION_3 = 0x20080522
_MAX_PROOF = 4096


class SandboxError(RuntimeError):
    """The remote client boundary could not be proved."""


class _CapHeader(ctypes.Structure):
    _fields_ = [("version", ctypes.c_uint32), ("pid", ctypes.c_int)]


class _CapData(ctypes.Structure):
    _fields_ = [("effective", ctypes.c_uint32),
                ("permitted", ctypes.c_uint32),
                ("inheritable", ctypes.c_uint32)]


class _MountAttr(ctypes.Structure):
    _fields_ = [("attr_set", ctypes.c_uint64), ("attr_clr", ctypes.c_uint64),
                ("propagation", ctypes.c_uint64), ("userns_fd", ctypes.c_uint64)]


_LIBC = ctypes.CDLL(None, use_errno=True)
_LIBC.mount.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
                        ctypes.c_ulong, ctypes.c_char_p]
_LIBC.mount.restype = ctypes.c_int
if hasattr(_LIBC, "mount_setattr"):
    _LIBC.mount_setattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint,
                                    ctypes.POINTER(_MountAttr), ctypes.c_size_t]
    _LIBC.mount_setattr.restype = ctypes.c_int
_LIBC.prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong,
                        ctypes.c_ulong, ctypes.c_ulong]
_LIBC.prctl.restype = ctypes.c_int
_LIBC.capset.argtypes = [ctypes.POINTER(_CapHeader), ctypes.POINTER(_CapData)]
_LIBC.capset.restype = ctypes.c_int
_LIBC.capget.argtypes = [ctypes.POINTER(_CapHeader), ctypes.POINTER(_CapData)]
_LIBC.capget.restype = ctypes.c_int


def _syscall_error(name: str) -> SandboxError:
    return SandboxError(f"Codex remote sandbox {name} failed: {os.strerror(ctypes.get_errno())}")


def _mount(source: str | None, target: Path, flags: int, *,
           filesystem: str | None = None, data: str | None = None) -> None:
    encoded_source = None if source is None else os.fsencode(source)
    encoded_filesystem = None if filesystem is None else os.fsencode(filesystem)
    encoded_data = None if data is None else os.fsencode(data)
    if _LIBC.mount(encoded_source, os.fsencode(target), encoded_filesystem,
                   flags, encoded_data) != 0:
        raise _syscall_error("mount")


def _mount_read_only(path: Path, *, recursive: bool, read_only: bool) -> None:
    if not hasattr(_LIBC, "mount_setattr"):
        raise SandboxError("Codex remote recursive mount enforcement is unavailable")
    attributes = _MountAttr(
        attr_set=_MOUNT_ATTR_RDONLY if read_only else 0,
        attr_clr=0 if read_only else _MOUNT_ATTR_RDONLY,
        propagation=0,
        userns_fd=0,
    )
    flags = _AT_RECURSIVE if recursive else 0
    if _LIBC.mount_setattr(_AT_FDCWD, os.fsencode(path), flags,
                           ctypes.byref(attributes), ctypes.sizeof(attributes)) != 0:
        raise _syscall_error("recursive read-only mount")


def _identity(path: Path, *, follow: bool = False) -> tuple[int, int, int]:
    metadata = path.stat(follow_symlinks=follow)
    return metadata.st_dev, metadata.st_ino, stat.S_IFMT(metadata.st_mode)


def _validate_paths(store: Path, runtime: Path, client_state: Path) -> dict:
    store = Path(os.path.abspath(store))
    runtime = Path(os.path.abspath(runtime))
    client_state = Path(os.path.abspath(client_state))
    canonical_dir = store / "auth" / "codex"
    canonical = canonical_dir / "auth.json"
    link = runtime / "auth.json"
    if not runtime.is_dir() or runtime.is_symlink():
        raise SandboxError("Codex remote runtime topology is invalid")
    link_metadata = os.lstat(link)
    if not stat.S_ISLNK(link_metadata.st_mode) or os.readlink(link) != str(canonical):
        raise SandboxError("Codex remote credential link is invalid")
    descriptor = os.open(canonical, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        canonical_metadata = os.fstat(descriptor)
        if not stat.S_ISREG(canonical_metadata.st_mode):
            raise SandboxError("Codex remote credential owner is invalid")
        os.read(descriptor, 1)
    finally:
        os.close(descriptor)
    state_metadata = os.stat(client_state, follow_symlinks=False)
    if (not stat.S_ISDIR(state_metadata.st_mode) or state_metadata.st_uid != os.geteuid()
        or stat.S_IMODE(state_metadata.st_mode) != 0o700):
        raise SandboxError("Codex remote client state is invalid")
    for protected in (runtime.parent, canonical_dir):
        try:
            client_state.relative_to(protected)
        except ValueError:
            pass
        else:
            raise SandboxError("Codex remote client state overlaps protected paths")
    return {
        "store": store,
        "runtime": runtime,
        "canonical_dir": canonical_dir,
        "canonical": canonical,
        "link": link,
        "client_state": client_state,
        "runtime_identity": _identity(runtime),
        "link_identity": _identity(link),
        "canonical_identity": _identity(canonical),
    }


def create_sentinels(runtime: Path, canonical_dir: Path, host_parent: Path) -> list[dict]:
    """Create fabricated mutation targets adjacent to both protected views."""
    token = secrets.token_hex(12)
    result: list[dict] = []
    try:
        for parent in (Path(runtime).resolve().parent, Path(canonical_dir).resolve()):
            for role in ("target", "rename", "symlink"):
                path = parent / f".ihar-remote-{token}-{role}"
                if role == "symlink":
                    os.symlink("fabricated-target", path)
                else:
                    descriptor = os.open(
                        path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
                    try:
                        os.write(descriptor, b"synthetic-sentinel")
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
                metadata = os.lstat(path)
                result.append({"path": str(path), "role": role, "dev": metadata.st_dev,
                               "ino": metadata.st_ino, "mode": stat.S_IFMT(metadata.st_mode)})
        path = Path(host_parent).resolve() / f".ihar-remote-{token}-host"
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
                             0o600)
        try:
            os.write(descriptor, b"synthetic-host-sentinel")
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        metadata = os.lstat(path)
        result.append({"path": str(path), "role": "host", "dev": metadata.st_dev,
                       "ino": metadata.st_ino, "mode": stat.S_IFMT(metadata.st_mode)})
    except OSError:
        cleanup_sentinels(result)
        raise
    return result


def cleanup_sentinels(sentinels: list[dict]) -> None:
    """Remove only unchanged fabricated sentinels."""
    for item in sentinels:
        path = Path(item["path"])
        try:
            metadata = os.lstat(path)
        except FileNotFoundError:
            continue
        if ((metadata.st_dev, metadata.st_ino, stat.S_IFMT(metadata.st_mode))
            != (item["dev"], item["ino"], item["mode"])):
            raise SandboxError("Codex remote sentinel identity changed")
        path.unlink()


def _validate_sentinels(paths: dict, sentinels: list[dict]) -> None:
    expected_parents = {paths["runtime"].parent, paths["canonical_dir"]}
    observed = {(Path(item.get("path", "")).parent, item.get("role"))
                for item in sentinels if isinstance(item, dict)}
    expected = {(parent, role) for parent in expected_parents
                for role in ("target", "rename", "symlink")}
    host_items = [item for item in sentinels if item.get("role") == "host"]
    if (len(host_items) != 1
        or Path(host_items[0].get("path", "")).parent != paths["client_state"].parent):
        raise SandboxError("Codex remote host sentinel is incomplete")
    expected.add((Path(host_items[0].get("path", "")).parent, "host"))
    if len(sentinels) != len(expected) or observed != expected:
        raise SandboxError("Codex remote sentinels are incomplete")
    for item in sentinels:
        metadata = os.lstat(item["path"])
        if ((metadata.st_dev, metadata.st_ino, stat.S_IFMT(metadata.st_mode))
            != (item.get("dev"), item.get("ino"), item.get("mode"))):
            raise SandboxError("Codex remote sentinel identity changed")


def _enter_namespaces() -> int:
    if not sys.platform.startswith("linux") or not hasattr(os, "unshare"):
        raise SandboxError("Codex remote sandbox requires Linux namespaces")
    try:
        last_cap = int(Path("/proc/sys/kernel/cap_last_cap").read_text(encoding="ascii"))
    except (OSError, ValueError) as error:
        raise SandboxError("Codex remote capability range is unavailable") from error
    uid, gid = os.getuid(), os.getgid()
    try:
        os.unshare(os.CLONE_NEWUSER)
    except OSError as error:
        raise SandboxError("Codex remote user namespace is unavailable") from error
    try:
        Path("/proc/self/setgroups").write_text("deny", encoding="ascii")
    except FileNotFoundError:
        pass
    try:
        Path("/proc/self/uid_map").write_text(f"0 {uid} 1\n", encoding="ascii")
        Path("/proc/self/gid_map").write_text(f"0 {gid} 1\n", encoding="ascii")
        os.unshare(os.CLONE_NEWNS)
    except OSError as error:
        raise SandboxError("Codex remote namespace mapping failed") from error
    _mount(None, Path("/"), _MS_REC | _MS_PRIVATE)
    return last_cap


def _isolate_root(paths: dict) -> None:
    _mount("/", Path("/"), _MS_BIND | _MS_REC)
    for path in (paths["runtime"].parent, paths["canonical_dir"], paths["client_state"]):
        _mount(str(path), path, _MS_BIND | _MS_REC)
    _mount("ihar-private-proc", Path("/proc"), _MS_NOSUID | _MS_NODEV | _MS_NOEXEC,
           filesystem="tmpfs", data="size=4096,mode=0555")
    _mount_read_only(Path("/"), recursive=True, read_only=True)
    _mount_read_only(paths["client_state"], recursive=True, read_only=False)


def _expect_read_only(callable_) -> None:
    try:
        callable_()
    except OSError as error:
        if error.errno == errno.EROFS:
            return
        raise SandboxError("Codex remote sentinel mutation had an unexpected result") from error
    raise SandboxError("Codex remote sentinel mutation was not refused")


def _probe_mutations(sentinels: list[dict]) -> dict[str, str]:
    groups: dict[Path, dict[str, Path]] = {}
    for item in sentinels:
        path = Path(item["path"])
        if item["role"] != "host":
            groups.setdefault(path.parent, {})[item["role"]] = path
    for items in groups.values():
        target = items["target"]
        _expect_read_only(lambda: os.open(target, os.O_WRONLY | os.O_CLOEXEC))
        _expect_read_only(lambda: os.truncate(target, 0))
        _expect_read_only(lambda: os.replace(items["rename"], target))
        _expect_read_only(lambda: os.unlink(target))
        _expect_read_only(lambda: os.replace(items["symlink"], target))
    host = Path(next(item["path"] for item in sentinels if item["role"] == "host"))
    _expect_read_only(lambda: os.open(host, os.O_WRONLY | os.O_CLOEXEC))
    proc_alias = Path("/proc") / str(os.getppid()) / "root" / host.relative_to("/")
    try:
        descriptor = os.open(proc_alias, os.O_WRONLY | os.O_CLOEXEC)
    except OSError as error:
        if error.errno not in (errno.ENOENT, errno.ENOTDIR, errno.EACCES, errno.EROFS):
            raise SandboxError("Codex remote procfs alias probe had an unexpected result") from error
    else:
        os.close(descriptor)
        raise SandboxError("Codex remote procfs alias remained writable")
    result = {name: "refused" for name in
              ("write", "truncate", "rename", "unlink", "symlink_replace")}
    result.update(host_write="refused", proc_root_write="inaccessible")
    return result


def _drop_capabilities(last_cap: int) -> None:
    for capability in range(last_cap + 1):
        if _LIBC.prctl(_PR_CAPBSET_DROP, capability, 0, 0, 0) != 0:
            raise _syscall_error("capability bounding-set drop")
    header = _CapHeader(_LINUX_CAPABILITY_VERSION_3, 0)
    data = (_CapData * 2)()
    if _LIBC.capset(ctypes.byref(header), data) != 0:
        raise _syscall_error("capability drop")
    if _LIBC.prctl(_PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        raise _syscall_error("no_new_privs")


def _security_status(last_cap: int) -> dict[str, str]:
    header = _CapHeader(_LINUX_CAPABILITY_VERSION_3, 0)
    data = (_CapData * 2)()
    if _LIBC.capget(ctypes.byref(header), data) != 0:
        raise _syscall_error("capability verification")
    if any(item.effective or item.permitted or item.inheritable for item in data):
        raise SandboxError("Codex remote capabilities were not fully dropped")
    for capability in range(last_cap + 1):
        observed = _LIBC.prctl(_PR_CAPBSET_READ, capability, 0, 0, 0)
        if observed < 0:
            raise _syscall_error("capability bounding-set verification")
        if observed:
            raise SandboxError("Codex remote capabilities were not fully dropped")
    no_new_privs = _LIBC.prctl(_PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0)
    if no_new_privs < 0:
        raise _syscall_error("no_new_privs verification")
    expected = {"CapEff": "0000000000000000", "CapPrm": "0000000000000000",
                "CapBnd": "0000000000000000", "NoNewPrivs": "1"}
    if no_new_privs != 1:
        raise SandboxError("Codex remote capabilities were not fully dropped")
    return expected


def prepare(store: Path, runtime: Path, client_state: Path,
            sentinels: list[dict]) -> dict:
    """Install and prove the namespace boundary before any vendor exec."""
    paths = _validate_paths(store, runtime, client_state)
    _validate_sentinels(paths, sentinels)
    last_cap = _enter_namespaces()
    _isolate_root(paths)
    if (not os.statvfs(Path("/")).f_flag & os.ST_RDONLY
        or not os.statvfs(paths["runtime"]).f_flag & os.ST_RDONLY
        or not os.statvfs(paths["canonical"]).f_flag & os.ST_RDONLY
        or os.statvfs(paths["client_state"]).f_flag & os.ST_RDONLY):
        raise SandboxError("Codex remote protected mounts are not read-only")
    if os.listdir("/proc"):
        raise SandboxError("Codex remote procfs is not private")
    if (_identity(paths["runtime"]) != paths["runtime_identity"]
        or _identity(paths["link"]) != paths["link_identity"]
        or _identity(paths["canonical"]) != paths["canonical_identity"]
        or os.readlink(paths["link"]) != str(paths["canonical"])):
        raise SandboxError("Codex remote protected identity changed")
    descriptor = os.open(paths["canonical"], os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(descriptor)
        os.read(descriptor, 1)
    finally:
        os.close(descriptor)
    if ((metadata.st_dev, metadata.st_ino, stat.S_IFMT(metadata.st_mode))
        != paths["canonical_identity"]):
        raise SandboxError("Codex remote credential read identity changed")
    mutations = _probe_mutations(sentinels)
    _drop_capabilities(last_cap)
    capabilities = _security_status(last_cap)
    return {"ok": True, "mutations": mutations, "capabilities": capabilities,
            "proc": "private"}


def command(store: Path, runtime: Path, client_state: Path, sentinels: list[dict],
            proof_fd: int, gate_fd: int, argv: list[str]) -> list[str]:
    return [sys.executable, "-m", "ihar.codex.remote_sandbox",
            str(store), str(runtime), str(client_state), json.dumps(sentinels),
            str(proof_fd), str(gate_fd), "--", *argv]


def run(store: Path, runtime: Path, client_state: Path, sentinels: list[dict],
        proof_fd: int, gate_fd: int, argv: list[str]) -> int:
    if not argv or not os.path.isabs(argv[0]):
        return 3
    try:
        proof = prepare(store, runtime, client_state, sentinels)
    except (OSError, ValueError, KeyError, TypeError, SandboxError) as error:
        proof = {"ok": False, "error": str(error)[:300]}
    try:
        payload = json.dumps(proof, separators=(",", ":")).encode("ascii")
        if len(payload) > _MAX_PROOF:
            return 3
        os.write(proof_fd, payload)
    finally:
        os.close(proof_fd)
    if not proof["ok"]:
        return 3
    try:
        ready = os.read(gate_fd, 1)
    finally:
        os.close(gate_fd)
    if ready != b"1":
        return 3
    environment = dict(os.environ, CODEX_HOME=str(Path(runtime).resolve()),
                       IHAR_REMOTE_CLIENT_STATE=str(Path(client_state).resolve()))
    environment.pop("IHAR_GUARD_FD", None)
    environment.pop("IHAR_CODEX_GUARD_FD", None)
    os.execvpe(argv[0], argv, environment)
    return 3


def _main(arguments: list[str]) -> int:
    if len(arguments) < 8 or arguments[6] != "--":
        return 3
    sentinels = json.loads(arguments[3])
    if not isinstance(sentinels, list):
        return 3
    return run(Path(arguments[0]), Path(arguments[1]), Path(arguments[2]), sentinels,
               int(arguments[4]), int(arguments[5]), arguments[7:])


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
