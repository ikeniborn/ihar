# Final Fix Report: Existing Runtime State Upgrade

## Status

Implemented automatic staged migration for persistent vendor state materialized in pre-manifest runtime homes. Migration runs under the existing required project-state lock, fails closed before source replacement, and retains recovery copies after successful publication.

## RED evidence

- `PYTHONPATH=lib/python python3 tests/test_jsonio.py` — exit 1 because overlapping state-manifest paths were accepted, leaving migration ownership ambiguous.
- `PYTHONPATH=lib/python python3 tests/test_runtime_state_upgrade.py` — exit 1 because the runtime upgrade helper did not exist.
- The added publication-rollback test exited 1 because a failed publish followed by a failed canonical restore deleted the private stage instead of reporting retained recovery evidence.
- A multi-entry relink rollback exited 1 because restored nested files left transaction-created empty recovery parents; cleanup now removes that tree only after every original is restored.
- `bash tests/test_profiles.sh` — exit 1, `PASS=57 FAIL=1`, because the old fixed eight-input hash selected the pre-manifest runtime path.
- The first state integration run exposed inherited `IHAR_RUNTIME` as a false active-writer signal. The helper process and its invoking shell were the observed owners; excluding only current ancestry retained independent writer detection.

## GREEN evidence

Focused evidence on the final executable state:

- Targeted Python compile and changed Bash syntax checks — exit 0.
- `PYTHONPATH=lib/python python3 tests/test_jsonio.py` — exit 0, `PASS=29 FAIL=0`.
- `PYTHONPATH=lib/python python3 tests/test_runtime_state_upgrade.py` — exit 0, `PASS=7 FAIL=0`.
- `bash tests/test_contracts.sh` — exit 0, `PASS=84 FAIL=0`.
- `PYTHONPATH=lib/python python3 tests/test_sessions_readers.py` — exit 0.
- `bash tests/test_config.sh` — exit 0, `PASS=20 FAIL=0`.
- `bash tests/test_profiles.sh` — exit 0, `PASS=58 FAIL=0`.
- `bash tests/test_concurrency.sh` — exit 0, `PASS=33 FAIL=0`.
- `bash tests/test_state.sh` — exit 0, `PASS=317 FAIL=0`.
- `git diff --check` — exit 0.
- Full suite intentionally not run per final-fix scope.

## Behavior delivered

- `state.json` receives a stable digest only after schema validation. That identity joins the eight existing configuration inputs, so a manifest change selects a new runtime generation.
- State-manifest paths may not overlap within one vendor. Each materialized runtime pathname therefore has one declared migration owner.
- Runtime creation and reuse scan prior generations for one unambiguous materialized owner. Wrong links, multiple owners, active independent owners, special entries, canonical conflicts, invalid manifests, source mutation, publication failure, or relink failure abort with exit 3 through the runtime wrapper.
- The helper copies selected entries to a mode-0700 private stage below `st/`, compares source-before, source-after, and staged fingerprints, then swaps the complete vendor state root under the already-held required state lock.
- Runtime originals move into `recovery/runtime-state/<vendor>/<generation>-*` before canonical links replace them. Successful migration keeps those recovery bytes and the prior canonical root. Failed relinking restores runtime entries and canonical state; an incomplete rollback keeps and names its recovery stage.
- Repeated materialization sees canonical links and creates no additional recovery transaction.

## Changed paths

- `lib/python/ihar/inventory.py`
- `lib/python/ihar/jsonio.py`
- `lib/python/ihar/runtime_state_upgrade.py`
- `lib/state/runtime.sh`
- `manifests/tests.json`
- `tests/test_jsonio.py`
- `tests/test_profiles.sh`
- `tests/test_runtime_state_upgrade.py`
- `tests/test_state.sh`
- `.superpowers/sdd/2026-09-20-lld-conformance-remediation/final-fix-runtime-upgrade-report.md`

## Self-review and blockers

- Runtime upgrade mutates only entries selected from the validated state manifest; mutable auth/plugin and tracked store-link inventories stay separate.
- Original materialized bytes remain available after success and after every tested failure path.
- User-owned `.iwiki.toml` remains untouched and unstaged.
- LLD and parent iwiki ledger remain unchanged for parent reconciliation.
- No blockers remain.
