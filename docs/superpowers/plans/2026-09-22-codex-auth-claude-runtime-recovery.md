---
review:
  plan_hash: b151f5bc9119ce67
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
---

# Codex Authentication and Claude Runtime Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore shared Codex authentication and both vendors' immutable runtime selection without weakening fail-closed drift checks.

**Architecture:** Keep one store-owned Codex credential file and admit one credential writer, including a long-lived daemon or microVM guest, at a time. Route interactive re-authentication through a protected real-file staging home and human publication checkpoint; permit only the verified sole-owner microVM refresh to publish automatically. Derive runtime identity from effective MCP render and compare Claude settings by explicit ownership.

**Tech Stack:** Bash launcher/tests, Python 3.12 helper modules, JSON/TOML renderers, Linux/macOS process checks, existing ihar lock and runtime-state utilities.

**Spec:** `docs/superpowers/specs/2026-09-22-codex-auth-claude-runtime-recovery-design.md`

## Global Constraints

- The existing materialized Codex runtime `auth.json` and both live runtime homes are read-only inputs until a separate human-approved recovery action.
- Do not log, print, commit, or include credential values in task evidence; use fabricated credentials in tests.
- A second independent Codex credential writer must not start while the first process, managed daemon, or guest is active or cannot be proven quiescent.
- Re-authentication replacement of an existing canonical credential and adoption of a materialized or ambiguous file require explicit human approval; `--assume-yes` must not grant it. A verified sole-owner microVM refresh with an unchanged canonical baseline is guarded and may publish automatically.
- Never rewrite a published runtime generation for changed managed content. Keep managed security settings and link checks fail-closed.
- Follow the existing branch `dev-codex-auth-claude-runtime-recovery` in its sibling worktree; never commit to `master`.
- Run syntax and focused tests per task, relevant regression tests after each shared boundary, and one full suite on the final unchanged code state.

## File ownership map

- `lib/python/ihar/render/mcp.py`, `lib/render/hooks.sh`, `lib/state/runtime.sh`, `lib/render/config.sh`, `lib/cli/commands.sh`, `lib/cli/check.sh`: one effective MCP identity used by render, launch, and check.
- `lib/python/ihar/render/claude_compare.py`, `lib/state/runtime.sh`, `lib/cli/check.sh`: one Claude settings projection comparator.
- `lib/python/ihar/codex/auth_owner.py`, `lib/codex/auth.sh`, `lib/cli/commands.sh`, `lib/codex/daemon.sh`, `lib/python/ihar/codex/daemon.py`: protected auth staging, credential publication, writer lease, and daemon ownership.
- `lib/sandbox/microvm.sh`: writable guest auth view separate from the read-only policy image, guest return, and retained recovery evidence under the same owner.
- `tests/test_mcp.sh`, `tests/test_state.sh`, `tests/test_lifecycle.sh`, `tests/test_daemon.sh`, `tests/test_microvm.sh`, new focused Python tests: behavior and tamper evidence. `docs/lld/unified-harness.md` and user docs: verified contract.

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

**Files:** Create `lib/python/ihar/codex/auth_owner.py`; test new `tests/test_codex_auth_owner.py`. Do not expose a production auth route until Task 4 installs the lease.

**Interfaces:** `auth_owner.stage(store) -> Path` creates a 0700 real-file `CODEX_HOME` under the protected auth owner. `auth_owner.publish(stage, store, *, approve_existing: bool) -> None` checks nofollow topology, stage provenance, prior-owner identity, and durable rollback before replacing the canonical file. Task 4 consumes these functions behind an exclusive owner lease. The helper never prints payload bytes.

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

### Task 4: Hold one Codex writer across foreground and daemon lifetimes (R2)

**Files:** Extend `lib/python/ihar/codex/auth_owner.py`; create `lib/codex/auth.sh`; modify `ihar.sh`, `lib/cli/args.sh`, `lib/codex/daemon.sh`, `lib/python/ihar/codex/daemon.py`, `lib/cli/commands.sh`; test new `tests/test_codex_auth_lease.py`, `tests/test_daemon.sh`, `tests/test_acp.sh`, `tests/test_console_acp.sh`, `tests/test_lifecycle.sh`.

**Interfaces:** The auth owner exposes `acquire(runtime, mode)` and `release(owner_id)` through a locked 0700 store metadata directory. `owner_identity_proven(record)` checks PID plus start identity and expected binary; `owner_is_active(record)` includes plausible children and daemon socket identity. A foreground runner retains the lease until its child and plausible descendants are quiescent. A managed daemon has a lease guardian and durable owner record from verified start through verified stop; clients attached to that exact daemon reuse its owner ID, not a second writer slot. If the guardian exits while the daemon remains live, its record causes a refusal, never a second owner. An independent runtime receives a bounded busy refusal.

Required admission predicate under the lock:

```python
if owner is not None:
    if not owner_identity_proven(owner):
        raise AuthOwnerError("Codex auth owner cannot be verified")
    if owner_is_active(owner):
        if attached_daemon_id != owner.daemon_id or runtime != owner.runtime:
            raise AuthBusy("another Codex runtime owns the shared login")
```

Test anchor in `tests/test_codex_auth_lease.py`:

```python
def test_second_runtime_cannot_own_login(self):
    first = acquire(self.runtime_a, "foreground")
    try:
        with self.assertRaises(AuthBusy):
            acquire(self.runtime_b, "foreground")
    finally:
        release(first)
```

- [ ] Write tests for two simultaneous foreground writers, an exited parent with a live child, a long-lived daemon after its CLI exits, an attached client of that daemon, a different profile, stale PID reuse, an unreadable process table, daemon stop/restart, and ACP/console launch. Assert no second independent vendor-start marker appears during ownership.
- [ ] Run `PYTHONPATH=lib/python python3 tests/test_codex_auth_lease.py` and `bash tests/test_daemon.sh`; expect the new assertions to fail.
- [ ] Implement a required OS-backed lock for admission plus an owner record containing only process identity, runtime/config hash, and state. Reuse existing Linux/macOS process-observation logic where possible. Refuse opaque or uncertain liveness; never infer quiescence from a missing shell parent alone.
- [ ] Replace `exec` only for Codex paths needing a supervising owner; preserve vendor exit status and signal behavior. Connect daemon start/reconcile/stop and remote-control start to the same owner. Add `ihar_codex_auth_command` behind this lease: detect exact `login`, `login status`, and `logout` verbs before runtime materialization; run login in Task 3's protected stage; require direct TTY confirmation before re-authentication replaces the canonical file; never let `--assume-yes` grant it. Verify a launched CLI cannot outlive its lease guardian and a daemon cannot lose its owner when the launcher exits.
- [ ] Run `PYTHONPATH=lib/python python3 tests/test_codex_auth_lease.py`, `bash tests/test_daemon.sh`, `bash tests/test_acp.sh`, `bash tests/test_console_acp.sh`, and `bash tests/test_lifecycle.sh`; expect exit 0. Any unresolved child or process-identity uncertainty must be a safe refusal, not an automatic stale-lock deletion.
- [ ] Commit with `feat(auth): enforce one Codex credential writer`.

### Task 5: Return isolated guest auth without losing recovery bytes (R3)

**Files:** Extend `lib/python/ihar/codex/auth_owner.py`, `lib/codex/auth.sh`, and `lib/sandbox/microvm.sh`; test `tests/test_microvm.sh` and new `tests/test_codex_auth_guest.py`.

**Interfaces:** `auth_owner.publish_guest(bundle, baseline, store, owner_id)` accepts only the exact guest bundle registered by the active owner, after VM shutdown and quiescence; it publishes changed regular auth bytes recoverably or retains the bundle and refuses. `bundle_identity_matches(bundle, owner_id)` compares the prelaunch bundle identity with the retained owner record; `publish_verified_refresh(candidate, store, owner_id, expected_baseline)` performs the guarded canonical update. Unchanged guest auth is a no-op. Missing guest auth is not logout.

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

- [ ] Write fake-VM tests for the current read-only policy image refusing credential writes, then for a separate writable credential view; unchanged auth, one changed synthetic auth file, missing guest file, symlink substitution, changed canonical baseline, active Firecracker process, failed publication, and crash before return. Assert retained bundle/recovery path is owner-only and no secret appears in output.
- [ ] Run `PYTHONPATH=lib/python python3 tests/test_codex_auth_guest.py` and `bash tests/test_microvm.sh`; expect the new assertions to fail.
- [ ] Stage Codex auth in an owner-only directory copied into the writable state image, not the read-only policy image. Rewrite only the guest Codex `auth.json` link to that writable mount; keep guest `config.toml`, hooks, policy, and store assets read-only. Register bundle identity before guest start. After the guest command, flush and shut down the guest; only after verified Firecracker exit extract the auth candidate from the retained state image with `debugfs`, validate it, and then permit bundle cleanup. Do not use the live SSH/rsync state transfer as auth-publication evidence. Keep the global owner until validation finishes. `publish_verified_refresh` must recheck the canonical baseline while holding the owner lock, retain the prior version durably, and publish only this owner's changed guest result. Reuse the transaction primitive from Task 3 without treating this as human approval for re-authentication; never treat guest absence as a request to delete canonical auth.
- [ ] Run `PYTHONPATH=lib/python python3 tests/test_codex_auth_guest.py`, `bash tests/test_microvm.sh`, and `bash tests/test_state.sh`; expect exit 0. Simulated crash and ambiguous ownership must preserve the candidate file and block a new writer.
- [ ] Commit with `feat(auth): reconcile isolated Codex credentials safely`.

### Task 6: Align LLD, diagnostics, and observable contract (R1-R6)

**Files:** Modify `docs/lld/unified-harness.md`, `README.md`, `docs/README.ru.md`, `lib/cli/check.sh`, `lib/python/ihar/check_result.py`, and relevant test manifest entries; test `tests/test_contracts.sh`, `tests/test_mcp.sh`, `tests/test_state.sh`, `tests/test_lifecycle.sh`.

**Interfaces:** `ihar check --diff` reports selected runtime generation and bounded reason categories without credential or environment values. User docs distinguish staged login, busy owner, approved re-authentication, and existing materialized-file recovery.

- [ ] Add contract tests for diagnostic categories, no secret values, and a safe message for the already materialized runtime credential. Run `bash tests/test_contracts.sh`; expect new assertions to fail.
- [ ] Implement diagnostic rendering using the same MCP identity and Claude comparator as Tasks 1-2, and the same auth-owner state as Tasks 3-5. Do not create a second independent drift calculation.
- [ ] Update LLD §§2.3-2.4, 4.2-4.3, 5.5, 7, and 9 to match observed final behavior. Document the single-owner concurrency limit, human checkpoints, recoverable guest return, and known `theme` exception. Update English and Russian user instructions; do not describe the proposed behavior as shipped until corresponding tests pass.
- [ ] Add explicit iwiki Given-When-Then scenarios for new observable auth/lease and runtime-generation behavior, with implementation and executable-test bindings. Use `wiki_spec_context` before changing any existing scenario. Preserve declared selectors; defer resolution until Task 7 confirms the hosted graph contains this branch's code changes, or record `graph_unavailable` if publication cannot complete.
- [ ] Run `bash tests/test_contracts.sh`, `bash tests/test_mcp.sh`, `bash tests/test_state.sh`, and `bash tests/test_lifecycle.sh`; expect exit 0. Run documentation structure/lint checks and bound `wiki_lint` after the Wiki update.
- [ ] Commit with `docs(lld): record shared auth and runtime identity contract`.

### Task 7: Integration and human checkpoint (R1-R6)

**Files:** No new source file by default; only fix a reproducible failure in the owning task's file and rerun its focused check. Record commands, exits, and repository revision in the iwiki task page.

- [ ] Run `bash -n ihar.sh lib/cli/commands.sh lib/cli/check.sh lib/render/hooks.sh lib/render/config.sh lib/state/runtime.sh lib/codex/auth.sh lib/codex/daemon.sh lib/sandbox/microvm.sh` and `python3 -m compileall -q lib/python/ihar`; expect exit 0.
- [ ] Run the relevant auth, daemon, microVM, state, MCP, lifecycle, contract, and Claude comparison tests; expect exit 0. If one fails, diagnose and fix that narrow boundary before broad reruns.
- [ ] Run `bash tests/run.sh` once on the final stable code fingerprint; expect `failed=0` and record command, exit status, and revision. Do not describe focused evidence as a full-suite pass.
- [ ] Perform a separate deep integration review of credential durability, writer exclusivity, daemon lifetime, guest return, and rollback. A finding returns to the owning task and invalidates only affected checks.
- [ ] Refresh the ihar code graph after Python/Bash symbol changes: use `wiki_code_index` only if the active bound MCP server has the checkout; for hosted HTTP publish the checked-out snapshot using `wiki_code_publish_begin`, bounded batches, and finalize, respecting server-advertised limits. Verify `wiki_code_status` is ready/fresh/session-bound, then run `wiki_spec_resolve` for the new scenarios and `wiki_lint`. If the graph is unavailable, record `graph_unavailable` rather than inventing resolved bindings.
- [ ] **HUMAN CHECKPOINT:** Present a metadata-only proposal for the observed materialized Codex `auth.json`; obtain separate approval before any live move or replacement. Without approval, retain the file and report live Codex restoration as pending, regardless of synthetic-test results.
- [ ] After approval and safe recovery, ask the user to complete account authorization if needed; then observe `ihar codex -- login status`, `ihar codex`, `ihar claude`, repeated auth behavior, and `ihar check --diff` without printing credentials. Stop on any ambiguity.
- [ ] Run `$check-chain result docs/superpowers/plans/2026-09-22-codex-auth-claude-runtime-recovery.md`; reconcile each intent outcome, health metric, and `Done when` criterion before branch finishing or PR.
