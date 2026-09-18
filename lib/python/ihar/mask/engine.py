"""The one masking implementation (LLD 8.4).

The gateway and the handoff builder both import this, so the claim that no unmasked
supported content leaves the machine rests on a single body of code rather than on
two that have to agree.

Failure class: the caller's. This module masks or reports that it cannot; refusing a
request is the gateway's decision.

Presidio is used when it imports, and a regex engine is the fallback. That is not a
silent degradation: `describe()` reports which engine is active and `ihar check`
prints it, because "standard" masking backed by regexes alone is a weaker promise
than the same word backed by named-entity recognition.
"""

from __future__ import annotations

import os
import re

from ._shared import SECRET_PATTERNS

LEVELS = ("off", "secrets", "standard")

# Personal data the `standard` level masks in addition to credentials. Deliberately
# conservative: a pattern that fires on ordinary prose would make the gateway mangle
# the very requests it is meant to protect, and a user who sees that turns masking
# off, which is worse than a narrower rule.
_PII_PATTERNS = (
    ("email", re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")),
    ("iban", re.compile(r"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b")),
    ("card", re.compile(r"\b(?:\d[ \-]?){13,19}\b")),
    ("ipv4", re.compile(r"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b")),
    ("phone", re.compile(r"(?<![\w.])\+\d[\d\s\-().]{7,}\d(?![\w.])")),
)


class Masker:
    def __init__(self, level: str = "standard", engine: str = "presidio", token: str = "REDACTED"):
        if level not in LEVELS:
            raise ValueError(f"unknown masking level {level!r}")
        self.level = level
        self.token = token
        self._analyzer = None
        self._engine = "regex"
        if level != "off" and engine == "presidio":
            self._analyzer = _load_presidio()
            if self._analyzer is not None:
                self._engine = "presidio"

    def describe(self) -> dict:
        return {"level": self.level, "engine": self._engine}

    def secrets_only(self, text: str) -> tuple[str, list[str]]:
        """Credentials only, leaving everything else untouched.

        Used for values whose shape carries meaning — a path, a command, an
        identifier — where PII masking would break the call while a leaked
        credential still has to be caught (LLD 8.4).
        """
        if self.level == "off":
            return text, []
        return _apply(text, SECRET_PATTERNS, self.token)

    def mask(self, text: str) -> tuple[str, list[str]]:
        """Everything the level covers."""
        if self.level == "off":
            return text, []
        text, kinds = _apply(text, SECRET_PATTERNS, self.token)
        if self.level == "secrets":
            return text, kinds
        if self._analyzer is not None:
            text, found = _presidio_mask(self._analyzer, text, self.token)
            kinds.extend(found)
            return text, kinds
        text, found = _apply(text, _PII_PATTERNS, self.token)
        kinds.extend(found)
        return text, kinds


def _apply(text: str, patterns, token: str) -> tuple[str, list[str]]:
    kinds: list[str] = []
    for kind, pattern in patterns:
        text, count = pattern.subn(f"{token}-{kind}", text)
        if count:
            kinds.append(kind)
    return text, kinds


def _load_presidio():
    if os.environ.get("IHAR_GATEWAY_ENGINE") == "regex":
        return None
    try:
        from presidio_analyzer import AnalyzerEngine       # type: ignore
    except Exception:                                      # noqa: BLE001
        return None
    try:
        return AnalyzerEngine()
    except Exception:                                      # noqa: BLE001
        # Installed but unusable, typically a missing language model. Falling back is
        # right; pretending it worked is not, which is why describe() reports the
        # engine that actually ran.
        return None


def _presidio_mask(analyzer, text: str, token: str) -> tuple[str, list[str]]:
    try:
        results = analyzer.analyze(text=text, language="en")
    except Exception:                                      # noqa: BLE001
        return _apply(text, _PII_PATTERNS, token)
    kinds: list[str] = []
    # Replace from the end so earlier offsets stay valid.
    for result in sorted(results, key=lambda item: item.start, reverse=True):
        kind = str(result.entity_type).lower()
        kinds.append(kind)
        text = text[:result.start] + f"{token}-{kind}" + text[result.end:]
    return text, kinds
