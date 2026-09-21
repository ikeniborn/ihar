---
status: approved
result_check:
  verdict: OK
  source: plan
  plan_hash: af450391d25c08d6
  last_run: 2026-09-21
  reviewed: true
  docs_checked: true
review:
  plan_hash: af450391d25c08d6
  last_run: 2026-09-20
  phases:
    structure: { status: passed }
    coverage: { status: passed }
    dependencies: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
  findings: []
chain:
  intent: docs/superpowers/intents/2026-09-20-lld-conformance-remediation-intent.md
  spec: docs/superpowers/specs/2026-09-20-lld-conformance-remediation-design.md
---

# LLD Conformance Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close findings C2, C1, I2, I1, I3/I4, and I5/I6 in that strict order while keeping code, executable contracts, LLD, tests, and iwiki aligned.

**Architecture:** Existing Bash lifecycle remains the orchestrator. Small Python modules validate JSON contracts and perform deterministic collection, fingerprinting, and rendering; Bash owns locks, process lifecycle, atomic publication, and CLI exit semantics. Release inputs stay tracked and immutable, while machine-local evidence and persistent vendor state stay below the store and state roots.

**Tech Stack:** Bash 4+, Python 3 standard library, JSON manifests validated by `ihar.jsonio`, `flock`, `rsync`, existing dependency-free test harness.

**Spec:** `docs/superpowers/specs/2026-09-20-lld-conformance-remediation-design.md`

## Global Constraints

- Required implementation order is C2 → C1 → I2 → I1 → I3/I4 → I5/I6.
- Enforced-profile security failure exits 3 before vendor execution.
- Migration and store migration are copy-only; source data is never deleted.
- Automatic cleanup never removes persistent state below `st/`.
- `.ihar-lockfile.json` is immutable release input; installation evidence belongs in `$IHAR_STORE/install-receipt.json`.
- `manifests/state.json` is the only persistent-state inventory used by runtime linking and migration.
- `manifests/assets.json` is the only tracked-asset inventory used by installation and runtime linking.
- JSON contracts reject unknown keys and unsafe relative paths.
- Tests use deterministic barriers or observable state; timing-only concurrency assertions are forbidden.
- Run the complete suite once, only after the final implementation fingerprint is stable.

---

## File structure

- `lib/render/config.sh`: pass protected roots and strict sandbox mode to Claude settings rendering.
- `lib/python/ihar/render/claude_settings.py`: emit native Claude sandbox filesystem rules.
- `lib/python/ihar/conformance/run.py`: execute real protected-root and workspace write probes.
- `.ihar-lockfile.json`: tracked release-only pins.
- `lib/python/ihar/jsonio.py`: schemas for lockfile, install receipt, state manifest, asset manifest, check result, and test inventory.
- `lib/python/ihar/install_receipt.py`: build, read, and atomically write machine-local install evidence.
- `lib/store/install.sh`: validate release inputs, stage publication, and publish receipt last.
- `lib/store/lockfile.sh`: release drift and receipt-backed binary verification helpers.
- `manifests/state.json`: canonical persistent vendor state inventory.
- `lib/python/ihar/inventory.py`: validated manifest queries shared by Bash call sites.
- `lib/state/links.sh`: manifest-driven runtime links.
- `lib/state/migrate.sh`: manifest-driven migration copy and fingerprint scope.
- `lib/python/ihar/migration_fingerprint.py`: fingerprint entries selected from the state manifest.
- `manifests/assets.json`: canonical tracked asset inventory with required/optional semantics.
- `lib/store/assets.sh`: validate, stage, and diagnose tracked assets from the manifest.
- `lib/cli/check.sh`: collect one structured check result and render text, JSON, or diff.
- `lib/store/migrate.sh`: fail-closed legacy-store copy transaction.
- `lib/state/gc.sh`: runtime-only cleanup for current or exact named state.
- `manifests/tests.json`: executable test-path inventory.
- `tests/test_concurrency.sh`: deterministic cross-component concurrency cases.

### Task 1: C2 native Claude protected-path enforcement

**Files:**
- Modify: `lib/render/config.sh`
- Modify: `lib/python/ihar/render/claude_settings.py`
- Modify: `lib/python/ihar/conformance/run.py`
- Modify: `tests/test_profiles.sh`
- Modify: `tests/test_conformance.py`
- Modify: `tests/test_hooks.sh`

**Interfaces:**
- Consumes: `IHAR_PROFILE_SANDBOX`, `IHAR_STORE`, `IHAR_STATE_ROOT`, and selected runtime path.
- Produces: `render_sandbox(mode: str, protected_roots: list[str]) -> dict | None`; conformance cases `sandbox-direct-write`, `sandbox-child-write`, and `sandbox-workspace-write`.

**Closes:** `R-C2.1`, `R-C2.2`.

- [ ] **Step 1: Add failing renderer assertions**

Add a Claude renderer helper to `tests/test_profiles.sh` and assert the parsed JSON, not string fragments:

```bash
settings="$(render_claude protected "$IHAR_STORE" "$IHAR_STATE_ROOT" "$PROJECT/runtime")"
assert_eq "Claude disables unsandboxed retries" "False" \
  "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sandbox"]["allowUnsandboxedCommands"])' <<<"$settings")"
assert_eq "Claude fails when sandbox is unavailable" "True" \
  "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sandbox"]["failIfUnavailable"])' <<<"$settings")"
for protected in "$IHAR_STORE" "$IHAR_STATE_ROOT" "$PROJECT/runtime"; do
  assert_contains "Claude denies $protected" "$settings" "$protected"
done
```

Also assert standard omits the managed sandbox object and protected paths are absolute and deduplicated.

- [ ] **Step 2: Run the focused renderer test and confirm failure**

```bash
bash tests/test_profiles.sh
```

Expected: failure because current Claude sandbox uses the string `workspace-write` and lacks `denyWrite`, `allowUnsandboxedCommands`, and `failIfUnavailable`.

- [ ] **Step 3: Render the native Claude policy minimally**

Change `_ihar_render_claude_config` to pass a JSON array of protected roots. Implement the Python boundary with this exact result shape:

```python
def render_sandbox(mode: str, protected_roots: list[str]) -> dict | None:
    if mode == "vendor-default":
        return None
    if mode == "read-only":
        return {"enabled": True, "filesystem": "read-only"}
    roots = sorted({os.path.abspath(path) for path in protected_roots})
    return {
        "enabled": True,
        "allowUnsandboxedCommands": False,
        "failIfUnavailable": True,
        "filesystem": {"denyWrite": roots},
    }
```

Keep hook enforcement limited to direct `Edit`/`Write`; add a regression assertion in `tests/test_hooks.sh` that shell text is not treated as a security parser.

- [ ] **Step 4: Add failing conformance write-probe tests**

In `tests/test_conformance.py`, fake the vendor subprocess and require these case results:

```python
assert record["cases"]["sandbox-direct-write"]["status"] == "passed"
assert record["cases"]["sandbox-child-write"]["status"] == "passed"
assert record["cases"]["sandbox-workspace-write"]["status"] == "passed"
```

The protected probes target one file in each protected root; the positive probe targets the temporary workspace. A sandbox-unavailable result must be `failed`, never `skipped`, for Claude.

- [ ] **Step 5: Implement and run focused C2 tests**

Drive the pinned Claude binary through its non-interactive command path in `conformance.run`; check return status and filesystem effect. Do not infer enforcement from hook output.

```bash
bash tests/test_profiles.sh
bash tests/test_hooks.sh
PYTHONPATH=lib/python python3 tests/test_conformance.py
```

Expected: all pass.

- [ ] **Step 6: Commit C2**

```bash
git add lib/render/config.sh lib/python/ihar/render/claude_settings.py lib/python/ihar/conformance/run.py tests/test_profiles.sh tests/test_conformance.py tests/test_hooks.sh
git commit -m "fix(security): enforce Claude protected paths natively"
```

### Task 2: C1 immutable release lockfile and atomic install receipt

**Files:**
- Create: `.ihar-lockfile.json`
- Create: `lib/python/ihar/install_receipt.py`
- Modify: `lib/python/ihar/jsonio.py`
- Modify: `lib/python/ihar/lockfile.py`
- Modify: `lib/store/install.sh`
- Modify: `tests/test_jsonio.py`
- Modify: `tests/test_lockfile.sh`
- Modify: `tests/test_install.sh`
- Modify: `tests/test_contracts.sh`

**Interfaces:**
- Consumes: validated release lockfile and installed executable paths.
- Produces: `build_receipt(lockfile, binaries, installed_at) -> dict`; `write_receipt(path, receipt) -> None` using temp-file, `fsync`, and `os.replace`; CLI `python3 -m ihar.install_receipt build <lockfile> <target> <claude-path|-> <codex-path|->`.

**Closes:** `R-C1.1`, `R-C1.2`. Receipt consumption for `R-I5.1` remains Task 6 so required finding order is preserved.

- [ ] **Step 1: Add failing schemas and immutable-input tests**

Add `install-receipt` to the registered-contract loop and test these shapes:

```python
LOCKFILE = {"schema": 1, "node": {"version": "22.23.1"}, "claude": {"version": "2.1.274"}}
RECEIPT = {
    "schema": 1,
    "release_lock_sha256": "a" * 64,
    "installed_at": "2026-09-20T00:00:00Z",
    "components": {"claude": {"version": "2.1.274", "binary_sha256": "b" * 64}},
}
```

Reject `installedAt` and `binarySha256` in the release lockfile. Reject absent/extra receipt fields, unknown vendors, and malformed digests.

- [ ] **Step 2: Run schema tests and confirm failure**

```bash
PYTHONPATH=lib/python python3 tests/test_jsonio.py
bash tests/test_contracts.sh
```

Expected: missing `install-receipt` kind and legacy mutable lockfile fields remain accepted.

- [ ] **Step 3: Add tracked release pins and receipt schema**

Create `.ihar-lockfile.json` with verified immutable pins from current source lockfiles:

```json
{
  "schema": 1,
  "node": {"version": "22.23.1"},
  "claude": {"version": "2.1.274"},
  "codex": {
    "version": "rust-v0.154.0",
    "asset": "codex-x86_64-unknown-linux-musl.tar.gz",
    "sha256": "d7e18b2597ae8f242f5f31ee9e90deef48dbc9edd634d9868fb6435d08c07f02"
  },
  "acp": {"claude-agent-acp": "0.79.0", "codex-acp": "6ec22f3"}
}
```

Add the SHA-256 map for every shipped hook and managed-hook artifact to the tracked file, generated once from the reviewed repository bytes and committed with them. Remove mutating `--set`/`--pin-tree` behavior from `ihar.lockfile`; release validation remains read-only. Future hook changes update their release pins in the same reviewed commit, never during install.

- [ ] **Step 4: Add failing atomic-publication tests**

In `tests/test_install.sh`, save the lockfile digest and an existing receipt, inject a failure immediately before receipt publication, and assert:

```bash
assert_eq "install never rewrites release lock" "$before_lock" "$(sha256sum "$IHAR_LOCKFILE" | cut -d' ' -f1)"
assert_eq "failed install preserves receipt" "$before_receipt" "$(sha256sum "$IHAR_STORE/install-receipt.json" | cut -d' ' -f1)"
assert_exit "receipt temp is not leaked" 1 compgen -G "$IHAR_STORE/.install-receipt-*"
```

Then assert a successful install records actual executable digests and the exact release-lock digest.

- [ ] **Step 5: Implement receipt generation and publish it last**

`install_receipt.py` reads versions from the release lock and hashes only executable files that exist. `write_receipt` validates before writing, sets mode `0600`, flushes, `fsync`s, and replaces the target. `_ihar_install_all` calls it only after component installation and conformance. Eliminate every write to `$IHAR_LOCKFILE`.

- [ ] **Step 6: Run focused C1 tests**

```bash
PYTHONPATH=lib/python python3 tests/test_jsonio.py
bash tests/test_contracts.sh
bash tests/test_lockfile.sh
bash tests/test_install.sh
```

Expected: all pass; `git diff -- .ihar-lockfile.json` stays empty across the install fixture.

- [ ] **Step 7: Commit C1**

```bash
git add .ihar-lockfile.json lib/python/ihar/install_receipt.py lib/python/ihar/jsonio.py lib/python/ihar/lockfile.py lib/store/install.sh tests/test_jsonio.py tests/test_lockfile.sh tests/test_install.sh tests/test_contracts.sh
git commit -m "fix(store): separate release pins from install evidence"
```

### Task 3: I2 single persistent-state inventory

**Files:**
- Create: `manifests/state.json`
- Create: `lib/python/ihar/inventory.py`
- Modify: `lib/python/ihar/jsonio.py`
- Modify: `lib/state/links.sh`
- Modify: `lib/state/migrate.sh`
- Modify: `lib/python/ihar/migration_fingerprint.py`
- Modify: `tests/test_jsonio.py`
- Modify: `tests/test_contracts.sh`
- Modify: `tests/test_state.sh`
- Modify: `tests/test_sessions_readers.py`

**Interfaces:**
- Consumes: `state-manifest` schema `{schema, entries[]}` with `vendor`, `path`, and `kind`.
- Produces: `python3 -m ihar.inventory state <manifest> <vendor>` tab-separated `path<TAB>kind`; `fingerprint(root, entries) -> str`.

**Closes:** `R-I2.1`, `R-I2.2`, `R-I2.3`.

- [ ] **Step 1: Add failing state-manifest contract tests**

Use this contract and reject absolute paths, `..`, empty components, duplicate `(vendor,path)` keys, and unsupported kinds:

```json
{"schema":1,"entries":[{"vendor":"codex","path":"state_5.sqlite","kind":"sqlite-family"}]}
```

Register `state-manifest` in `jsonio.KINDS` and `tests/test_contracts.sh`.

- [ ] **Step 2: Add failing linking and migration parity tests**

Extend `tests/test_state.sh` with a temporary manifest containing one directory, one initially absent file, and one SQLite family. Assert runtime links for the directory and dangling file, plus migration of the database, `-wal`, and `-shm`. Assert a manifest entry added to the fixture affects both paths without editing Bash arrays.

```bash
assert_eq "linker and migration read the same entries" \
  "$(state_inventory claude)" "$(migration_inventory claude)"
```

Replace obsolete `thread_history_1.sqlite` fixture expectations with current `goals_1.sqlite`, `memories_1.sqlite`, and `logs_2.sqlite` families.

- [ ] **Step 3: Run focused I2 tests and confirm failure**

```bash
PYTHONPATH=lib/python python3 tests/test_jsonio.py
bash tests/test_contracts.sh
bash tests/test_state.sh
PYTHONPATH=lib/python python3 tests/test_sessions_readers.py
```

Expected: hard-coded link and migration arrays disagree with the manifest contract.

- [ ] **Step 4: Create the canonical pinned-version inventory**

Populate `manifests/state.json` with verified current entries:

```json
{
  "schema": 1,
  "entries": [
    {"vendor":"claude","path":".claude.json","kind":"file"},
    {"vendor":"claude","path":"history.jsonl","kind":"file"},
    {"vendor":"claude","path":"projects","kind":"directory"},
    {"vendor":"claude","path":"sessions","kind":"directory"},
    {"vendor":"claude","path":"session-env","kind":"directory"},
    {"vendor":"claude","path":"file-history","kind":"directory"},
    {"vendor":"codex","path":"sessions","kind":"directory"},
    {"vendor":"codex","path":"history.jsonl","kind":"file"},
    {"vendor":"codex","path":"session_index.jsonl","kind":"file"},
    {"vendor":"codex","path":"shell_snapshots","kind":"directory"},
    {"vendor":"codex","path":"app-server-control","kind":"directory"},
    {"vendor":"codex","path":"state_5.sqlite","kind":"sqlite-family"},
    {"vendor":"codex","path":"goals_1.sqlite","kind":"sqlite-family"},
    {"vendor":"codex","path":"memories_1.sqlite","kind":"sqlite-family"},
    {"vendor":"codex","path":"logs_2.sqlite","kind":"sqlite-family"}
  ]
}
```

- [ ] **Step 5: Replace hard-coded state arrays with inventory queries**

`ihar_link_runtime` creates directory sources, allows dangling links for declared files, and expands SQLite families to base, `-wal`, and `-shm` links. Migration and fingerprinting receive the same expanded list. Preserve lifecycle locks, pre/post fingerprints, special-file exclusions, copy-only publication, and rollback.

- [ ] **Step 6: Run focused I2 tests**

```bash
PYTHONPATH=lib/python python3 tests/test_jsonio.py
bash tests/test_contracts.sh
bash tests/test_state.sh
PYTHONPATH=lib/python python3 tests/test_sessions_readers.py
```

Expected: all pass, including concurrent source mutation rollback and WAL/SHM retention.

- [ ] **Step 7: Commit I2**

```bash
git add manifests/state.json lib/python/ihar/inventory.py lib/python/ihar/jsonio.py lib/state/links.sh lib/state/migrate.sh lib/python/ihar/migration_fingerprint.py tests/test_jsonio.py tests/test_contracts.sh tests/test_state.sh tests/test_sessions_readers.py
git commit -m "fix(state): drive persistence from one manifest"
```

### Task 4: I1 explicit tracked-asset inventory

**Files:**
- Create: `manifests/assets.json`
- Create: `lib/store/assets.sh`
- Create: `skills/README.md`
- Create: `manifests/config/claude/CLAUDE.md`
- Create: `manifests/config/codex/AGENTS.md`
- Modify: `ihar.sh`
- Modify: `lib/python/ihar/jsonio.py`
- Modify: `lib/python/ihar/inventory.py`
- Modify: `lib/store/install.sh`
- Modify: `lib/state/links.sh`
- Modify: `tests/test_contracts.sh`
- Modify: `tests/test_install.sh`
- Modify: `tests/test_state.sh`

**Interfaces:**
- Consumes: `asset-manifest` entries with `vendor`, `source`, `target`, `kind`, `required`, and `runtime`.
- Produces: `ihar_asset_validate <manifest>`; `ihar_asset_install <stage>`; `ihar_asset_diagnostics` lines `required|optional<TAB>present|missing<TAB>source<TAB>target`.

**Closes:** `R-I1.1`, `R-I1.2`.

- [ ] **Step 1: Add failing asset-schema and source-boundary tests**

Validate this minimum shape:

```json
{"schema":1,"entries":[{"vendor":"common","source":"hooks","target":"hooks","kind":"directory","required":true,"runtime":false}]}
```

Reject unsafe paths, duplicate targets per vendor, required sources that do not exist, and manifest entries targeting `auth`, caches, generated settings, plugins, transcripts, or `st/`.

- [ ] **Step 2: Add failing installer/linker parity tests**

In `tests/test_install.sh`, remove one required fixture source and assert exit 3 before the active store fingerprint changes. Remove one optional source and assert successful install plus explicit `optional missing` output. In `tests/test_state.sh`, assert every `runtime:true` installed target is linked and no undeclared store entry is linked.

- [ ] **Step 3: Run focused I1 tests and confirm failure**

```bash
bash tests/test_contracts.sh
bash tests/test_install.sh
bash tests/test_state.sh
```

Expected: installer and linker still use separate hard-coded trees/arrays and silently skip missing sources.

- [ ] **Step 4: Define narrow portable assets**

Populate `manifests/assets.json` only with repository-owned portable content: common hooks, manifests, skills metadata, Claude instructions, and Codex instructions. Mark currently absent optional vendor extension directories optional; do not create authentication, generated settings, caches, plugin caches, or vendor state. `skills/README.md` must record source repository, source revision/update command, and that no external skill payload is bundled yet.

- [ ] **Step 5: Implement one asset engine**

Source `lib/store/assets.sh` from `ihar.sh`. Validate every required source before creating or mutating the stage. Copy declared entries into a store stage, publish atomically, and make `ihar_link_runtime` query the same manifest for `runtime:true` entries. Missing optional entries emit stable diagnostics for later check collection.

- [ ] **Step 6: Run focused I1 tests**

```bash
bash tests/test_contracts.sh
bash tests/test_install.sh
bash tests/test_state.sh
```

Expected: all pass; active store remains unchanged on missing required input.

- [ ] **Step 7: Commit I1**

```bash
git add manifests/assets.json lib/store/assets.sh skills/README.md manifests/config/claude/CLAUDE.md manifests/config/codex/AGENTS.md ihar.sh lib/python/ihar/jsonio.py lib/python/ihar/inventory.py lib/store/install.sh lib/state/links.sh tests/test_contracts.sh tests/test_install.sh tests/test_state.sh
git commit -m "fix(store): install tracked assets from one manifest"
```

### Task 5: I3/I4 structured check, store migration, and safe runtime cleanup

**Files:**
- Create: `lib/cli/check.sh`
- Create: `lib/store/migrate.sh`
- Create: `lib/python/ihar/check_result.py`
- Modify: `ihar.sh`
- Modify: `lib/cli/args.sh`
- Modify: `lib/cli/commands.sh`
- Modify: `lib/cli/usage.sh`
- Modify: `lib/python/ihar/jsonio.py`
- Modify: `lib/state/gc.sh`
- Modify: `lib/store/install.sh`
- Modify: `tests/test_config.sh`
- Modify: `tests/test_install.sh`
- Modify: `tests/test_profiles.sh`
- Modify: `tests/test_state.sh`
- Modify: `tests/test_jsonio.py`

**Interfaces:**
- Consumes: resolved profile, gateway/MCP/adapter facts, hook/conformance records, receipt status, asset diagnostics, active runtime homes.
- Produces: `ihar_check_collect <target-json>`; `python3 -m ihar.check_result text|json <result>`; `ihar_check_diff`; `ihar_store_migrate`; `ihar_state_clean_runtimes <days> <state>`.

**Closes:** `R-I3.1`, `R-I4.1`, `R-I4.2`.

- [ ] **Step 1: Add failing CLI mode and check-result tests**

Add `IHAR_FLAG_DIFF=false`, parse `check --diff`, and explicitly allow global `--json` only for `check`, `sessions`, and existing daemon JSON paths. Assert:

```bash
assert_exit "check supports JSON" 0 ihar --json check
assert_exit "launch rejects JSON" 2 ihar --json codex --dry-run
assert_exit "install rejects JSON" 2 ihar --json install
```

Register a closed `check-result` schema. Parse text and JSON outputs from the same fixture and compare profile, guarantee, masking, gateway, both vendors' receipt status, asset findings, hooks, MCP notes, and known gaps.

- [ ] **Step 2: Add failing side-effect-free diff tests**

Fingerprint store, state, and active runtimes before and after `ihar check --diff`; assert identical fingerprints. Change a rendered fixture and assert the diff names both vendor and relative path. Assert `--conformance` is the only check mode that changes conformance evidence.

- [ ] **Step 3: Implement collect-once check rendering**

Move current `ihar_cmd_check` fact gathering into `ihar_check_collect`, validate the JSON, then route to text or JSON rendering. `ihar_check_diff` renders both vendors into temporary directories, uses existing runtime verification comparison rules, prints differences, and always removes its temporary directories.

- [ ] **Step 4: Add failing copy-only store migration tests**

Create a legacy store fixture, hold its lifecycle lock, and assert `install --migrate-store` exits 3 without copying. Mutate a source during the staged copy and assert the stage is discarded. On success, assert eligible manifest assets and the old receipt are copied, source fingerprints remain unchanged, and unrelated configuration/state are excluded.

- [ ] **Step 5: Implement fail-closed store migration**

Parse `--migrate-store` only for `install`. In `lib/store/migrate.sh`, reuse the lifecycle-lock and fingerprint transaction pattern: exclusive required lock, writer/open-descriptor check, source fingerprint, declared-entry copy to stage, source re-fingerprint, stage validation, atomic publish. Never call `rm` on a legacy source.

- [ ] **Step 6: Add failing runtime-only cleanup tests**

Create current, named, orphan, and malformed states with old runtime directories plus sentinel files below `st/`. Assert:

```bash
assert_exit "clean current runtimes" 0 ihar homes clean
assert_exit "clean exact state runtimes" 0 ihar homes clean "$named_id"
assert_exit "unknown state id is usage" 2 ihar homes clean missing
assert_exit "current persistent state survives" 0 test -f "$current/st/claude/sentinel"
assert_exit "named persistent state survives" 0 test -f "$named/st/codex/sentinel"
assert_exit "orphan state survives" 0 test -d "$orphan"
```

- [ ] **Step 7: Replace orphan deletion with runtime cleanup**

`ihar_cmd_homes clean` resolves the current state when no ID is supplied or validates the exact `$IHAR_STATE_ROOT/<id>` marker when supplied. It calls only `ihar_state_clean_runtimes`; `ihar_state_list` continues reporting orphans. Remove automatic orphan deletion from the command path.

- [ ] **Step 8: Run focused I3/I4 tests**

```bash
bash tests/test_config.sh
bash tests/test_profiles.sh
bash tests/test_install.sh
bash tests/test_state.sh
PYTHONPATH=lib/python python3 tests/test_jsonio.py
```

Expected: all pass; diff and cleanup fingerprints prove no forbidden mutation.

- [ ] **Step 9: Commit I3/I4**

```bash
git add lib/cli/check.sh lib/store/migrate.sh lib/python/ihar/check_result.py ihar.sh lib/cli/args.sh lib/cli/commands.sh lib/cli/usage.sh lib/python/ihar/jsonio.py lib/state/gc.sh lib/store/install.sh tests/test_config.sh tests/test_install.sh tests/test_profiles.sh tests/test_state.sh tests/test_jsonio.py
git commit -m "fix(cli): make status and maintenance contracts explicit"
```

### Task 6: I5/I6 launch verification, concurrency proof, and executable test inventory

**Files:**
- Create: `manifests/tests.json`
- Create: `tests/test_concurrency.sh`
- Modify: `lib/store/lockfile.sh`
- Modify: `lib/cli/commands.sh`
- Modify: `lib/python/ihar/jsonio.py`
- Modify: `tests/run.sh`
- Modify: `tests/test_lockfile.sh`
- Modify: `tests/test_lifecycle.sh`
- Modify: `tests/test_gateway_explicit.sh`
- Modify: `tests/test_contracts.sh`
- Modify: `docs/lld/unified-harness.md`

**Interfaces:**
- Consumes: `$IHAR_STORE/install-receipt.json`, selected vendor executable, runtime/store/gateway lock seams.
- Produces: `ihar_receipt_binary_status <vendor> <binary>` returning `verified`, `mismatched`, or `missing receipt`; deterministic concurrency barriers; validated `test-inventory` paths consumed by `tests/run.sh`.

**Closes:** `R-I5.1`, `R-I6.1`, `R-I6.2`.

- [ ] **Step 1: Add failing receipt-backed launch verification tests**

Replace binary-pin fixtures in `tests/test_lockfile.sh` with receipts. Assert standard warns and continues on mismatch; protected and isolated exit 3 for mismatch, missing receipt, or unreadable receipt. In `tests/test_lifecycle.sh`, use a fake vendor that writes a start marker and assert no marker exists after enforced verification failure.

- [ ] **Step 2: Implement receipt verification before vendor execution**

`ihar_store_verify` validates the release lock and hook pins, then calls `ihar_receipt_binary_status` for the selected native vendor. Standard logs mismatch/missing receipt; protected and isolated call `ihar_die 3`. `ihar check` exposes the same status strings from the shared helper.

- [ ] **Step 3: Add deterministic concurrency cases**

Create `tests/test_concurrency.sh` with named FIFO or file barriers and explicit state markers:

```bash
wait_for_file() { while [[ ! -e "$1" ]]; do :; done; }
```

Case A pauses two profile renders before publication, releases both, and proves distinct runtime paths plus unchanged post-publication hashes. Case B holds the store lock in install 1, proves install 2 has not reached its entry marker, releases install 1, then proves ordered entry markers. Case C acquires standard and secrets gateways and proves different instance keys/PIDs. Case D acquires one instance twice, releases once, proves PID and socket remain, then releases the second consumer and proves shutdown.

- [ ] **Step 4: Add executable test inventory validation**

Create `manifests/tests.json`:

```json
{"schema":1,"paths":["tests/test_contracts.sh","tests/test_concurrency.sh","tests/test_profiles.sh","tests/test_hooks.sh","tests/test_gateway_routes.py"]}
```

The complete file lists every path named by the LLD test plan. Register `test-inventory`, reject duplicate or unsafe paths, and make `tests/run.sh` validate that every listed path exists and is among the discovered `tests/test_*.sh`/`tests/test_*.py` files before execution.

- [ ] **Step 5: Run focused I5/I6 tests**

```bash
bash tests/test_lockfile.sh
bash tests/test_lifecycle.sh
bash tests/test_gateway_explicit.sh
bash tests/test_concurrency.sh
bash tests/test_contracts.sh
```

Expected: all pass; removing runtime separation, store serialization, gateway instance separation, or refcount retention makes its corresponding concurrency assertion fail.

- [ ] **Step 6: HUMAN CHECKPOINT — reconcile LLD paths and contracts**

Update `docs/lld/unified-harness.md` only for implementation discoveries that preserve the approved design: exact JSON fields, function ownership, current manifest entries, and actual test paths. Any discovery that weakens fail-closed behavior, changes public CLI semantics, or risks data loss returns to design review instead of editing through it.

- [ ] **Step 7: Run syntax and focused contract checks**

```bash
bash -n ihar.sh lib/**/*.sh tests/test_*.sh
PYTHONPATH=lib/python python3 -m compileall -q lib/python hooks tests
git diff --check
```

Expected: exit 0.

- [ ] **Step 8: Run the complete suite once on the stable fingerprint**

```bash
git diff --binary HEAD | sha256sum
bash tests/run.sh
```

Expected: `failed=0`. Record command, exit status, and fingerprint in the task ledger; do not rerun unless executable inputs change.

- [ ] **Step 9: Refresh durable documentation evidence**

Update the iwiki task page with per-task commits, focused checks, final fingerprint, full-suite result, and any effective LLD correction. Because Bash/Python symbols changed, rebuild/publish the code graph using the active iwiki transport, then run `wiki_lint` and resolve task-page findings.

- [ ] **Step 10: Commit I5/I6 and final reconciliation**

```bash
git add manifests/tests.json tests/test_concurrency.sh lib/store/lockfile.sh lib/cli/commands.sh lib/python/ihar/jsonio.py tests/run.sh tests/test_lockfile.sh tests/test_lifecycle.sh tests/test_gateway_explicit.sh tests/test_contracts.sh docs/lld/unified-harness.md
git commit -m "test(concurrency): prove final LLD invariants"
```

- [ ] **Step 11: Run result gate before branch finishing**

Invoke `$check-chain result docs/superpowers/plans/2026-09-20-lld-conformance-remediation.md`. Fix `needs_work` findings without changing approved intent/spec; if implementation evidence contradicts either, return to the earliest affected gate.
