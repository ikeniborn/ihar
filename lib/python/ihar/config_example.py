"""Emit the commented example configuration (LLD 2.6).

Generated from the key table rather than hand-written, so a key added to the parser
and forgotten here is impossible: the example and the accepted set are the same list.

Usage: python3 -m ihar.config_example
"""

from __future__ import annotations

import sys

# (key, default, accepted, why it exists)
KEYS = [
    ("IHAR_PROFILE", "standard", "standard | protected | isolated",
     "Which guarantees this project runs under. `ihar check` prints the text of each."),
    ("IHAR_DEFAULT_AGENT", "claude", "claude | codex",
     "Which agent a bare `ihar` launches."),
    ("IHAR_GATEWAY_MASKING_LEVEL", "the profile's floor", "off | secrets | standard",
     "May tighten the profile's floor, never loosen it. Any level above `off` needs a\n"
     "# gateway, so it is refused under a profile that has none."),
    ("IHAR_GATEWAY_ENGINE", "presidio", "presidio | regex",
     "`presidio` falls back to regexes when it is not installed, and `ihar check`\n"
     "# reports which one actually ran."),
    ("IHAR_STORE", "${XDG_DATA_HOME:-~/.local/share}/ihar", "an absolute path",
     "Binaries, hooks and credentials. Must stay outside any directory an\n"
     "# agent can write, which is why it is not in the checkout."),
    ("IHAR_STATE_ROOT", "${XDG_STATE_HOME:-~/.local/state}/ihar", "an absolute path",
     "Project state and runtime homes. Kept short because a Codex daemon socket\n"
     "# lives under it and the platform caps that path near 108 bytes."),
    ("IHAR_SOCKET_PATH_MAX", "107", "an integer",
     "The socket budget the state preflight checks against."),
    ("IHAR_TELEMETRY", "off", "off | otel | langfuse | both", "Telemetry export."),
    ("IHAR_DISTILLER", "fork", "fork | local | off",
     "How a handoff summary is produced. `fork` asks the source agent on a fork of\n"
     "# its own session, so the transcript is never mutated."),
    ("IHAR_CHAT_LANG", "unset", "a language name", "Conversation language for the agents."),
    ("IHAR_DOC_LANG", "unset", "a language name", "Documentation language for the agents."),
    ("IHAR_PROXY_URL", "unset", "a URL", "Corporate egress proxy, used by installs only."),
    ("IHAR_PROXY_CA", "unset", "a path", "CA bundle for that proxy."),
    ("IHAR_PROXY_INSECURE", "unset", "1 to skip verification",
     "Only for a proxy whose certificate cannot be verified any other way."),
    ("IHAR_IWIKI_REMOTE_URL", "unset", "a URL",
     "Any IHAR_IWIKI_* key is accepted and forwarded to the iwiki MCP server."),
]

HEADER = """\
# ihar project configuration — copy to .ihar_config and edit.
#
# Parsed, never sourced: only KEY=value lines with an IHAR_* name are accepted, and
# an unknown key is an error rather than something quietly ignored. A value is data,
# so a command substitution written here is stored as text, not executed.
#
# Precedence is defaults < this file < command-line flags, with one exception: the
# profile's masking level is a floor that neither this file nor a flag may lower.
#
# Every line below is commented out and shows the default.
"""


def render() -> str:
    lines = [HEADER]
    for key, default, accepted, why in KEYS:
        lines.append(f"# {why}")
        lines.append(f"# accepted: {accepted}")
        lines.append(f"# {key}={default}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main(argv: list[str]) -> int:
    sys.stdout.write(render())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
