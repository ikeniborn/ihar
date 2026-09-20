# Task 6 Report: I5/I6

## Status

Implemented receipt-backed native launch verification, deterministic concurrency coverage, and a closed executable test inventory. Reconciled the LLD with the delivered contracts without weakening fail-closed behavior.

## RED evidence

- `bash tests/test_lockfile.sh` — exit 1: nine receipt assertions failed because no shared receipt helper existed and enforced profiles did not abort before launch.
- `bash tests/test_lifecycle.sh` — exit 1: receipt failure did not name install-receipt verification and the fake vendor start marker was created.
- `bash tests/test_contracts.sh` — exit 1: `test-inventory` was an unknown contract and `manifests/tests.json` did not exist.
- `bash tests/test_concurrency.sh` initially exposed an invalid two-publication barrier assumption: the required state lock correctly prevented the second publication from entering. The test was corrected to observe lock attempt, blocked publication, and ordered entry before production behavior was changed.
- Missing receipt plus missing executable initially reported `mismatched`; the helper regression required `missing receipt` to win.
- Missing release lock under `standard` initially returned before receipt verification; the regression required a receipt warning even without release pins.

## GREEN evidence

Focused evidence on the final executable state:

- `bash tests/test_lockfile.sh` — exit 0, `PASS=25 FAIL=0`.
- `bash tests/test_lifecycle.sh` — exit 0, `PASS=22 FAIL=0`.
- `bash tests/test_gateway_explicit.sh` — exit 0, `PASS=20 FAIL=0`.
- `bash tests/test_concurrency.sh` — exit 0, `PASS=30 FAIL=0`.
- `bash tests/test_contracts.sh` — exit 0, `PASS=72 FAIL=0`.
- `PYTHONPATH=lib/python python3 tests/test_jsonio.py` — exit 0, `PASS=24 FAIL=0`.
- Regression files from the authorized fixture reconciliation: `test_acp.sh` `PASS=22 FAIL=0`, `test_adapters.sh` `PASS=47 FAIL=0`, `test_daemon.sh` `PASS=56 FAIL=0`, and `test_web.sh` `PASS=23 FAIL=0`.
- `bash -n ihar.sh lib/**/*.sh tests/test_*.sh` — exit 0.
- `PYTHONPATH=lib/python python3 -m compileall -q lib/python hooks tests` — exit 0.
- `git diff --check` — exit 0.
- Test-inventory schema validation and exact sorted comparison with discovered `tests/test_*.sh` and `tests/test_*.py` paths — exit 0.

## Full-suite evidence

The first full-suite run used implementation fingerprint `ebac9479bee6235abb7427dcda43a4e29006222c77f173d493589f137630bf05` (user-owned `.iwiki.toml` excluded):

- `bash tests/run.sh` — exit 1, `files=27 failed=4`.
- Failures: `test_acp.sh` (`PASS=13 FAIL=9`), `test_adapters.sh` (`PASS=26 FAIL=21`), `test_daemon.sh` (`PASS=53 FAIL=4`), and `test_web.sh` (`PASS=6 FAIL=17`).
- Root causes were stale empty-store fixtures missing current hook/asset prerequisites, diagnostic lines preceding dry-run JSON, and daemon assertions targeting fields intentionally removed by the approved Task 5 closed check-result schema.

After the authorized narrow fixture and assertion repairs, final scoped diff fingerprint was `fa1a24e7bd9e7233d81234dd3e672d4410a67fb7e9007c7bb6a7b1caa554be33`:

- `bash tests/run.sh` — exit 0, `files=27 failed=0`.
- The suite was run once on this stable executable fingerprint. This report is documentation-only and does not invalidate that evidence.

## Behavior delivered

- Native launches compare the selected vendor executable with `$IHAR_STORE/install-receipt.json` before vendor execution. `standard` warns and continues; `protected` and `isolated` exit 3 for mismatched, missing, malformed, or unreadable evidence.
- `ihar_receipt_binary_status <vendor> <binary>` is shared by launch and `ihar check` and emits only `verified`, `mismatched`, or `missing receipt`.
- Dry-run and ACP skip only native-executable receipt comparison because they do not execute the native binary; store and hook integrity checks remain active.
- The concurrency suite uses entry, attempt, release, ready, and done markers to prove runtime publication serialization, distinct immutable homes, store-lock ordering, gateway identity separation, and shared-instance refcount retention.
- `manifests/tests.json` is a closed schema-1 inventory of all 27 discovered tests. `tests/run.sh` validates it before execution and exits 3 for malformed, duplicate, unsafe, missing, listed-but-undiscovered, or unlisted-discovered paths.

## LLD reconciliation

- Advanced `docs/lld/unified-harness.md` to revision 10.
- Documented selected-binary receipt verification, the three-value public status contract, standard versus enforced severity, and non-native dry-run/ACP handling.
- Added the test-inventory data contract and fail-closed runner behavior.
- Reconciled the test-plan table with existing suites and the deterministic Task 6 concurrency cases.
- Updated the failure matrix to name receipt states and enforced exit behavior.

## Changed paths

- `docs/lld/unified-harness.md`
- `lib/cli/check.sh`
- `lib/cli/commands.sh`
- `lib/python/ihar/jsonio.py`
- `lib/store/lockfile.sh`
- `manifests/tests.json`
- `tests/run.sh`
- `tests/test_acp.sh`
- `tests/test_adapters.sh`
- `tests/test_concurrency.sh`
- `tests/test_contracts.sh`
- `tests/test_daemon.sh`
- `tests/test_jsonio.py`
- `tests/test_lifecycle.sh`
- `tests/test_lockfile.sh`
- `tests/test_web.sh`
- `.superpowers/sdd/2026-09-20-lld-conformance-remediation/task-6-report.md`

## Self-review and blockers

- Extra paths beyond the original plan were limited to the recorded shared-helper test fixture and the parent-authorized ACP/adapters/daemon/web fixture reconciliation.
- Daemon diagnosis found stale consumer assertions, not a production structured-check contract gap; production check-result code was not broadened.
- User-owned `.iwiki.toml` remains untouched and unstaged.
- No blockers remain.

## Review round 1 remediation

### RED and mutation evidence

- `bash tests/test_acp.sh` — exit 1, `PASS=22 FAIL=6`: real ACP launches bypassed selected-native-executable receipt verification, so tampered and missing evidence still reached the adapter.
- The first rewritten concurrency fixture failed before its assertion because `IHAR_NVM` was unset while sourcing the production installer. Supplying the real install entry point's required environment corrected the fixture; no production change was made for this setup error.
- With the production state and store lock calls temporarily removed, `bash tests/test_concurrency.sh` — exit 1, `PASS=28 FAIL=3`: the second runtime crossed the post-lock publication marker, the first publication ordering assertion failed, and the second install entered `_ihar_install_all` before release. The exact production lock calls were restored immediately after this mutation check.
- The expanded receipt matrix passed against existing helper behavior and proved the missing coverage rather than requiring a mapping change: both `protected` and `isolated` reject missing, malformed, and permission-unreadable evidence; all malformed/unreadable cases retain the public `missing receipt` state.

### GREEN evidence

- `bash tests/test_acp.sh` — exit 0, `PASS=28 FAIL=0`.
- `bash tests/test_concurrency.sh` — exit 0, `PASS=31 FAIL=0`.
- `bash tests/test_lockfile.sh` — exit 0, `PASS=30 FAIL=0`.
- `bash tests/test_lifecycle.sh` — exit 0, `PASS=22 FAIL=0`.
- `bash tests/test_adapters.sh` — exit 0, `PASS=47 FAIL=0`.
- `bash tests/test_web.sh` — exit 0, `PASS=23 FAIL=0`.
- `bash tests/test_gateway_explicit.sh` — exit 0, `PASS=20 FAIL=0`.
- `bash tests/test_contracts.sh` — exit 0, `PASS=72 FAIL=0`.
- `PYTHONPATH=lib/python python3 tests/test_jsonio.py` — exit 0, `PASS=24 FAIL=0`.
- Changed-shell `bash -n`, Python `compileall`, `git diff --check`, test-inventory schema validation, and exact inventory/discovery comparison — exit 0.

Final review-round executable fingerprint: `138833cb4dec2179a7ae9825868932febde8eade3f1ae142c90dd6ef3bc5ccce`.

- `bash tests/run.sh` — exit 0, `files=27 failed=0`.
- The full suite was run once on this stable review-round executable state.

### Behavior and test corrections

- Only dry-run skips selected-native-executable receipt verification. A real ACP launch verifies the native CLI that its adapter delegates to before adapter execution; adapter version/digest integrity remains the existing separate check with no invented receipt fields.
- ACP regressions use a valid ACP-allowed non-standard fixture profile to prove tampered and missing receipt failures occur before its adapter start marker. Shipped `protected` and `isolated` profiles continue to refuse ACP at the earlier profile gate.
- Install concurrency now calls production `ihar_cmd_install`; only `_ihar_install_all` is replaced with a deterministic barrier inside the real required store lock.
- Runtime concurrency asserts that the second process cannot reach a marker placed inside the actual post-lock publication seam before release. Removing the state lock makes the test fail.
- Shared-gateway retention is now proved by a live protocol probe after the first consumer releases, not by the persistent port file.
- The LLD no longer claims ACP skips native receipt verification and documents the existing separate adapter-integrity boundary.

### Round 1 scope and blockers

- Final paths are limited to `lib/cli/commands.sh`, `lib/store/lockfile.sh`, `tests/test_acp.sh`, `tests/test_concurrency.sh`, `tests/test_lockfile.sh`, `docs/lld/unified-harness.md`, and this report.
- The temporary lock mutations left no diff in `lib/store/install.sh` or `lib/state/runtime.sh`.
- User-owned `.iwiki.toml` remains untouched and unstaged.
- No blockers remain.
