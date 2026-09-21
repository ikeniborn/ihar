---
review:
  spec_hash: fd9c3cc5f686e3bf
  last_run: 2026-09-21
  phases:
    structure: { status: passed }
    coverage: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
  findings: []
chain:
  intent: docs/superpowers/intents/2026-09-21-install-hook-conformance-diagnostics-intent.md
---

# Install Hook Conformance Diagnostics Design

**Date:** 2026-09-21
**Status:** approved

## 1. Scope and accepted decision

This design resolves the first-install conflict in the approved intent. A genuinely fresh installation may activate installed components without successful live hook conformance. That activation is not conformance evidence: `standard` may launch subject to native vendor authentication, while every profile with enforced hooks remains fail-closed until the exact installed vendor binary and hook manifest pass the full live suite. The first installation attempts conformance so an already authenticated user can earn proof immediately. Failed live cases are tolerated only for the first activation. Updates and reinstalls of an existing generation retain mandatory pre-activation conformance and rollback.

The design changes the existing installer, conformance reporting, check command, tests, user configuration, and corresponding LLD/README/iwiki descriptions. It does not change vendor authentication ownership, relax hook integrity, create a new authentication flow, or broaden enforced-profile access.

## 2. Requirements and acceptance

### R1. Bootstrap eligibility

Before staging, the installer SHALL classify a transaction as initial bootstrap only when the active store has no install receipt path (not even a dangling receipt symlink) and neither installed ihar vendor executable exists in the active store/NVM locations. A malformed receipt or an installed vendor executable makes the transaction a reinstall, not a bootstrap. The classification is made under the required store lock and is not inferred from missing credentials or from a failed conformance attempt.

Acceptance: a clean store is eligible; a receipt-only, executable-only, or malformed-receipt store is not. A partially prepared store with neither receipt nor installed vendor executable remains eligible, but the staging and activation transaction still validates all assets and preserves mutable owners.

### R2. First-install conformance and activation

The staged installation SHALL verify release pins and structural inputs, install components, and attempt every installed vendor's full live suite against the staged binary and hooks while linking authentication only from the stable active store. A complete, schema-valid conformance record containing failed required cases MAY be tolerated only for an R1 bootstrap. A pre-record error, wrong pin, incomplete/invalid record, missing required case, or failed non-conformance installation step SHALL abort without activating the stage. Before bootstrap activation, failed records SHALL be removed from the staged verification directory; successful records MAY be activated. The staged receipt SHALL still describe the installed binary bytes, not claim conformance. A bootstrap warning SHALL name each unproven vendor and direct the user to `ihar check --conformance` after authentication.

Acceptance: a clean unauthenticated installation completes with a receipt and `unproven` conformance for each failed vendor; an authenticated clean installation with passing suites activates valid proof; a structural or pin failure never becomes a successful bootstrap. No failed record is mistaken for proof.

### R3. Existing-generation transaction

Any non-bootstrap `install` or `update` SHALL require all installed vendors' live suites to pass before activation. A failure SHALL discard the stage and preserve the previous installed generation, receipt, and conformance records. Existing auth, plugin, and vendor state remain at their stable owners and are never staged as installer-owned assets.

Acceptance: failed conformance or receipt publication on reinstall/update preserves a fingerprint of the prior active generation and receipt; no stage leaks or prior proof is replaced.

### R4. Enforced launch and post-auth proof

The existing launch gate SHALL continue to reject an enforced-hooks profile before vendor execution when the exact installed version, executable digest, or hook manifest lacks a successful complete record. `standard` retains best-effort hooks and vendor-native authentication behavior. After authentication through the vendor-owned path, `ihar check --conformance` SHALL run the full suite against active installed bytes, persist successful proof, and permit an enforced launch only when every required case passes.

Acceptance: enforced launch fails before proof with exit 3; it succeeds past the conformance gate only after a matching successful run. Changed binary or manifest invalidates proof. No mock, skipped case, or direct hook invocation substitutes for live evidence.

### R5. Bounded, secret-safe diagnostics

Both install and `ihar check --conformance` SHALL identify the vendor and the names/statuses of failed required cases without forwarding raw vendor stdout/stderr, model-written content, credential values, or dynamic exception text into user-facing output. A pre-record failure SHALL report the vendor and a bounded failure class without inventing case results. The detailed conformance record remains outside the repository and must not persist raw vendor output or model-written values in its `detail` fields. Text and JSON check output SHALL keep their declared formats; diagnostics for JSON mode go to stderr.

Acceptance: simulated vendor output containing a sentinel secret never appears in install/check output or a persisted conformance record; failed-case names appear; a pre-record failure has no fictitious case list.

### R6. Check command status

`ihar check --conformance` SHALL return nonzero if any vendor conformance run fails, even when the subsequent status collection/rendering succeeds. It SHALL still render the final status object when possible. Its JSON mode SHALL emit one valid status object to stdout and no case diagnostics to stdout.

Acceptance: one failed vendor makes the command nonzero; text and JSON reports remain valid; a successful post-auth run returns zero and reports `proven` for the installed vendor.

### R7. Configuration and documentation

The user's local project `.ihar_config` SHALL use absolute literal paths for `IHAR_STORE` and `IHAR_STATE_ROOT`. The parser SHALL remain data-only and SHALL NOT evaluate shell substitutions. The LLD §6.6 and §14.3, English and Russian README, and relevant iwiki pages SHALL describe bootstrap-unproven activation, mandatory existing-generation conformance, explicit post-auth proof, and safe diagnostics. The example configuration SHALL not imply that placeholder expressions are parsed when copied verbatim.

Acceptance: the local configuration resolves to intended absolute roots; the example/docs distinguish shell illustration from valid literal configuration; code, LLD, README, and wiki agree with test-observed behavior.

## 3. Component boundaries and data flow

`lib/store/install.sh` owns the under-lock bootstrap classification, staged transaction, and activation/rollback decision. It must not parse vendor output for security decisions. `ihar.conformance.run` owns live cases and closed record creation; a failed required case returns its existing distinct status from a pre-record error. A small validated report path exposes only vendor and required case names/statuses to shell callers. `lib/cli/commands.sh` invokes active-store conformance, while `lib/cli/check.sh` carries its failure status through status rendering. `lib/store/lockfile.sh` remains the authoritative enforced-profile gate; no bootstrap exception is added there.

Bootstrap flow: classify empty active generation under lock → stage and validate → install pinned components → attempt full live conformance → accept only successful records or complete failed-case records → discard failed staged records → stage receipt → activate transaction → report unproven vendors and post-auth command. Existing-generation flow remains stage → full conformance pass → receipt → activate, with rollback on failure. Post-auth flow is active `ihar check --conformance` → validated complete passing record → enforced launch gate.

## 4. Failure handling and security invariants

- Missing authentication may produce failed live cases and an unproven first install; it never produces a pass.
- A wrong pin, malformed record, missing required case, or pre-record error is not downgraded to a bootstrap warning.
- The presence of an old receipt or vendor executable prevents the bootstrap exception, even if the receipt is invalid.
- Active-generation activation failures retain the existing reverse-order rollback and recovery-backup behavior.
- No installer output or record includes vendor raw output, model-written values, credential content, or dynamic exception text.
- Failed explicit re-conformance cannot be treated as continued proof merely because an older pass existed; the launch gate evaluates the current persisted record.
- The installer never copies auth/plugin owners or user state into the stage and never deletes them.

## 5. Verification scenarios

1. Given an empty store and no vendor auth, when installation completes with complete failed live-case records, then `standard` can reach the vendor, enforced launch fails before vendor start, and check reports unproven vendors.
2. Given an empty store and usable auth, when all live cases pass, then installation activates passing records and an enforced launch passes the conformance gate.
3. Given a receipt or installed vendor executable, when conformance fails during install/update, then the command fails and the prior generation, receipt, and records are byte-identical.
4. Given a fresh store, when a pin/structure/pre-record validation fails, then installation fails and publishes no receipt or generation.
5. Given a bootstrap-unproven generation and available auth, when `ihar check --conformance` passes, then a complete record is persisted and enforced launch passes the proof gate.
6. Given a vendor failure and a sentinel secret in raw vendor output or model-written content, when install or check reports the failure, then only vendor/case identifiers appear and the secret appears in neither output nor persisted record.
7. Given one failed conformance run, when `ihar check --conformance --json` also collects status successfully, then stdout is one valid status object, stderr has bounded diagnostics, and exit status remains nonzero.
8. Given a failed activation or receipt step, when the transaction rolls back, then the previous active fingerprint remains unchanged and mutable vendor-owned files survive.

Focused shell/Python tests cover the transaction, record/report boundary, command exit status, and profile gate. Relevant regression suites and one full suite run on the final code fingerprint. A guarded local live run may follow exact-target and rollback checks; it never requires copying credentials into test fixtures.

## 6. Human checkpoints

Changing rules for secret access, weakening the enforced launch gate, or moving vendor authentication ownership requires separate explicit approval. Local install/conformance against the user's active store is guarded: inspect exact targets and preserve rollback evidence before running. No user data deletion, direct `master` commit, or direct merge is authorized. The checked spec must be approved before plan writing.
