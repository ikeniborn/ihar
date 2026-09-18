#!/usr/bin/env python3
"""UUIDv7 generation (LLD 10.1)."""

import os
import sys
import time
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "python"))

from ihar.ids import uuid7  # noqa: E402


def test_version_and_variant_are_rfc_9562():
    value = uuid7()
    assert value.version == 7, value.version
    assert (value.int >> 62) & 0b11 == 0b10, "variant bits are not 10"


def test_ids_are_time_ordered_across_milliseconds():
    """Ordering is by the 48-bit timestamp, so it holds between milliseconds, not
    within one: ids minted in the same millisecond differ only in their random tail
    and may sort either way."""
    ids = []
    for _ in range(5):
        ids.append(str(uuid7()))
        time.sleep(0.002)
    assert ids == sorted(ids), "ids do not sort by creation"


def test_ids_are_unique_within_one_millisecond():
    ids = {str(uuid7()) for _ in range(5000)}
    assert len(ids) == 5000, f"only {len(ids)} distinct ids"


def test_rand_a_and_rand_b_are_independent():
    """Regression: rand_a was taken from bits 12 to 23 while rand_b took bits 0 to 61,
    so twelve bits appeared in both fields. An id then carried 62 bits of entropy
    rather than 74, and two minted in the same millisecond collided 4096 times more
    often than the format allows.

    With overlapping slices, rand_a is a deterministic function of rand_b, so the
    twelve bits agree in every sample. Independent slices disagree almost always.
    """
    agreements = 0
    samples = 400
    for _ in range(samples):
        value = uuid7().int
        rand_a = (value >> 64) & ((1 << 12) - 1)
        rand_b = value & ((1 << 62) - 1)
        if rand_a == ((rand_b >> 12) & ((1 << 12) - 1)):
            agreements += 1
    assert agreements < samples // 10, (
        f"rand_a matched a slice of rand_b in {agreements}/{samples} ids; the fields overlap"
    )


def test_the_timestamp_is_the_leading_field():
    before = uuid7().int >> 80
    after = uuid7().int >> 80
    assert after >= before
    # And it is a plausible Unix millisecond count, not an arbitrary number.
    assert 1_600_000_000_000 < after < 4_000_000_000_000, after


def test_the_value_round_trips_as_a_uuid():
    value = uuid7()
    assert uuid.UUID(str(value)) == value


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
    print(f"PASS={len(tests)} FAIL=0")
