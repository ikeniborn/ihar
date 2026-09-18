"""Path and secret patterns, the union of what both wrappers block today (LLD 6.3).

Stdlib only; imported by the security hook under `python3 -I`.

The lists are the union of iclaude's `.claude-isolated/hooks/block-secrets.py` and
icodex's `.codex-isolated/hooks/block-secrets.py`, so the unified hook blocks
everything either wrapper blocked. Shrinking this set is a behaviour change and
belongs in the LLD, not in a quiet edit here.
"""

from __future__ import annotations

import re

# A path whose contents are a credential by construction.
SENSITIVE_PATH_PATTERNS = (
    r"(^|/)\.env(\.|$)",
    r"(^|/)\.envrc\.local$",
    r"\.pem$", r"\.key$", r"\.pfx$", r"\.p12$", r"\.jks$", r"\.keystore$",
    r"(^|/)id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$",
    r"(^|/)\.ssh/", r"(^|/)\.aws/", r"(^|/)\.gnupg/", r"(^|/)\.kube/",
    r"(^|/)\.docker/config\.json$",
    r"(^|/)\.netrc$", r"(^|/)\.pgpass$",
    r"(^|/)credentials(\.json)?$",
    r"(^|/)service[-_]account.*\.json$",
    r"private[-_]key",
    r"(^|/)auth\.json$",
    r"(^|/)\.credentials\.json$",
)

# A filename that carries a token regardless of where it lives.
TOKEN_FILENAME_PATTERNS = (
    r"secret", r"token", r"password", r"passwd", r"apikey", r"api[-_]key",
)

# Suffixes that mark a file as a template rather than the real thing. Without these
# every repository's `.env.example` would be unreadable, which teaches people to
# turn the hook off.
SAFE_SUFFIXES = (
    ".example", ".sample", ".template", ".dist", ".defaults", ".placeholder", ".md",
)

# Directories whose contents are hooks and policy, never user data. Reading them is
# fine; writing is refused by the store rule in the security hook itself.
HOOK_DIRECTORIES = ("/hooks/", "/.claude/hooks/", "/.codex/hooks/", "/.agents/hooks/")

_KINDS = (
    ("anthropic-key", r"sk-ant-[A-Za-z0-9_\-]{20,}"),
    ("openai-key", r"sk-(?:proj-)?[A-Za-z0-9_\-]{32,}"),
    ("github-token", r"gh[pousr]_[A-Za-z0-9]{20,}"),
    ("gitlab-token", r"glpat-[A-Za-z0-9_\-]{20,}"),
    ("slack-token", r"xox[baprs]-[A-Za-z0-9\-]{10,}"),
    ("google-key", r"AIza[0-9A-Za-z_\-]{35}"),
    ("stripe-key", r"[rs]k_(?:live|test)_[A-Za-z0-9]{20,}"),
    ("huggingface-token", r"hf_[A-Za-z0-9]{30,}"),
    ("groq-key", r"gsk_[A-Za-z0-9]{40,}"),
    ("aws-access-key", r"A(?:KIA|SIA|ROA|IDA)[0-9A-Z]{16}"),
    ("aws-secret", r"(?i)aws_secret_access_key\s*[=:]\s*['\"]?([A-Za-z0-9/+=]{40})"),
    ("private-key-block", r"-----BEGIN (?:RSA |EC |OPENSSH |PGP |DSA )?PRIVATE KEY-----"),
    ("jwt", r"eyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"),
    ("url-credentials", r"[a-z][a-z0-9+.\-]*://[^/\s:@]+:[^/\s:@]+@"),
    ("assignment", r"(?i)\b(?:password|passwd|secret|api[-_]?key|access[-_]?token|"
                   r"auth[-_]?token|bearer)\b\s*[=:]\s*['\"]([^'\"\s]{8,})['\"]"),
)

SECRET_PATTERNS = tuple((kind, re.compile(pattern)) for kind, pattern in _KINDS)

_SENSITIVE = tuple(re.compile(pattern) for pattern in SENSITIVE_PATH_PATTERNS)
_TOKEN_NAME = tuple(re.compile(pattern, re.IGNORECASE) for pattern in TOKEN_FILENAME_PATTERNS)


def is_sensitive_path(path: str) -> str | None:
    """The reason a path is refused, or None."""
    lowered = path.lower()
    if lowered.endswith(SAFE_SUFFIXES):
        return None
    if any(marker in lowered for marker in HOOK_DIRECTORIES):
        return None
    for pattern in _SENSITIVE:
        if pattern.search(lowered):
            return f"{path} is a credential path ({pattern.pattern})"
    name = lowered.rsplit("/", 1)[-1]
    for pattern in _TOKEN_NAME:
        if pattern.search(name):
            return f"{path} names a token ({pattern.pattern})"
    return None


def redact(text: str, token: str = "REDACTED") -> tuple[str, list[str]]:
    """Replace every secret with a labelled placeholder. Returns the text and the
    kinds found, so a caller can report what it masked without printing the value."""
    found: list[str] = []
    for kind, pattern in SECRET_PATTERNS:
        text, count = pattern.subn(f"{token}-{kind}", text)
        if count:
            found.append(kind)
    return text, found
