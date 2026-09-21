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

## Review fix round 1

### RED evidence

- `PYTHONPATH=lib/python python3 tests/test_jsonio.py` — exit 1 because an explicit `state.sqlite-wal` entry could alias the WAL expanded from a `state.sqlite` family.
- `PYTHONPATH=lib/python python3 tests/test_runtime_state_upgrade.py` — exit 1 because a process holding canonical state open was ignored. Added failures also reproduced runtime-root, generation, and vendor ancestry symlinks; an active sibling runtime; writes after staging and after publication; and non-atomic publication rollback.

### Remediation

- State, runtime, generation, vendor, manifest-entry, staging, recovery, and relink traversal now uses retained directory descriptors with `O_NOFOLLOW`. Runtime ancestry symlinks fail before mutation and external referents remain byte-identical.
- Quiescence scans every same-vendor runtime and blocks inspectable processes that select any such runtime or hold a canonical/materialized path as cwd or an open descriptor. Missing process evidence fails closed; non-dumpable session services with no inspectable project-runtime evidence are outside the candidate set.
- Staging is re-fingerprinted against source after copy, after the second quiescence gate, immediately after publication, and after relink. Late writes roll back publication while retaining the writer's latest source bytes.
- Publication uses Linux `renameat2(RENAME_EXCHANGE)`, so the canonical vendor directory is never absent. The prior canonical tree stays in the private stage until relink verification commits it into recovery; failed publication exchanges it back atomically.
- State-manifest overlap validation now runs on SQLite-family-expanded paths. Explicit base/WAL/SHM aliases fail schema validation before state-tree inspection or recovery creation.

### GREEN evidence

- `PYTHONPATH=lib/python python3 tests/test_jsonio.py` — exit 0, `PASS=29 FAIL=0`.
- `PYTHONPATH=lib/python python3 tests/test_runtime_state_upgrade.py` — exit 0, `PASS=15 FAIL=0`.
- `bash tests/test_contracts.sh` — exit 0, `PASS=84 FAIL=0`.
- `PYTHONPATH=lib/python python3 tests/test_sessions_readers.py` — exit 0.
- `bash tests/test_config.sh` — exit 0, `PASS=20 FAIL=0`.
- `bash tests/test_profiles.sh` — exit 0, `PASS=58 FAIL=0`.
- `bash tests/test_concurrency.sh` — exit 0, `PASS=33 FAIL=0`.
- `bash tests/test_state.sh` — exit 0, `PASS=317 FAIL=0`.
- Python compile, Bash syntax, and `git diff --check` — exit 0.
- Full suite intentionally not run per review-fix scope.

## Review fix round 2

### RED evidence

- Focused upgrade tests failed when a live same-session process made `/proc/<pid>/environ` unreadable: migration treated the unknown process as irrelevant and published state.
- Live processes selecting owner, sibling, or canonical state through `CODEX_HOME` and `CLAUDE_CONFIG_DIR` were ignored because only `IHAR_RUNTIME` was inspected.
- An injected post-relink failure plus failed atomic rollback reported a recovery path that cleanup deleted.
- Publication lacked direct tests that intercepted the exact `renameat2(..., RENAME_EXCHANGE)` call, rejected missing syscall support without mutation, and continuously observed canonical-directory presence.

### Remediation

- Same-UID, same-session processes with unreadable, empty, or partial environments are unknown consumers and fail closed. The current helper and its invoking ancestry are excluded by exact PID proof; unreadable processes outside that execution session are not candidate descendants.
- Quiescence resolves `IHAR_RUNTIME`, `CODEX_HOME`, and `CLAUDE_CONFIG_DIR` and rejects selectors naming any same-vendor owner, sibling runtime, canonical root, or their descendants. Open-descriptor and cwd checks remain active.
- Rollback restores canonical publication before runtime entries. When the atomic rollback fails, runtime links and original recovery bytes remain coherent; cleanup retains the exact recovery directory named in the error. All incomplete rollback paths now suppress evidence cleanup.
- Tests intercept one libc `renameat2` invocation with the exact `RENAME_EXCHANGE` flag, exercise 500 exchanges under a concurrent canonical-presence observer, and prove missing atomic syscall support leaves canonical and materialized bytes unchanged.

### GREEN evidence

- `PYTHONPATH=lib/python python3 tests/test_jsonio.py` — exit 0, `PASS=29 FAIL=0`.
- `PYTHONPATH=lib/python python3 tests/test_runtime_state_upgrade.py` — exit 0, `PASS=23 FAIL=0`.
- `bash tests/test_contracts.sh` — exit 0, `PASS=84 FAIL=0`.
- `PYTHONPATH=lib/python python3 tests/test_sessions_readers.py` — exit 0.
- `bash tests/test_config.sh` — exit 0, `PASS=20 FAIL=0`.
- `bash tests/test_profiles.sh` — exit 0, `PASS=58 FAIL=0`.
- `bash tests/test_concurrency.sh` — exit 0, `PASS=33 FAIL=0`.
- `bash tests/test_state.sh` — exit 0, `PASS=317 FAIL=0`.
- Python compile, Bash syntax, and `git diff --check` — exit 0.
- Full suite intentionally not run per review-fix scope.

## Review fix round 3

### RED evidence

- A detached `setsid` process with `CODEX_HOME` selecting a sibling runtime, an open materialized-state fd, and unreadable environment was skipped solely because its session differed from the migration helper.
- A detached process with a partial environment and an open runtime fd was skipped before cwd/fd inspection.
- A parent process holding materialized or canonical state open was excluded as helper ancestry while its child successfully invoked the migration.

### Remediation

- Environment failure no longer short-circuits a process scan. Every same-UID process is checked for cwd and every enumerable fd even when its environment is unreadable, empty, or partial. Any protected-path reference blocks immediately; remaining unknown environment/cwd/fd evidence fails closed.
- Session-based relevance filtering was removed. Detached processes receive the same inspection as every other same-UID process.
- Blanket parent and ancestor exclusion was removed. Only the exact current migration PID is excluded; this migration creates no subprocesses, so it owns no additional exclusion lifetime.
- Process identity now comes from the `/proc/<pid>` directory owner before reading process evidence. Exited processes are treated as races; live permission failures remain blocking uncertainty.

### GREEN evidence

- `PYTHONPATH=lib/python python3 tests/test_jsonio.py` — exit 0, `PASS=29 FAIL=0`.
- `PYTHONPATH=lib/python python3 tests/test_runtime_state_upgrade.py` — exit 0, `PASS=26 FAIL=0`.
- `bash tests/test_contracts.sh` — exit 0, `PASS=84 FAIL=0`.
- `PYTHONPATH=lib/python python3 tests/test_sessions_readers.py` — exit 0.
- `bash tests/test_config.sh` — exit 0, `PASS=20 FAIL=0`.
- `bash tests/test_profiles.sh` — exit 0, `PASS=58 FAIL=0`.
- `bash tests/test_concurrency.sh` — exit 0, `PASS=33 FAIL=0`.
- `unshare --map-user=1000 --map-group=1000 -pf --mount-proc bash tests/test_state.sh` — exit 0, `PASS=317 FAIL=0`. PID isolation prevents unrelated opaque host services from becoming intentional fail-closed quiescence blockers while retaining non-root permission behavior.
- Python compile, Bash syntax, and `git diff --check` — exit 0.
- Full suite intentionally not run per review-fix scope.

## Escalation fix: candidate-consumer quiescence

### RED evidence

- `PYTHONPATH=lib/python python3 tests/test_runtime_state_upgrade.py` — exit 1 because an unrelated process with a partial environment was treated as a global quiescence uncertainty.
- The direct live-`/proc` production-session fixture exited 1 because opaque same-UID `systemd`, `(sd-pam)`, and `ssh-agent` processes blocked migration despite having no runtime evidence.
- The sibling-runtime cwd case exited 1 because cwd/fd inspection covered only the materialized owner and canonical root, allowing migration to start while a sibling runtime was active.
- A partial environment containing a readable protected `CODEX_HOME` was initially ignored; the regression exited 1 until readable selectors were evaluated independently of environment completeness.
- Review regressions exited 1 because duplicate selector entries could hide a protected value and because an absolute command-line root containing `=` was parsed as an assignment.
- Mutation check: inserting `continue` after an unreadable environment made `test_unreadable_environment_still_reports_runtime_file_descriptor_consumer` exit 1 with `unreadable environment skipped runtime fd inspection`; removing the mutant restored exit 0.

### Remediation

- Every same-UID process is still checked for readable selectors and cwd/open-fd references under the materialized owner, every sibling runtime, and canonical state. Those direct references block regardless of process identity.
- Opaque or partial process evidence becomes blocking uncertainty only after executable or command-line evidence classifies the process as the current vendor, its ACP adapter, the ihar wrapper, or as referring to a protected root. Unrelated opaque session daemons no longer block.
- Classified candidates retain fail-closed handling for unreadable/partial environments and unavailable cwd/fd inspection. Only the exact migration PID is excluded; detached and ancestor processes receive the same checks.
- Selector inspection considers every duplicate `IHAR_RUNTIME`, `CODEX_HOME`, and `CLAUDE_CONFIG_DIR` entry, including complete entries visible inside an otherwise partial environment.
- Command-line root classification preserves complete absolute and `unix://` paths before considering assignment or option right-hand sides, including roots whose names contain `=`.
- Tests cover Codex, Claude, both ACP executable names, `ihar`/`ihar.sh`, wrong-vendor exclusion, executable and command-line identity, command-line root references, independent cwd/fd uncertainty, and a direct production-session mix of unrelated opaque daemons plus readable and unreadable vendor candidates.

### GREEN evidence

- `python3 -m py_compile lib/python/ihar/runtime_state_upgrade.py tests/test_runtime_state_upgrade.py` — exit 0.
- `PYTHONPATH=lib/python python3 tests/test_runtime_state_upgrade.py` — exit 0, `PASS=34 FAIL=0`.
- `PYTHONPATH=lib/python python3 tests/test_jsonio.py` — exit 0, `PASS=29 FAIL=0`.
- `bash tests/test_contracts.sh` — exit 0, `PASS=84 FAIL=0`.
- `PYTHONPATH=lib/python python3 tests/test_sessions_readers.py` — exit 0.
- `bash tests/test_config.sh` — exit 0, `PASS=20 FAIL=0`.
- `bash tests/test_profiles.sh` — exit 0, `PASS=58 FAIL=0`.
- `bash tests/test_concurrency.sh` — exit 0, `PASS=33 FAIL=0`.
- `bash tests/test_state.sh` — exit 0, `PASS=317 FAIL=0`.
- `git diff --check` — exit 0.
- Independent escalation re-review found no Critical or Important findings. The pre-existing theoretical PID-reuse race during `/proc` traversal remains a non-blocking Minor; this narrow correction does not add process-lifetime pinning.
- Full suite intentionally not run per escalation scope.
