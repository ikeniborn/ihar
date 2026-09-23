#!/usr/bin/env python3
"""The masking engine's two layers and two languages (LLD 8.4, plan task X2.4).

The named-entity half is exercised with a stub analyzer so the suite runs on a machine
that has not installed the dependency, and once more against the real engine when it is
present — skipped cleanly when it is not, like every other test of a real component.
"""

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib" / "python"))

from ihar.mask import engine  # noqa: E402

PASS = FAIL = SKIP = 0


def check(label, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
    else:
        FAIL += 1
        print(f"FAIL {label}")


class Span:
    def __init__(self, start, end, kind):
        self.start, self.end, self.entity_type = start, end, kind


class Stub:
    """An analyzer that reports what the test tells it to, per language."""

    def __init__(self, spans=None, raises=None):
        self.spans = spans or {}
        self.raises = raises
        self.seen = []

    def analyze(self, text, language):
        self.seen.append(language)
        if self.raises:
            raise self.raises
        return self.spans.get(language, [])


def masker_with(analyzer, level="standard"):
    instrument = engine.Masker(level)
    instrument._analyzer = analyzer
    instrument._engine = "presidio(en,ru)+regex"
    return instrument


def main():
    global PASS, FAIL, SKIP

    # Language comes from the script, not from a setting that can be wrong.
    check("cyrillic asks for russian", engine.languages_for("Иван Петров") == ("ru",))
    check("latin asks for english", engine.languages_for("John Smith") == ("en",))
    check("mixed text asks for both", engine.languages_for("Иван and John") == ("ru", "en"))
    check("text with no letters still analyses once",
          engine.languages_for("10.0.0.1 — 42") == ("en",))

    # The patterns always run, which is why an address survives as a whole match.
    silent = Stub()
    masked, kinds = masker_with(silent).mask("write to dev@example.invalid from 10.0.0.1")
    check("an address is masked whole", "REDACTED-email" in masked)
    check("no fragment of the address survives", "@example" not in masked)
    check("an address in a latin text asks english only", silent.seen == ["en"])
    check("the kinds name what was found", {"email", "ipv4"} <= set(kinds))

    # Named entities are added on top of the already-masked text.
    text = "Иван Петров писал вчера"
    named = Stub(spans={"ru": [Span(0, 11, "PERSON")]})
    masked, kinds = masker_with(named).mask(text)
    check("a russian name is masked by the named-entity layer",
          masked.startswith("REDACTED-person"))
    check("a russian text asks russian", named.seen == ["ru"])
    check("the named kind is reported", "person" in kinds)

    both = Stub(spans={"ru": [], "en": []})
    masker_with(both).mask("Иван wrote to John")
    check("mixed text runs both passes in order", both.seen == ["ru", "en"])

    # A failed analysis is a refusal, not a quieter mask (the S14 defect).
    exploding = Stub(raises=ValueError("[E088] Text of length 1000001 exceeds maximum"))
    try:
        masker_with(exploding).mask("anything")
    except engine.MaskingUnavailable as reason:
        check("a failed analysis raises", "E088" in str(reason))
        check("the refusal names the language it failed on", " as en" in str(reason))
    else:
        check("a failed analysis raises", False)
        check("the refusal names the language it failed on", False)

    # `secrets` never reaches the named-entity layer; `off` masks nothing.
    counting = Stub()
    secrets = masker_with(counting, level="secrets")
    masked, _ = secrets.mask("key sk-ant-abcdefghijklmnopqrstuvwxyz0123 from dev@example.invalid")
    check("the secrets level catches the credential", "REDACTED-anthropic" in masked
          or "REDACTED" in masked)
    check("the secrets level leaves the address alone", "dev@example.invalid" in masked)
    check("the secrets level never calls the analyzer", counting.seen == [])

    # The engine is named honestly, including the languages it can actually read.
    forced = dict(os.environ)
    os.environ["IHAR_GATEWAY_ENGINE"] = "regex"
    try:
        check("the regex engine can be forced and says so",
              engine.Masker("standard").describe()["engine"] == "regex")
    finally:
        os.environ.clear()
        os.environ.update(forced)

    # And once against the real dependency, when this machine has it.
    if engine._load_presidio() is None:
        SKIP += 1
        print("SKIP the real engine is not installed here")
    else:
        real = engine.Masker("standard")
        described = real.describe()["engine"]
        check(f"the real engine names both languages ({described})",
              "en" in described and "ru" in described and described.startswith("presidio"))
        masked, kinds = real.mask("Иван Петров, ivan@example.invalid")
        check("a russian name is masked by the real engine", "Иван" not in masked)
        check("the address stays whole under the real engine", "@example" not in masked)
        masked, _ = real.mask("John Smith, john@example.invalid")
        check("an english name is masked by the real engine", "Smith" not in masked)

    print(f"PASS={PASS} FAIL={FAIL} SKIP={SKIP}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
