"""The one masking implementation (LLD 8.4).

The gateway and the handoff builder both import this, so the claim that no unmasked
supported content leaves the machine rests on a single body of code rather than on
two that have to agree.

Failure class: the caller's. This module masks or reports that it cannot; refusing a
request is the gateway's decision.

The two layers run in order, and both always run at `standard`. Measured on 2026-09-22:
Presidio alone mangles an address, because its URL recognizer matches fragments of one
and replacing by offsets then leaves the rest visible — `X-urlith@X-urlvalid` in English
and `X-urlrov@X-urlvalid` in Russian. The tuned patterns match a whole address, so they
run first and Presidio adds names, places and organisations on top of already-masked
text. Using Presidio instead of the patterns would have been a regression on email.

Language is chosen by the script the text is written in, not by a configured hint: a
Russian name in a session labelled English must not survive because a setting said so.
Cyrillic gets the Russian pass, Latin the English one, and a text carrying both gets
both. `describe()` names the engine and the languages, and `ihar check` prints it,
because "standard" masking backed by patterns alone is a weaker promise than the same
word backed by named-entity recognition.
"""

from __future__ import annotations

import os
import re
import unicodedata

from ._shared import SECRET_PATTERNS

LEVELS = ("off", "secrets", "standard")


class MaskingUnavailable(RuntimeError):
    """The selected engine could not analyse this input.

    Raised rather than quietly falling back to the regex patterns. Measured on
    2026-09-22: spaCy refuses input over 1,000,000 characters with `ValueError [E088]`,
    and the fallback that used to catch it left the caller recording `masked: true` at
    level `standard` while `ihar check` still reported `engine: presidio` — a weaker
    promise than the label, invisible to everyone. A caller that can degrade does so
    knowingly; the gateway refuses the request instead.
    """


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
                self._engine = "presidio(" + ",".join(
                    code for code, _ in LANGUAGE_MODELS) + ")+regex"

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
        # The patterns always run: they match a whole address, which the named-entity
        # engine does not (see the module docstring).
        text, found = _apply(text, _PII_PATTERNS, self.token)
        kinds.extend(found)
        if self._analyzer is not None:
            for language in languages_for(text):
                text, named = _presidio_mask(self._analyzer, text, self.token, language)
                kinds.extend(named)
        return text, kinds


def languages_for(text: str) -> tuple[str, ...]:
    """The languages worth analysing this text in, from the scripts it uses."""
    cyrillic = latin = False
    for character in text:
        if not character.isalpha():
            continue
        try:
            name = unicodedata.name(character)
        except ValueError:
            continue
        cyrillic = cyrillic or name.startswith("CYRILLIC")
        latin = latin or name.startswith("LATIN")
        if cyrillic and latin:
            break
    languages = []
    if cyrillic:
        languages.append("ru")
    if latin:
        languages.append("en")
    return tuple(languages) or ("en",)


def _apply(text: str, patterns, token: str) -> tuple[str, list[str]]:
    kinds: list[str] = []
    for kind, pattern in patterns:
        text, count = pattern.subn(f"{token}-{kind}", text)
        if count:
            kinds.append(kind)
    return text, kinds


LANGUAGE_MODELS = (("en", "en_core_web_sm"), ("ru", "ru_core_news_sm"))


def _load_presidio():
    """Build the two-language analyzer, or report that there is none.

    Both models are pinned by `lib/python/requirements.lock`. A build that cannot load
    them falls back to the patterns rather than to one language: an analyzer that
    silently knew only English would mask a Russian transcript worse while every report
    still said the same word.
    """
    if os.environ.get("IHAR_GATEWAY_ENGINE") == "regex":
        return None
    try:
        from presidio_analyzer import AnalyzerEngine              # type: ignore
        from presidio_analyzer.nlp_engine import NlpEngineProvider  # type: ignore
    except Exception:                                      # noqa: BLE001
        return None
    try:
        provider = NlpEngineProvider(nlp_configuration={
            "nlp_engine_name": "spacy",
            "models": [{"lang_code": code, "model_name": name}
                       for code, name in LANGUAGE_MODELS],
        })
        return AnalyzerEngine(nlp_engine=provider.create_engine(),
                              supported_languages=[code for code, _ in LANGUAGE_MODELS])
    except Exception:                                      # noqa: BLE001
        # Installed but unusable, typically a missing language model. Falling back is
        # right; pretending it worked is not, which is why describe() reports the
        # engine that actually ran.
        return None


def _presidio_mask(analyzer, text: str, token: str, language: str = "en") -> tuple[str, list[str]]:
    try:
        results = analyzer.analyze(text=text, language=language)
    except Exception as error:                             # noqa: BLE001
        raise MaskingUnavailable(
            f"the presidio engine could not analyse {len(text)} characters "
            f"as {language}: {error}"
        ) from error
    kinds: list[str] = []
    # Replace from the end so earlier offsets stay valid.
    for result in sorted(results, key=lambda item: item.start, reverse=True):
        kind = str(result.entity_type).lower()
        kinds.append(kind)
        text = text[:result.start] + f"{token}-{kind}" + text[result.end:]
    return text, kinds
