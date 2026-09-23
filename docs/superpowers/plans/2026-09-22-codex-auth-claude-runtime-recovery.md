---
review:
  plan_hash: 85a78a76c93c8f3c
  last_run: 2026-09-22
  phases:
    structure: { status: passed }
    coverage: { status: passed }
    dependencies: { status: passed }
    verifiability: { status: passed }
    consistency: { status: passed }
  findings: []
chain:
  intent: docs/superpowers/intents/2026-09-21-codex-auth-claude-runtime-recovery-intent.md
  spec: docs/superpowers/specs/2026-09-22-codex-auth-claude-runtime-recovery-design.md
result_check:
  verdict: needs_work
  source: plan
  plan_hash: 85a78a76c93c8f3c
  last_run: 2026-09-23
  reviewed: true
  docs_checked: true
---

# Codex Authentication and Claude Runtime Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore shared Codex authentication and both vendors' immutable runtime selection without weakening fail-closed drift checks.

**Architecture:** Keep one store-owned Codex credential file. A continuous guardian acquires global ownership before any ihar-managed Codex executable, supervises preflight, CLI/ACP, daemon, and guest work, and releases only after quiescence and credential reconciliation. Route interactive re-authentication through a protected real-file staging home and human publication checkpoint; permit only the verified sole-owner microVM refresh to publish automatically. Derive runtime identity from effective MCP render and compare Claude settings by explicit ownership.

**Tech Stack:** Bash launcher/tests, Python 3.12 helper modules, JSON/TOML renderers, Linux/macOS process checks, existing ihar lock and runtime-state utilities.

**Spec:** `docs/superpowers/specs/2026-09-22-codex-auth-claude-runtime-recovery-design.md`

## Global Constraints

- The existing materialized Codex runtime `auth.json` and both live runtime homes are read-only inputs until a separate human-approved recovery action.
- Do not log, print, commit, or include credential values in task evidence; use fabricated credentials in tests.
- A second independent Codex credential writer must not start while the first process, managed daemon, or guest is active or cannot be proven quiescent.
- No Codex executable, including hook-trust app-server, check, conformance, install/update, switch, or a version probe, may start before authenticated admission to the continuous owner; no phase releases and reacquires ownership.
- A reusable owner ID or environment marker alone is not authorization. On platforms where descendant and daemon quiescence cannot be proven, Codex operation fails closed.
- Re-authentication replacement of an existing canonical credential and adoption of a materialized or ambiguous file require explicit human approval; `--assume-yes` must not grant it. A verified sole-owner microVM refresh with an unchanged canonical baseline is guarded and may publish automatically.
- Never rewrite a published runtime generation for changed managed content. Keep managed security settings and link checks fail-closed.
- Follow the existing branch `dev-codex-auth-claude-runtime-recovery` in its sibling worktree; never commit to `master`.
- Run syntax and focused tests per task, relevant regression tests after each shared boundary, and one full suite on the final unchanged code state.

## File ownership map

- `lib/python/ihar/render/mcp.py`, `lib/render/hooks.sh`, `lib/state/runtime.sh`, `lib/render/config.sh`, `lib/cli/commands.sh`, `lib/cli/check.sh`: one effective MCP identity used by render, launch, and check.
- `lib/python/ihar/render/claude_compare.py`, `lib/state/runtime.sh`, `lib/cli/check.sh`: one Claude settings projection comparator.
- `lib/python/ihar/codex/auth_owner.py`, new `lib/python/ihar/codex/guardian.py`, `lib/codex/auth.sh`, `ihar.sh`: durable owner state, authenticated guardian control, early command admission, and staged authentication.
- `lib/codex/daemon.sh`, `lib/python/ihar/codex/daemon.py`: daemon lifetime and exact-owner client admission without a second lease.
- `lib/cli/check.sh`, `lib/cli/commands.sh`, `lib/python/ihar/conformance/run.py`, `lib/python/ihar/handoff/distill.py`: protected check, conformance/install/update, and switch paths.
- `lib/sandbox/microvm.sh`: writable guest auth view, guest return, and retained recovery evidence under the same continuous owner.
- `tests/test_codex_auth_lease.py`, `tests/test_daemon.sh`, `tests/test_web.sh`, `tests/test_conformance.py`, `tests/test_handoff.sh`, `tests/test_microvm.sh`: focused proof of every admission boundary. `docs/lld/unified-harness.md` and user docs: verified contract.

### Task 1: Effective MCP identity selects the runtime generation (R4)

**Files:** Modify `lib/python/ihar/render/mcp.py`, `lib/render/hooks.sh`, `lib/state/runtime.sh`, `lib/render/config.sh`, `lib/cli/commands.sh`, `lib/cli/check.sh`; test `tests/test_mcp.sh`, `tests/test_state.sh`, `tests/test_profiles.sh`, `tests/test_lifecycle.sh`.

**Interfaces:** `python3 -m ihar.render.mcp <vendor> <profile> <registry> --identity` prints one lowercase SHA-256 digest of the effective, secret-free render. `ihar_effective_mcp_identity <vendor>` obtains it before `ihar_config_hash`; `ihar_config_hash` takes that digest as its ninth explicit input. `_ihar_claude_runtime_path` and `_ihar_check_config_hash` use the same ninth input.

Core renderer change:

```python
def effective_identity(registry, profile, environment, vendor):
    rendered, _ = (
        render_claude(registry, profile, environment)
        if vendor == "claude"
        else render_codex(registry, profile, environment)
    )
    body = json.dumps(rendered, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(body.encode("utf-8")).hexdigest()
```

Test anchor in `tests/test_mcp.sh` after defining a `requires_env` registry fixture:

```bash
unset IWIKI_REMOTE_TOKEN
without="$(python3 -m ihar.render.mcp codex standard "$REGISTRY" --identity)"
IWIKI_REMOTE_TOKEN=synthetic with="$(python3 -m ihar.render.mcp codex standard "$REGISTRY" --identity)"
[[ "$without" != "$with" ]] || { printf 'effective MCP selection did not change identity\n' >&2; exit 1; }
```

- [ ] Write a failing test in `tests/test_mcp.sh`: toggle a registry server's `requires_env` variable, assert different `--identity` output for both vendors, assert changing only the variable's secret value leaves the digest unchanged, and assert the digest matches a stable render twice.
- [ ] Run `bash tests/test_mcp.sh`; expect the new `--identity` assertion to fail before implementation.
- [ ] Add a pure `effective_identity(registry, profile, environment, vendor)` function in `mcp.py`: call the existing render function, serialize its result deterministically, hash those bytes, and print only the digest for `--identity`. The renderer already retains token names rather than token values; do not add environment-value logging or a second expansion path.
- [ ] Run `bash tests/test_mcp.sh`; expect exit 0.
- [ ] Add a failing generation test in `tests/test_state.sh`: identical registry digest but different `requires_env` presence must select different hashes; changing only a token's value must not. Run `bash tests/test_state.sh`; expect the new assertions to fail.
- [ ] Thread the ninth digest through the launch and check call sites and the Claude runtime-path calculation. Update every eight-argument test call identified by `rg -n 'ihar_config_hash' lib tests`, including `tests/test_profiles.sh`. Compute the digest after profile/state setup but before runtime-path-dependent rendering; keep both vendors' hashes independent. Run `bash tests/test_state.sh`, `bash tests/test_profiles.sh`, `bash tests/test_lifecycle.sh`, and `bash tests/test_mcp.sh`; expect exit 0 and no existing-generation rewrite.
- [ ] Commit the focused change with `feat(runtime): key generations by effective mcp render`.

### Task 2: Classify Claude settings without masking managed drift (R5)

**Files:** Create `lib/python/ihar/render/claude_compare.py`; modify `lib/state/runtime.sh`, `lib/cli/check.sh`; test `tests/test_state.sh` and new `tests/test_claude_compare.py`.

**Interfaces:** `compare_objects(desired: dict, active: dict) -> str | None` returns the first differing field path or `None`; it copies its inputs before removing the allowed active `theme` string. `python3 -m ihar.render.claude_compare <desired-settings> <active-settings>` exits 0 on `None`, else exits 3 and prints only the path. Both launch reuse and `ihar check --diff` call it for `settings.json`.

Core comparison rule:

```python
desired = json.load(open(desired_path, encoding="utf-8"))
active = json.load(open(active_path, encoding="utf-8"))
if "theme" in active and isinstance(active["theme"], str):
    active.pop("theme")
if active != desired:
    return 3
return 0
```

Test anchor in `tests/test_claude_compare.py`:

```python
def test_theme_does_not_hide_hook_tampering(self):
    desired = {"hooks": {"PreToolUse": []}}
    active = {"hooks": {"PreToolUse": ["changed"]}, "theme": "dark"}
    self.assertEqual(compare_objects(desired, active), "hooks.PreToolUse")
```

- [ ] Write directly runnable Python tests with synthetic JSON for exact equality, an added or changed top-level `theme`, modified `hooks`, modified `sandbox`, modified `_iharGateway`, malformed JSON, and an unknown extra key. End the file with `if __name__ == "__main__": unittest.main()` and assert no value appears in diagnostics.
- [ ] Run `PYTHONPATH=lib/python python3 tests/test_claude_compare.py`; expect failure before the comparator exists.
- [ ] Implement the comparator with `json.load`, `isinstance(theme, str)`, top-level-only removal, and recursive key-path reporting that never renders values. Do not whitelist other keys.
- [ ] Route `settings.json` comparisons in `_ihar_runtime_verify` and `_ihar_check_file_matches` through this helper; retain byte comparison for every other rendered file.
- [ ] Run `PYTHONPATH=lib/python python3 tests/test_claude_compare.py`, `bash tests/test_state.sh`, and `bash tests/test_lifecycle.sh`; expect exit 0. Assert a synthetic managed-key edit still returns exit 3 and a `theme` edit does not.
- [ ] Commit with `fix(runtime): distinguish Claude theme from managed drift`.

### Task 3: Build protected Codex credential staging and publication primitives (R1)

**Files:** Create `lib/python/ihar/codex/auth_owner.py`; test new `tests/test_codex_auth_owner.py`. Do not expose a production auth route until Tasks 4-5 install continuous ownership and early admission.

**Interfaces:** `auth_owner.stage(store) -> Path` creates a 0700 real-file `CODEX_HOME` under the protected auth owner. `auth_owner.publish(stage, store, *, approve_existing: bool) -> None` checks nofollow topology, stage provenance, prior-owner identity, and durable rollback before replacing the canonical file. Task 5 consumes these functions behind Task 4's continuous guardian. The helper never prints payload bytes.

Required approval branch (no implicit `--assume-yes`):

```python
if canonical.exists() and not approve_existing:
    raise ApprovalRequired("existing Codex credential requires direct user approval")
if not candidate.is_file() or candidate.is_symlink():
    raise AuthOwnerError("staged Codex credential is not a regular file")
```

Test anchor in `tests/test_codex_auth_owner.py`:

```python
def test_existing_canonical_needs_approval(self):
    canonical = self.store / "auth" / "codex" / "auth.json"
    canonical.write_text("synthetic-old", encoding="utf-8")
    staged = stage(self.store)
    (staged / "auth.json").write_text("synthetic-new", encoding="utf-8")
    with self.assertRaises(ApprovalRequired):
        publish(staged, self.store, approve_existing=False)
    self.assertEqual(canonical.read_text(encoding="utf-8"), "synthetic-old")
```

- [ ] Write tests for first login with an absent canonical file, failed login leaving it absent, re-login preserving existing bytes until approval, `--assume-yes` not authorizing replacement, symlinked parents, source mutation, publication interruption, and retained recovery bytes. Use synthetic credential strings only.
- [ ] Run `PYTHONPATH=lib/python python3 tests/test_codex_auth_owner.py`; expect failure because the owner helper does not exist.
- [ ] Implement staging with nofollow directory checks, owner-only permissions, a one-use stage marker, fsync of staged file and parent, and an atomic publish/rollback path. Never log content. A result with no regular `auth.json` is a failed login, not logout.
- [ ] Run `PYTHONPATH=lib/python python3 tests/test_codex_auth_owner.py`; expect exit 0, including a fake-vendor staging test that deletes and recreates `auth.json` while a separate synthetic runtime link remains unchanged.
- [ ] Commit with `feat(auth): stage Codex login outside runtime homes`.

### Task 4: Create the continuous guardian and authenticated admission channel (R2)

**Files:** Create `lib/python/ihar/codex/guardian.py`; modify `lib/python/ihar/codex/auth_owner.py`; test `tests/test_codex_auth_lease.py`. This task does not expose a new production launch path.

**Interfaces:** `guardian.run(store: Path, argv: list[str]) -> int` enables Linux child-subreaper supervision, acquires one pending owner record under the existing 0700 store lock, starts a guarded child with one inherited socket descriptor, and retains ownership until all registered work is quiescent. For a foreground command it returns the child's status after quiescence; if a verified daemon survives, it reports the initiating command's status to its caller while the guardian process remains alive and holds the record. `guardian.request(fd: int, operation: str, fields: dict) -> dict` sends bounded control messages over that descriptor. The guardian authenticates the connected descriptor and process identity, not an environment marker or owner ID, before `bind-runtime`, `bind-child`, `bind-daemon`, `register-guest`, or `release`. The record includes guardian PID/start identity, child/daemon/guest identities, runtime/hash once known, and a `pending|active|quiescing|blocked` state; it contains no credential bytes. Existing schema-1 records remain blocking until their original writers are proven gone. Unsupported supervision platforms return exit 3 rather than using an unlocked fallback.

Test anchor in `tests/test_codex_auth_lease.py`:

```python
def test_spoofed_guard_environment_cannot_bind_owner(self):
    with self.assertRaises(AuthOwnerError):
        guardian.request(-1, "bind-runtime", {"runtime": str(self.runtime_a)})
    self.assertEqual(self.owner_record.read_bytes(), self.original_record)
```

- [ ] Add failing synthetic tests for one pending owner before child start, a second guardian busy within two seconds, a forged descriptor/marker, PID reuse, an opaque external Codex consumer, guardian crash with live descendant, daemon or guest identities surviving the initiating shell, and a previous schema-1 record. Run `PYTHONPATH=lib/python python3 tests/test_codex_auth_lease.py`; expect only the new cases to fail.
- [ ] Implement the bounded control protocol and durable owner state in `guardian.py` and `auth_owner.py`. Create the record before `subprocess.Popen`; use an inherited socketpair descriptor for the guarded child and process-identity checks for control requests. Retain the blocking record on any ambiguous crash; never unlink solely because the guardian PID disappeared.
- [ ] Run `PYTHONPATH=lib/python python3 tests/test_codex_auth_lease.py`; expect the new owner, spoof, crash, and stale-record cases to pass. Run `python3 -m compileall -q lib/python/ihar/codex`; expect exit 0.
- [ ] Commit with `feat(auth): add continuous Codex guardian`.

### Task 5: Admit launcher and authentication before preflight Codex starts (R1-R2)

**Files:** Modify `ihar.sh`, `lib/codex/auth.sh`, `lib/cli/commands.sh`, `lib/render/hooks.sh`, `lib/state/runtime.sh`; test `tests/test_codex_auth_lease.py`, `tests/test_lifecycle.sh`, `tests/test_hook_trust.sh`, `tests/test_acp.sh`, `tests/test_console_acp.sh`.

**Interfaces:** After pure configuration and argument parsing, `ihar_main` routes every command that may invoke Codex through `guardian.run` before command dispatch. The guarded re-entry validates the inherited control descriptor; a copied `IHAR_CODEX_GUARD_FD` value without a live authenticated channel is refused. `ihar_codex_auth_command` runs exact `login`, `login status`, and `logout` verbs in Task 3's real-file stage under this same owner; credential publication is requested through the guardian, and direct TTY approval still gates replacement. Runtime seal and trust checks can invoke Codex only in the guarded child. The final CLI/ACP is a supervised child of that owner; no second `acquire` occurs after preflight.

Test anchor in `tests/test_codex_auth_lease.py`:

```python
def test_busy_owner_blocks_prelaunch_app_server(self):
    self.start_existing_owner()
    result = self.run_ihar("--dry-run", "codex")
    self.assertEqual(result.returncode, 3)
    self.assertFalse(self.app_server_start_marker.exists())
```

- [ ] Restore the previously observed RED with a fake `app-server` marker: an occupied owner plus `ihar.sh --dry-run codex` currently starts that marker before admission. Add direct CLI, ACP, login-status, and spoofed-marker variants. Run the focused lease and lifecycle tests; expect the new prelaunch assertions to fail before the fix.
- [ ] Insert the guardian boundary after side-effect-free parsing and before vendor dispatch. Validate re-entry through Task 4's descriptor, not through environment alone. Remove late `ihar_codex_auth_run` acquisition and route all Codex child starts under the original owner, preserving exit status and signal forwarding. If a pre-admission helper cannot be proved vendor-free, move it inside the boundary rather than exempting it.
- [ ] Run `PYTHONPATH=lib/python python3 tests/test_codex_auth_lease.py`, `bash tests/test_lifecycle.sh`, `bash tests/test_hook_trust.sh`, `bash tests/test_acp.sh`, and `bash tests/test_console_acp.sh`; expect exit 0 and no pre-owner Codex marker.
- [ ] Commit with `fix(auth): admit Codex before runtime preflight`.

### Task 6: Keep daemon and attached clients in the original owner (R2)

**Files:** Modify `ihar.sh`, `lib/python/ihar/codex/guardian.py`, `lib/python/ihar/codex/daemon.py`, `lib/codex/daemon.sh`, `lib/cli/commands.sh`; add `lib/python/ihar/codex/remote_sandbox.py`; test `tests/test_codex_auth_lease.py`, `tests/test_daemon.sh`, `tests/test_web.sh`.

**Interfaces:** Daemon start and remote-control setup use Task 4's owner through authenticated control, never a new daemon guardian. When the initiating shell exits, that guardian remains alive while the exact daemon PID/start identity, socket inode, or plausible descendant is active. `guardian.attach(runtime, config_hash, argv, stdio_fds)` uses an owner-only Unix control socket with peer-credential verification and passes standard-I/O descriptors to the original guardian; only that guardian spawns and tracks the attached client. Before vendor exec, `remote_sandbox` creates a Linux user/mount namespace, bind-mounts the verified runtime and canonical auth directory read-only at their original absolute paths, exposes only declared non-credential client state as writable, drops mount capability, and sets `no_new_privs`. It verifies the live runtime link and canonical target only through nofollow identity/read/mount evidence. Write, truncate, replace, unlink, and symlink-replacement probes target fabricated adjacent sentinels created before the read-only remount, never live credential paths. Only after every sentinel mutation is refused may the guardian bind and supervise the exact remote client PID and descendants. Missing namespace support, failed setup/probe, unsupported platform, different generation, or uncertain teardown exits 3 without starting the vendor client. Stop/restart requests go through the same owner and release only after verified daemon quiescence.

Test anchor in `tests/test_codex_auth_lease.py`:

```python
def test_launcher_exit_does_not_release_live_daemon(self):
    self.start_managed_daemon()
    self.assertTrue(self.daemon_process_is_live())
    self.assertEqual(self.run_ihar("--profile", "other", "codex").returncode, 3)
    self.assertFalse(self.second_vendor_start_marker.exists())
```

- [ ] Preserve the review-clean daemon/control subset at `08209e9`. Add failing namespace-boundary tests for launcher exit, same-owner attachment, different generation refusal, guardian crash, remote-control child start, and non-destructive exact-path identity/read/mount checks. Exercise direct write, truncate, rename-over, unlink, and symlink replacement only against fabricated adjacent sentinels; prove the live credential bytes and identities remain unchanged. Test missing namespace support and failed capability drop as exit 3 before the vendor marker. Keep the live PID/socket web fixture; do not weaken production identity checks. Run `PYTHONPATH=lib/python python3 tests/test_codex_auth_lease.py`, `bash tests/test_daemon.sh`, and `bash tests/test_web.sh`; expect new attachment cases to fail before implementation.
- [ ] Add the minimal namespace helper and attach route. The helper must finish mounts and refusal probes, drop mount capability, and set `no_new_privs` before releasing an exec gate. Have the original guardian pass stdio descriptors, register the exact client PID/start identity and plausible descendants, and retain daemon ownership after launcher exit. Do not copy credentials or treat file modes/argv as enforcement. Keep every unverified start, attachment, stop, or teardown outcome blocking.
- [ ] Run the same three focused checks; expect exit 0. Confirm the fake remote client can use the verified daemon socket and declared client-state path but cannot mutate either credential path through any tested filesystem operation. Confirm unsupported enforcement refuses instead of falling back.
- [ ] Commit with `fix(auth): retain owner across Codex daemon lifetime`.

### Task 7: Guard check, conformance, install/update, and switch (R2)

**Files:** Modify `ihar.sh`, `lib/cli/check.sh`, `lib/cli/commands.sh`, `lib/python/ihar/conformance/run.py`, `lib/python/ihar/handoff/distill.py`; test `tests/test_codex_auth_lease.py`, `tests/test_conformance.py`, `tests/test_install.sh`, `tests/test_handoff.sh`.

**Interfaces:** Ordinary check, conformance, install/update, and switch enter Task 4's guardian whenever Codex is installed or the command may invoke it. Admission precedes taking the command's store/install lock; no guarded path acquires these locks in the reverse order. Metadata-only exceptions require a test proving no Codex subprocess; a `--dry-run` flag does not create an exception. Conformance's temporary `CODEX_HOME` remains owner-controlled; after a failure, any materialized or changed `auth.json` is retained in an owner-only recovery directory, not removed by temporary-home cleanup. A Codex-source fork/archive in `ihar switch` is a child of the same guardian. Claude-only work is unaffected.

Test anchor in `tests/test_conformance.py`:

```python
def test_failed_codex_conformance_retains_changed_auth(self):
    result = self.run_failed_codex_case_with_synthetic_auth()
    self.assertNotEqual(result.returncode, 0)
    self.assertTrue(self.recovery_candidate.is_file())
    self.assertEqual(self.canonical.read_bytes(), self.original_canonical)
```

- [ ] Add RED cases with an occupied owner for ordinary `check`, `check --conformance`, install/update conformance, and Codex-source switch: assert no fake Codex start marker and bounded exit 3. Add a failed conformance case that writes a synthetic auth candidate and asserts it survives cleanup. Assert store-lock contention does not invert the guardian-before-store order.
- [ ] Route these entry points through the early guardian boundary, remove unguarded Codex child calls, and retain ambiguous conformance output with nofollow, owner-only recovery topology. Do not revoke old conformance evidence or activate an install generation before admission succeeds. Treat any unproven probe as a guarded Codex invocation.
- [ ] Run `PYTHONPATH=lib/python python3 tests/test_codex_auth_lease.py`, `PYTHONPATH=lib/python python3 tests/test_conformance.py`, `bash tests/test_install.sh`, and `bash tests/test_handoff.sh`; expect exit 0 and unchanged canonical credential bytes in refusal cases.
- [ ] Commit with `fix(auth): guard auxiliary Codex invocations`.

### Task 8: Return isolated guest auth without losing recovery bytes (R3)

**Files:** Extend `lib/python/ihar/codex/auth_owner.py`, `lib/codex/auth.sh`, and `lib/sandbox/microvm.sh`; test `tests/test_microvm.sh` and new `tests/test_codex_auth_guest.py`.

**Interfaces:** The shell requests guest return through Task 4's authenticated channel; only the continuous guardian calls `auth_owner.publish_guest(bundle, baseline, store, owner_id)` for its registered bundle after VM shutdown and quiescence. `bundle_identity_matches(bundle, owner_id)` compares the prelaunch bundle identity with the retained owner record; `publish_verified_refresh(candidate, store, owner_id, expected_baseline)` performs the guarded canonical update. Unchanged guest auth is a no-op. Missing guest auth is not logout. The guest command must reuse the host guardian's channel rather than calling `acquire` again or treating an owner ID as a capability.

Guest return decision table in code:

```python
if vm_is_active(owner_id) or not bundle_identity_matches(bundle, owner_id):
    raise AuthOwnerError("guest ownership or quiescence is unproven")
if not guest_auth.exists():
    raise AuthOwnerError("guest credential missing; canonical owner retained")
if digest(guest_auth) != baseline:
    publish_verified_refresh(guest_auth, store, owner_id, expected_baseline=baseline)
```

Test anchor in `tests/test_codex_auth_guest.py`:

```python
def test_changed_canonical_baseline_preserves_guest_candidate(self):
    self.canonical.write_text("synthetic-other-writer", encoding="utf-8")
    with self.assertRaises(AuthOwnerError):
        publish_guest(self.bundle, self.original_baseline, self.store, self.owner_id)
    self.assertTrue(self.guest_candidate.is_file())
    self.assertEqual(self.canonical.read_text(encoding="utf-8"), "synthetic-other-writer")
```

- [ ] Write fake-VM tests for the current read-only policy image refusing credential writes, then for a separate writable credential view; unchanged auth, one changed synthetic auth file, missing guest file, symlink substitution, changed canonical baseline, active Firecracker process, failed publication, crash before return, and an occupied owner blocking guest start before Firecracker. Assert retained bundle/recovery path is owner-only and no secret appears in output.
- [ ] Run `PYTHONPATH=lib/python python3 tests/test_codex_auth_guest.py` and `bash tests/test_microvm.sh`; expect the new assertions to fail.
- [ ] Reuse the original guardian through bundle registration, Firecracker start, guest shutdown, extraction, and publication; remove the guest's second `acquire` and any ID-only handoff. Stage Codex auth in an owner-only directory copied into the writable state image, not the read-only policy image. Rewrite only the guest Codex `auth.json` link to that writable mount; keep guest `config.toml`, hooks, policy, and store assets read-only. Register bundle identity before guest start. After the guest command, flush and shut down the guest; only after verified Firecracker exit extract the auth candidate from the retained state image with `debugfs`, validate it, and then permit bundle cleanup. Do not use the live SSH/rsync state transfer as auth-publication evidence. Keep the global owner until validation finishes. `publish_verified_refresh` must recheck the canonical baseline while holding the owner lock, retain the prior version durably, and publish only this owner's changed guest result. Reuse the transaction primitive from Task 3 without treating this as human approval for re-authentication; never treat guest absence as a request to delete canonical auth.
- [ ] Run `PYTHONPATH=lib/python python3 tests/test_codex_auth_guest.py`, `bash tests/test_microvm.sh`, and `bash tests/test_state.sh`; expect exit 0. Simulated crash and ambiguous ownership must preserve the candidate file and block a new writer.
- [ ] Commit with `feat(auth): reconcile isolated Codex credentials safely`.

### Task 9: Align LLD, diagnostics, and observable contract (R1-R6)

**Files:** Modify `docs/lld/unified-harness.md`, `README.md`, `docs/README.ru.md`, `lib/cli/check.sh`, `lib/python/ihar/check_result.py`, and relevant test manifest entries; test `tests/test_contracts.sh`, `tests/test_mcp.sh`, `tests/test_state.sh`, `tests/test_lifecycle.sh`.

**Interfaces:** `ihar check --diff` reports selected runtime generation and bounded reason categories without credential or environment values. User docs distinguish staged login, busy owner, approved re-authentication, and existing materialized-file recovery.

- [ ] Add contract tests for diagnostic categories, no secret values, and a safe message for the already materialized runtime credential. Run `bash tests/test_contracts.sh`; expect new assertions to fail.
- [ ] Implement diagnostic rendering using the same MCP identity and Claude comparator as Tasks 1-2, and the same auth-owner state as Tasks 3-5. Do not create a second independent drift calculation.
- [ ] Update LLD §§2.3-2.4, 4.2-4.3, 5.5, 7, and 9 to match observed final behavior. Replace the pending-implementation note only after Tasks 4-8 pass; document the continuous guardian, no handoff, fail-closed unsupported paths, human checkpoints, recoverable guest return, and known `theme` exception. Update English and Russian user instructions; do not describe the proposed behavior as shipped until corresponding tests pass.
- [ ] Reconcile the existing iwiki Given-When-Then scenarios with the corrected guardian behavior and add only newly observable cases; the prelaunch-refusal scenario is already declared. Use `wiki_spec_context` before changing any existing scenario. Preserve declared selectors; defer resolution until Task 10 confirms the hosted graph contains this branch's code changes, or record `graph_unavailable` if publication cannot complete.
- [ ] Run `bash tests/test_contracts.sh`, `bash tests/test_mcp.sh`, `bash tests/test_state.sh`, and `bash tests/test_lifecycle.sh`; expect exit 0. Run documentation structure/lint checks and bound `wiki_lint` after the Wiki update.
- [ ] Commit with `docs(lld): record shared auth and runtime identity contract`.

### Task 10: Integration and human checkpoint (R1-R6)

**Files:** No new source file by default; only fix a reproducible failure in the owning task's file and rerun its focused check. Record commands, exits, and repository revision in the iwiki task page.

- [ ] Run `bash -n ihar.sh lib/cli/commands.sh lib/cli/check.sh lib/render/hooks.sh lib/render/config.sh lib/state/runtime.sh lib/codex/auth.sh lib/codex/daemon.sh lib/sandbox/microvm.sh` and `python3 -m compileall -q lib/python/ihar`; expect exit 0.
- [ ] Run the relevant auth, daemon, web, conformance, install, handoff, microVM, state, MCP, lifecycle, contract, and Claude comparison tests; expect exit 0. If one fails, diagnose and fix that narrow boundary before broad reruns.
- [ ] Run `bash tests/run.sh` once on the final stable code fingerprint; expect `failed=0` and record command, exit status, and revision. Do not describe focused evidence as a full-suite pass.
- [ ] Perform a separate deep integration review of the first possible Codex start, continuous owner and authenticated control, daemon lifetime, check/conformance/install/switch, guest return, credential durability, and rollback. A finding returns to the owning task and invalidates only affected checks.
- [ ] Refresh the ihar code graph after Python/Bash symbol changes: use `wiki_code_index` only if the active bound MCP server has the checkout; for hosted HTTP publish the checked-out snapshot using `wiki_code_publish_begin`, bounded batches, and finalize, respecting server-advertised limits. Verify `wiki_code_status` is ready/fresh/session-bound, then run `wiki_spec_resolve` for the new scenarios and `wiki_lint`. If the graph is unavailable, record `graph_unavailable` rather than inventing resolved bindings.
- [ ] **HUMAN CHECKPOINT:** Present a metadata-only proposal for the observed materialized Codex `auth.json`; obtain separate approval before any live move or replacement. Without approval, retain the file and report live Codex restoration as pending, regardless of synthetic-test results.
- [ ] After approval and safe recovery, ask the user to complete account authorization if needed; then observe `ihar codex -- login status`, `ihar codex`, `ihar claude`, repeated auth behavior, and `ihar check --diff` without printing credentials. Stop on any ambiguity.
- [ ] Run `$check-chain result docs/superpowers/plans/2026-09-22-codex-auth-claude-runtime-recovery.md`; reconcile each intent outcome, health metric, and `Done when` criterion before branch finishing or PR.
