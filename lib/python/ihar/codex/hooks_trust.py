"""Make ihar's own Codex hooks trusted, and verify that they are (LLD 6.4, 6.5).

Measured against Codex 0.154.0 rather than assumed, because the mechanism the LLD
first chose does not work:

    hooks.managed_dir in a project config.toml   hooks/list returns no entries
    hooks.managed_dir as a -c override           no entries
    $CODEX_HOME/hooks.json                       listed, trustStatus "untrusted"
    [hooks.state."<key>"] trusted_hash = <hash>  listed, trustStatus "trusted"
    the same with a wrong or unprefixed hash     listed, trustStatus "modified"
    bypass_hook_trust = true                     still "untrusted"

Two consequences. The managed directory is unavailable to a harness that cannot
write a machine-managed configuration, so the fallback LLD 6.4 already named is the
implementation. And `bypass_hook_trust` does not confer trust at all, so the key the
architecture review objected to was never the mechanism for this in the first place;
ihar writes it nowhere.

The key a hook is trusted under embeds the absolute path of the rendered hooks.json
and the digest is computed by the vendor, so neither can be predicted. They are
learned by asking the vendor about the staged runtime home before it is published,
which is why materialisation seals the home in two phases.

Failure class: fail-closed for a profile whose hooks are enforced.

Usage:
    python3 -m ihar.codex.hooks_trust --seal <binary> <staged-home> <cwd>
    python3 -m ihar.codex.hooks_trust --verify <binary> <home> <cwd> <required-script>...
"""

from __future__ import annotations

import json
import os
import sys

from .appserver import AppServerError, hooks_list

TRUSTED_SOURCES = ("system", "user", "mdm")
TRUSTED_STATES = ("managed", "trusted")


def _ours(hook: dict, home: str) -> bool:
    """A hook ihar rendered, as opposed to one the project or a plugin contributed."""
    path = hook.get("sourcePath") or ""
    return os.path.abspath(path) == os.path.abspath(os.path.join(home, "hooks.json"))


def _toml_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def seal_quiet(binary: str, home: str, cwd: str) -> tuple[int, str]:
    """seal(), returning its message instead of printing it.

    The printing is the CLI's job: these functions are also called in-process by the
    conformance suite, where stray stdout would corrupt a report.
    """
    import contextlib
    import io
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        code = seal(binary, home, cwd)
    return code, buffer.getvalue().strip()


def verify_quiet(binary: str, home: str, cwd: str, required: list[str]) -> tuple[int, str]:
    """verify(), returning its findings instead of printing them."""
    import contextlib
    import io
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        code = verify(binary, home, cwd, required)
    return code, buffer.getvalue().strip()


def seal(binary: str, home: str, cwd: str) -> int:
    """Record every ihar hook's current digest as trusted, in this home's config.toml.

    Only hooks whose sourcePath is this home's rendered hooks.json are trusted. A
    project or plugin hook keeps the vendor's ordinary trust flow: extending trust to
    those is exactly what made `bypass_hook_trust` unacceptable.
    """
    try:
        hooks = hooks_list(binary, home, [cwd])
    except (AppServerError, OSError) as error:
        print(f"ihar: cannot ask Codex about its hooks: {error}", file=sys.stderr)
        return 3

    lines = []
    for hook in sorted(hooks, key=lambda item: item.get("key", "")):
        if not _ours(hook, home):
            continue
        key, digest = hook.get("key"), hook.get("currentHash")
        if not key or not digest:
            print(f"ihar: a rendered hook has no key or digest: {json.dumps(hook)[:200]}",
                  file=sys.stderr)
            return 3
        lines.append(f'[hooks.state."{_toml_escape(key)}"]')
        lines.append(f'trusted_hash = "{_toml_escape(digest)}"')
        lines.append("")

    if not lines:
        print("ihar: Codex reported none of the rendered hooks; nothing to trust",
              file=sys.stderr)
        return 3

    config = os.path.join(home, "config.toml")
    with open(config, "a", encoding="utf-8") as handle:
        handle.write("\n# ihar:hook-trust:start\n")
        handle.write("# Written from the digests Codex itself reported for the hooks\n")
        handle.write("# ihar rendered into this home. Editing a hook invalidates these.\n")
        handle.write("\n".join(lines))
        handle.write("# ihar:hook-trust:end\n")
    print(len(lines) // 3)
    return 0


def verify(binary: str, home: str, cwd: str, required: list[str]) -> int:
    """Refuse a launch whose required hooks are not trusted.

    Prints one line per required hook that is not in order, and nothing when every
    one of them is trusted, enabled and sourced from a location ihar controls.
    """
    try:
        hooks = hooks_list(binary, home, [cwd])
    except (AppServerError, OSError) as error:
        print(f"cannot verify hook trust: {error}")
        return 3

    ours = {hook.get("key", ""): hook for hook in hooks if _ours(hook, home)}
    problems = []

    for script in required:
        matching = [hook for hook in ours.values() if script in (hook.get("key") or "")]
        # The key is "<path>:<event>:<index>:<index>", so it names the file rather
        # than the script. Fall back to "any of ours" when the manifest rendered one
        # file, which is the only shape this renderer produces.
        if not matching:
            matching = list(ours.values())
        if not matching:
            problems.append(f"{script}: Codex does not see it")
            continue
        for hook in matching:
            state = hook.get("trustStatus")
            if state not in TRUSTED_STATES:
                problems.append(f"{hook.get('key')}: trustStatus is {state!r}")
            if not hook.get("enabled", False):
                problems.append(f"{hook.get('key')}: it is disabled")
            if hook.get("source") not in TRUSTED_SOURCES:
                problems.append(f"{hook.get('key')}: source is {hook.get('source')!r}")

    for problem in sorted(set(problems)):
        print(problem)
    return 1 if problems else 0


def main(argv: list[str]) -> int:
    if len(argv) >= 4 and argv[0] == "--seal":
        return seal(argv[1], argv[2], argv[3])
    if len(argv) >= 4 and argv[0] == "--verify":
        return verify(argv[1], argv[2], argv[3], argv[4:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
