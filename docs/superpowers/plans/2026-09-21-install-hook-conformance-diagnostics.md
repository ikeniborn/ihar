---
review:
  plan_hash: d3cd35b36e9f5bd4
  last_run: 2026-09-21
  phases:
    structure: { status: passed }
    coverage: { status: passed }
    dependencies: { status: passed }
    verifiability: { status: passed }
    consistency: { status: passed }
  findings: []
chain:
  intent: docs/superpowers/intents/2026-09-21-install-hook-conformance-diagnostics-intent.md
  spec: docs/superpowers/specs/2026-09-21-install-hook-conformance-diagnostics-design.md
---

# Install Hook Conformance Diagnostics Implementation Plan

**Status:** approved

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a genuinely fresh installation activate usable components without prior vendor authentication while keeping enforced launches and existing-generation updates fail-closed.

**Architecture:** Keep the staged generation and rollback transaction in `lib/store/install.sh`. Distinguish bootstrap eligibility under its existing lock, tolerate only a complete failed live-case record on bootstrap, and never publish that failed record as proof. Make the Python conformance runner emit only bounded case names/statuses; preserve `ihar check --conformance` failure status through status rendering. The launch proof gate remains fail-closed; the result-review correction below adds a pending-recheck refusal without a bootstrap bypass.

**Tech Stack:** Bash launcher and transaction tests; Python 3 standard library and existing `ihar.jsonio` schema; existing shell/Python test inventory.

**Spec:** `docs/superpowers/specs/2026-09-21-install-hook-conformance-diagnostics-design.md`

## Global Constraints

- Never bypass the enforced-profile launch proof gate or substitute mock/direct hook execution for live conformance.
- Only a clean active store with no receipt path and no installed ihar vendor executable may use bootstrap tolerance.
- A wrong pin, pre-record error, invalid/incomplete record, or non-conformance failure remains fatal during bootstrap.
- Existing-generation install/update requires full passing conformance before activation and retains rollback.
- Mutable vendor auth, plugins, and state remain at stable owners and are never copied to the installer stage.
- Output and persisted records must not contain raw vendor output, model-written values, credential values, or dynamic exception text.
- Do not execute `.ihar_config` as shell; correct its local values to literal absolute paths.
- Work only on `dev-install-hook-conformance-diagnostics`; merge to `master` through a PR.

**Implementation rulings and result-review correction (spec §4, R2 and R5):** The failed-record validator SHALL take the expected vendor explicitly, so another vendor's record cannot authorize bootstrap. The unproven warning SHALL appear only after successful activation; an aborted transaction never claims installed components. Whole-branch review identified two additional requirements: installer diagnostics SHALL forward only the runner's bounded case text to stderr, and an explicit recheck failure SHALL NOT leave an older passing proof eligible. Before an explicit active-store recheck, the CLI SHALL mark that vendor pending, revoke only its managed proof records, and leave the marker on any revocation or live-run failure. The enforced gate SHALL reject a pending marker and only a passing recheck SHALL clear it. This tightens the gate; staged install/update rollback and vendor-owned mutable state remain unchanged. Regression tests SHALL cover a surviving old proof after a malformed sibling entry, recovery after a passing retry, vendor isolation, and bounded installer diagnostics.

---

### Task 1: Secret-safe conformance result boundary

**Closes:** Spec R5 (bounded, secret-safe diagnostics) and R2 (complete failed-case versus pre-record distinction). Each step below contributes to this boundary.

**Files:**
- Modify: `lib/python/ihar/conformance/run.py`
- Modify: `lib/python/ihar/conformance/check.py`
- Test: `tests/test_conformance.py`

**Interfaces:**
- Consumes: existing `run(vendor, binary, store, manifest_path, *, auth_store, lockfile_path, protected_store)` and closed `jsonio` conformance schema.
- Produces: CLI exit 0 for passing complete record, exit 1 for complete failed-case record, exit 3 for pre-record or record-write failure; stdout carries only failed case names/statuses in text mode, and no raw vendor output. The on-disk record still has the existing schema but only fixed, non-sensitive `detail` strings. `ihar.conformance.check --failed-record <vendor> <record> <binary> <manifest>` returns 0 only for a schema-valid, expected-vendor, digest-matched record with at least one failed required case.

- [ ] **Step 1: Add failing tests.** In `tests/test_conformance.py`, invoke `conformance.main(...)` with a stubbed `conformance.run` returning a complete record whose failed case has `detail: "SECRET-SENTINEL"`; capture stdout/stderr and assert the sentinel is absent, the failed case name is present, and exit is 1. Add a pre-record `RuntimeError("SECRET-SENTINEL")` case and assert exit 3 with no sentinel. For record persistence, make a case function return a model-written `SECRET-SENTINEL` detail and assert the saved record contains a fixed safe detail instead. Assert `check.main(["--failed-record", vendor, record, binary, manifest])` accepts only a valid failed required case for the expected vendor and matching digests, and rejects malformed, passing, wrong-vendor, or stale records. Restore each stub in `finally`.
- [ ] **Step 2: Verify red.** Run `PYTHONPATH=lib/python python3 tests/test_conformance.py`; expected: new sentinel assertions fail against current printing/persistence.
- [ ] **Step 3: Implement minimal boundary.** In `run()`, replace each insertion of case-provided `detail` into `record["cases"]` with a fixed string derived only from the allowlisted case name and status, for example `f"{name}: {status}"`. In `main()`, print only sorted failed case names/statuses; on pre-record or record-write exception print a bounded class such as `ihar: conformance setup failed for {vendor}: {type(error).__name__}`, never `str(error)`. Keep `jsonio.write` before the exit-1 decision and catch its validation/write errors as exit 3. Add the `--failed-record` mode to `check.main()` using `jsonio.read`, expected-vendor comparison, exact binary/manifest digest comparison, and `REQUIRED_CASES[vendor]` intersection with failed cases. Avoid printing the record path or dynamic case details.
- [ ] **Step 4: Verify green.** Rerun `PYTHONPATH=lib/python python3 tests/test_conformance.py`; expected exit 0, including existing real-vendor probe assertions or their documented skip.
- [ ] **Step 5: Commit.** Stage only the runner and its test; commit `fix(conformance): bound case diagnostics`.

### Task 2: Bootstrap-only transaction tolerance

**Closes:** Spec R1–R4 (eligibility, first activation, existing-generation rollback, enforced proof). Each step below proves or implements that transaction boundary.

**Files:**
- Modify: `lib/store/install.sh`
- Test: `tests/test_install.sh`

**Interfaces:**
- Consumes: Task 1's runner exit contract and verified record path `$IHAR_STORE/verification/$vendor-$(ihar_version_slug "$binary").json`.
- Produces: `_ihar_install_is_bootstrap` (true only with no receipt path and no installed vendor executable); the existing `ihar_install_conformance` returns success after an exit-1 failed-case record only when the transaction passed that predicate and Task 1's `--failed-record` validation passes. Every other failure remains nonzero.

- [ ] **Step 1: Add failing transaction tests.** Extend `run_install_scenario` in `tests/test_install.sh` with a fresh-generation fixture that removes only the test sandbox's receipt and installed vendor executables before the run. Stub conformance to return 1 and write a schema-valid failed record into the staged `verification` path. Assert install exit 0, receipt and new binaries active, failed record absent, and warning naming vendor plus `ihar check --conformance`. Assert bounded failed required case name/status reaches installer output while a sentinel record detail does not. Add a receipt-only and executable-only test that returns 1 but preserves the previous active fingerprint. Add bootstrap pre-record status 3, receipt failure, and activation failure tests that abort and publish no generation. Keep existing update/rollback scenarios.
- [ ] **Step 2: Verify red.** Run `bash tests/test_install.sh`; expected: fresh bootstrap success and existing-generation distinction fail before implementation.
- [ ] **Step 3: Implement minimal classification and decision.** In `ihar_install_transaction`, under the store lock and before stage creation, set a transaction-local bootstrap flag from absence of the receipt path and the active Codex/Claude installed executable paths, checking both `-e` and `-L` for each. Pass the flag into the staged build through an exported task-specific variable. In `ihar_install_conformance`, preserve the runner's exit code: a zero pass continues; an exit 1 may continue only for bootstrap and only when its staged record passes `ihar_python ihar.conformance.check --failed-record "$vendor" "$record" "$binary" "$IHAR_ROOT/manifests/hooks.json"`; remove that exact failed staged record before activation and record the unproven vendor for a bounded warning after successful activation. Any other status returns nonzero. Task 2 does not alter `_ihar_activate_generation`, mutable-owner inventories, or `ihar_store_verify_conformance`; the later result-review correction tightens the last gate for explicit rechecks only.
- [ ] **Step 4: Verify green and rollback.** Run `bash -n lib/store/install.sh` then `bash tests/test_install.sh`; expected both exit 0, including old rollback/migration tests and the new bootstrap cases. Inspect test sandbox fingerprints and stage cleanup assertions.
- [ ] **Step 5: Commit.** Stage only installer and transaction test; commit `fix(install): allow unproven first bootstrap`.

### Task 3: Preserve explicit check failure status

**Closes:** Spec R6 (nonzero explicit conformance result and valid text/JSON status), plus the result-review correction for R4's failed explicit recheck invariant. Each step below contributes to those contracts.

**Files:**
- Modify: `lib/cli/check.sh`
- Modify: `lib/cli/commands.sh` only if required to route Task 1's bounded stderr consistently.
- Review correction: `lib/store/lockfile.sh` and `lib/cli/commands.sh` for pending explicit recheck; `lib/store/install.sh` for bounded installer diagnostics.
- Test: `tests/test_profiles.sh`
- Review correction test: `tests/test_install.sh` for installer case output and `tests/test_profiles.sh` for stale-proof refusal and recovery.

**Interfaces:**
- Consumes: `ihar_cmd_conformance` exit 0 or nonzero and the existing text/JSON check renderers.
- Produces: `ihar_cmd_check` renders status when possible but exits nonzero if conformance failed; JSON stdout remains one status object and stderr carries bounded diagnostics.
- Review correction produces: a pending vendor recheck closes the enforced gate even if an older record survives a revocation or setup failure; a successful live recheck writes proof and clears the marker.

- [ ] **Step 1: Add failing tests.** Extend the existing Python wrapper in `tests/test_profiles.sh` to return a controlled nonzero status for one vendor conformance invocation. Assert `ihar check --conformance` exits nonzero even when status rendering succeeds. Capture `ihar --json check --conformance` stdout/stderr separately; parse stdout with `python3 -m json.tool`, assert no case text on stdout, and assert stderr identifies the vendor. Keep the existing plain-check and diff no-conformance assertions.
- [ ] **Step 2: Verify red.** Run `bash tests/test_profiles.sh`; expected the new exit-status assertion to fail.
- [ ] **Step 3: Implement minimal status propagation.** In `ihar_cmd_check`, capture `ihar_cmd_conformance` status instead of ignoring it, run the existing collection/rendering path, and return a rendering/collection error if one occurs or the captured conformance error otherwise. Keep JSON conformance output off stdout; route Task 1 bounded diagnostics to stderr. Preserve `--diff` semantics.
- [ ] **Step 4: Verify green.** Run `bash -n lib/cli/check.sh` and `bash tests/test_profiles.sh`; expected exit 0. Run `PYTHONPATH=lib/python python3 tests/test_conformance.py` if Task 1's output path changed.
- [ ] **Step 5: Commit.** Stage only CLI files actually changed and `tests/test_profiles.sh`; commit `fix(check): retain conformance failure status`.
- [ ] **Step 6: Apply the spec §4 result-review correction.** In the explicit active-store check path, mark a vendor recheck pending before revoking managed proof. Keep the marker after a revocation or live-run failure, including a malformed matching symlink or partial deletion; clear it only after a passing run writes proof. Make the enforced launch gate refuse a pending marker without a bootstrap bypass. Add a red test with an older passing proof plus malformed sibling entry, then assert gate exit 3, other-vendor proof preservation, and gate recovery after a passing retry. Run `bash -n lib/cli/commands.sh lib/store/lockfile.sh tests/test_profiles.sh` and `bash tests/test_profiles.sh`; expected exit 0 and no failed assertions.

### Task 4: Configuration, documentation, and integrated evidence

**Closes:** Spec R7 (literal configuration and documentation), with final integration evidence for R1–R6. Each step below verifies or documents those requirements.

**Files:**
- Modify locally, without staging: `.ihar_config`
- Modify: `.ihar_config.example`, `README.md`, `docs/README.ru.md`, `docs/lld/unified-harness.md`
- Update via MCP: relevant `ihar` iwiki documentation sections and task ledger
- Test: focused documentation checks and the final code suite

**Interfaces:**
- Consumes: Tasks 1–3's observed behavior and test evidence.
- Produces: literal local store/state roots, matching public/LLD/wiki contract, and final verified code fingerprint.

- [ ] **Step 1: Correct local values.** With `apply_patch`, change only the two user-approved `.ihar_config` lines to `IHAR_STORE=/home/ikeniborn/.local/share/ihar` and `IHAR_STATE_ROOT=/home/ikeniborn/.local/state/ihar`. Read no unrelated values and do not stage this ignored user file. Check the parser resolves those exact strings without shell evaluation.
- [ ] **Step 2: Align tracked docs.** In `.ihar_config.example`, replace copyable shell-style values with literal examples or clearly explain they are shell illustrations, not parsed expressions. In both READMEs, describe first bootstrap, native-auth `standard`, unproven enforced refusal, post-auth `ihar check --conformance`, and bounded failure diagnostics. In LLD §6.6 and §14.3, replace the unconditional pre-activation conformance assertion with the bootstrap-only exception and existing-generation rollback rule. Keep launch gate §12.4 unchanged.
- [ ] **Step 3: Verify docs and focused behavior.** Run `git diff --check`, `bash tests/test_install.sh`, `bash tests/test_profiles.sh`, and `PYTHONPATH=lib/python python3 tests/test_conformance.py`; expected exit 0. Review the resulting diff against spec R1–R7 and confirm `.ihar_config` is not staged. The iwiki structure check is the `wiki_lint` MCP call in Step 5.
- [ ] **Step 4: Run full suite once on the final unchanged code fingerprint.** Run `bash tests/run.sh`; expected exit 0 with zero failed test files. If a focused failure requires a code change, resolve and rerun that focused check before the one final full-suite run.
- [ ] **Step 5: Update iwiki and reconcile.** Bind the complete `.iwiki.toml` scope, update affected `ihar` documentation through MCP with CAS, refresh code links only against a ready unchanged source snapshot or publish a changed source snapshot as required, and run `wiki_lint`. Record command, exit status, revision, and current task lifecycle. Do not claim a code-graph rebuild if hosted source is unavailable.
- [ ] **Step 6: Commit tracked docs and hand off.** Stage only tracked docs changed by this task; commit `docs: document bootstrap conformance boundary`. Run `$check-chain result` only after all required implementation/test/doc evidence is present, then follow branch-finishing workflow for PR delivery. The ignored `.ihar_config` change remains local and is reported separately.
