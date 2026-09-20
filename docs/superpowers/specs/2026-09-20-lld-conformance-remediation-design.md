---
review:
  spec_hash: d18e54c98aca484b
  last_run: 2026-09-20
  phases:
    structure: { status: passed }
    coverage: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
  findings: []
chain:
  intent: docs/superpowers/intents/2026-09-20-lld-conformance-remediation-intent.md
---

# LLD Conformance Remediation Design

**Date:** 2026-09-20
**Status:** approved

## Scope and ordering

This design reconciles findings C2, C1, I2, I1, I3/I4, and I5/I6 in that strict order. Each finding is resolved on the side supported by executable evidence: implementation changes when the documented contract is sound, and the LLD changes when current behavior or a safer correction is the better contract.

The work remains inside the existing launcher, store, state, render, hook, CLI, and test boundaries. It does not replace the launch lifecycle or create another configuration system.

## Acceptance (from intent)

### Desired Outcomes

- Findings C2 through I6 are closed in the required order or explicitly converted into evidence-backed LLD corrections when the current implementation is the better contract.
- A fresh installation and every declared CLI scenario work from the tracked repository artifacts.
- Isolation and protected-path enforcement are not weakened.
- Claude and Codex persistent state is retained according to the reconciled contract.
- The complete relevant test suite passes, including new coverage for previously untested contracts.
- Code, LLD, tests, and iwiki documentation do not contradict one another.

### Done when

- C2 through I6 are reconciled between code and LLD, observable scenarios pass, the regression suite is green, iwiki is current, and delivery is ready to close through a PR.

## Design principles

1. A manifest describes a contract; one engine consumes it wherever that contract applies.
2. Release inputs are immutable. Machine-local evidence is stored outside the checkout.
3. Persistent vendor state has one canonical owner under `st/`; runtime homes own configuration only.
4. Security enforcement uses the strongest native boundary available. Hooks provide defense in depth and do not pretend to parse arbitrary shell programs.
5. Migration copies, verifies, and publishes atomically. It never deletes its source.
6. Automatic cleanup never deletes persistent vendor state.
7. Human-readable and machine-readable status are renderings of one collected result.

## C2: protected-path enforcement

### R-C2.1 Native Claude sandbox policy

For `protected`, Claude settings SHALL enable the native sandbox and render absolute `sandbox.filesystem.denyWrite` entries for `IHAR_STORE`, `IHAR_STATE_ROOT`, and the selected runtime home. They SHALL set `allowUnsandboxedCommands` to `false` and `failIfUnavailable` to `true`.

The OS sandbox is the authoritative boundary for Bash, PowerShell, Monitor, and child processes. The security hook SHALL continue to deny direct `Edit` and `Write` operations into protected paths. It SHALL NOT attempt to prove arbitrary shell commands safe by parsing shell text.

### R-C2.2 Enforcement evidence

Conformance SHALL run real write probes against the pinned Claude version. A direct shell write, an indirect child-process write, and direct file-tool writes into each protected root SHALL fail. A workspace write SHALL succeed. Sandbox unavailability and an unsandboxed retry SHALL fail closed for enforced profiles.

### Acceptance criteria

- Rendered Claude settings contain native deny-write rules for every protected root and strict fallback settings.
- Bash and a child process cannot mutate protected roots but can mutate the workspace.
- Direct file tools remain denied by the security hook.
- An unavailable sandbox prevents an enforced launch with exit 3.

## C1 and I5: release lockfile and install receipt

### R-C1.1 Immutable release lockfile

The tracked `.ihar-lockfile.json` SHALL contain immutable release inputs: schema version, vendor and dependency versions, downloadable artifact names and digests, and optional feature pins. A normal install or launch SHALL NOT modify it.

Machine-local fields such as installation time and hashes of produced binaries SHALL NOT live in the release lockfile. The LLD lockfile schema SHALL be corrected accordingly.

### R-C1.2 Local install receipt

`$IHAR_STORE/install-receipt.json` SHALL record the release lockfile digest, installation timestamp, installed component versions, and SHA-256 digests of the actual Claude and Codex executable bytes. It SHALL use a validated schema and atomic replacement.

The installer SHALL stage store changes and publish the receipt only after asset validation, component installation, binary hashing, and required conformance complete. Failure before publication SHALL leave the previously active store and receipt usable.

### R-I5.1 Launch-time binary verification

Every native launch SHALL compare the selected vendor binary with the install receipt before vendor execution. A mismatch under `standard` SHALL emit a warning and continue. A mismatch, missing receipt, or unreadable receipt under `protected` or `isolated` SHALL abort with exit 3. `ihar check` SHALL report `verified`, `mismatched`, or `missing receipt` for each vendor.

### Acceptance criteria

- A fresh clone contains a valid release lockfile and can enter the install workflow without a missing-file failure.
- A successful install leaves the tracked lockfile unchanged and atomically publishes a valid receipt.
- Failed installation cannot publish partial evidence or invalidate the previous receipt.
- Tampering either installed vendor binary produces the profile-specific warning or failure before vendor start.

## I2: vendor persistent-state manifest

### R-I2.1 Single state inventory

`manifests/state.json` SHALL be the only inventory of persistent vendor entries used by runtime linking and legacy migration. Each entry SHALL name a vendor, runtime-relative path, and kind (`directory`, `file`, or `sqlite-family`). Paths SHALL be safe relative paths.

The inventory SHALL reflect state produced by the pinned vendor versions. For Claude it includes `.claude.json`, prompt history, transcript/session directories, and other verified persistent entries. For Codex it includes sessions, history and session indices, shell snapshots, app-server control state, and the verified SQLite families such as state, goals, memories, and logs. Obsolete names SHALL be removed from the LLD when runtime evidence does not support them.

### R-I2.2 Runtime linking

Before a runtime home is published, directory targets SHALL be created under `st/<vendor>/` and linked into the runtime. Declared file links MAY initially point at a missing canonical target so the vendor can create it through the link. SQLite sidecars SHALL remain with their database family.

The runtime verifier SHALL distinguish rendered immutable files from persistent state links. Switching profiles SHALL not fork persistent state.

### R-I2.3 Migration

Legacy migration SHALL consume the same inventory. It SHALL preserve the existing lifecycle locks, process/open-descriptor compatibility probes, source-before/source-after/stage fingerprints, copy-only behavior, and rollback on failed publication.

### Acceptance criteria

- Every declared state entry is handled identically by linking and migration.
- State created under one profile is visible after switching profiles.
- Current SQLite databases and their WAL/SHM sidecars survive migration.
- A concurrent source mutation discards the staged migration and leaves the target unchanged.

## I1: tracked asset manifest

### R-I1.1 Explicit asset inventory

`manifests/assets.json` SHALL declare every tracked asset copied to the store or linked into a runtime. Each entry SHALL name the vendor scope, tracked source, runtime target, asset kind, and whether it is required or optional.

Required assets SHALL be validated before store mutation. A missing required asset SHALL abort installation. A missing optional asset SHALL produce an explicit diagnostic and SHALL appear in `ihar check`; it SHALL not be silently interpreted as delivered.

### R-I1.2 Tracked content boundary

The repository SHALL contain the common ihar skills and only portable configuration assets required by the inventory: vendor instructions, agents, commands/scripts, rules, and profiles. It SHALL NOT vendor authentication material, generated settings, caches, plugin caches, transcripts, or other vendor state.

Tracked shared skills SHALL carry provenance/version metadata so their source and update point are reviewable. Installer and runtime linking SHALL consume the same asset inventory instead of separate hardcoded arrays.

### Acceptance criteria

- A fresh clone contains every required inventory source.
- Missing required assets abort before the active store changes.
- Missing optional assets are reported consistently by install and check.
- Store and runtime targets contain only declared assets.

## I3 and I4: CLI status and maintenance contracts

### R-I3.1 Structured check result

`ihar check` SHALL collect one structured status object and render it as text or JSON. Both renderers SHALL describe the same fields: effective profile and guarantee, masking, dropped environment names, per-hook trust and conformance, gateway and network enforcement, MCP limitations, adapter capabilities, binary receipt state, asset diagnostics, and known gaps.

`ihar check --diff` SHALL render the desired configuration for both vendors into temporary directories and compare it with the active runtime homes without modifying store, state, or runtime content. `--conformance` remains the only check option that intentionally executes and records live vendor evidence.

The global `--json` flag SHALL be accepted only by commands that declare JSON output. Unsupported combinations SHALL return exit 2 rather than silently ignoring the flag.

### R-I4.1 Store migration

`ihar install --migrate-store` SHALL reuse the migration transaction: acquire fail-closed quiescence evidence, fingerprint sources, copy declared eligible content to a stage, re-fingerprint sources, validate the stage, then atomically publish. Legacy sources SHALL never be deleted.

Only assets and machine-local evidence represented by current contracts are eligible. Configuration and state owned elsewhere SHALL not be swept into the new store.

### R-I4.2 Runtime cleanup

`ihar homes clean` SHALL remove only expired runtime homes. `ihar homes clean <id>` SHALL apply the same runtime-only cleanup to the exact project-state ID. Both forms SHALL preserve `st/`.

Orphan persistent states SHALL be listed but not automatically removed. Full persistent-state deletion is outside this design and requires a separate explicit command and human-only approval.

### Acceptance criteria

- Text and JSON check results have semantic parity and a stable validated JSON shape.
- Diff reports desired-versus-active changes and leaves filesystem fingerprints unchanged.
- Unsupported `--json` combinations fail with exit 2.
- Store migration is copy-only, rejects active or changing sources, and rolls back failed publication.
- Both cleanup forms preserve all content below `st/`.

## I6: concurrency and test-plan integrity

### R-I6.1 Cross-component concurrency suite

`tests/test_concurrency.sh` SHALL use deterministic barriers and observable overlap markers to verify:

1. two launches for one project/vendor under different profiles publish distinct runtime homes without modifying either after publication;
2. parallel install attempts serialize on the required store lock;
3. clients with different masking levels acquire different gateway instances;
4. releasing one gateway consumer leaves an instance running for another consumer.

Timing-only assertions are insufficient. Each case SHALL prove the relevant state transition.

### R-I6.2 Executable test inventory

The LLD test plan SHALL name the files that actually own each case. Existing sandbox and gateway-log cases remain in their effective current test files rather than gaining empty compatibility files. A machine-readable test inventory SHALL be validated so every referenced path exists.

### Acceptance criteria

- The cross-component concurrency suite fails when serialization, runtime separation, instance separation, or refcount retention is removed.
- Every test path declared by the inventory exists and is executed by `tests/run.sh`.
- The final unchanged code fingerprint passes the complete suite once.

## Data flow

### Install

`release lockfile → validate assets/state manifests → stage store → install binaries → hash installed outputs → conformance → atomic store and receipt publication`

### Launch

`resolve profile → verify lockfile and receipt → setup canonical state → acquire enforcement → render → materialize manifest-driven runtime → verify trust/conformance → execute vendor`

### Migration

`acquire quiescence → fingerprint source → staged copy → fingerprint source again → validate stage → atomic publish`

### Check

`collect facts once → text renderer | JSON renderer | desired-versus-active diff`

## Failure handling

- Security boundary unavailable or unproven under an enforced profile: exit 3 before vendor start.
- Malformed release lockfile, receipt, asset manifest, or state manifest on an enforcement path: exit 3.
- Missing required asset: abort installation before store mutation.
- Missing optional asset: explicit diagnostic and status finding.
- Migration lock, quiescence, fingerprint, or publication failure: discard stage, preserve source and previous target.
- Cleanup target absent or malformed: exit 2 without deletion.
- Unsupported output-mode combination: exit 2.

## Human checkpoints

The user approved these proposal-first contract changes during design review:

- Claude native sandbox policy is authoritative for shell writes; hook shell parsing is rejected.
- Release lockfile and local install evidence are split.
- Obsolete state names are replaced by a pinned-version state inventory.
- Missing assets use explicit required/optional semantics.
- Automatic cleanup never deletes persistent vendor state.
- Test-plan drift is corrected to actual ownership rather than creating empty files.

Any implementation discovery that changes these decisions, weakens fail-closed behavior, changes public CLI semantics beyond this document, or creates data-loss risk returns to design review.
