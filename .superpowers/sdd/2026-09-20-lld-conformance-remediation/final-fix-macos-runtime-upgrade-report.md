# Final review fix report — macOS runtime-upgrade compatibility

## Outcome

- Added Darwin atomic directory exchange through
  `renameatx_np(..., RENAME_SWAP)` while retaining Linux
  `renameat2(..., RENAME_EXCHANGE)`.
- Added platform selection that rejects unsupported systems before publication.
- Added macOS same-UID process observation through `/bin/ps` and
  `/usr/sbin/lsof`. Runtime selectors, cwd, and open files below owner,
  sibling, or canonical roots block migration.
- Preserved candidate-aware fail-closed behavior: opaque current-vendor, ACP,
  and ihar processes block; unrelated daemons and other-vendor processes do
  not block without direct runtime evidence.
- Added an atomic-exchange availability preflight before staging.

## TDD evidence

- RED: `PYTHONPATH=lib/python python3 tests/test_runtime_state_upgrade.py`
  exited 1 at `test_macos_atomic_exchange_uses_renameatx_np_swap` because the
  implementation looked only for Linux `renameat2`.
- GREEN: `PYTHONPATH=lib/python python3 tests/test_runtime_state_upgrade.py`
  exited 0 with `PASS=40 FAIL=0` after the implementation.

## Verification

- `python3 -m py_compile lib/python/ihar/runtime_state_upgrade.py tests/test_runtime_state_upgrade.py`
- `PYTHONPATH=lib/python python3 tests/test_runtime_state_upgrade.py`
- `git diff --check`

No full-suite run was performed, as required by the final-fix scope. The
Darwin behavior is platform-faked in unit tests; no macOS host was available
for a live syscall/process-observation integration run.

## Blockers

None for the requested implementation. Live macOS integration remains outside
this bounded Linux-host execution.
