---
review:
  spec_hash: c6599c6ef5e2395c
  last_run: 2026-09-22
  phases:
    structure: { status: passed }
    coverage: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
  findings: []
chain:
  intent: docs/superpowers/intents/2026-09-21-codex-auth-claude-runtime-recovery-intent.md
---

# Design: Codex authentication and Claude runtime recovery

**Date:** 2026-09-22
**Status:** draft

## Context and decision

The installed Codex 0.154.0 completed device authorization but left a materialized `auth.json` in a runtime home; the next ihar launch correctly refused the broken mutable-link contract. Claude refused `mcp/ihar.json` after environment-dependent MCP selection changed without selecting a new runtime generation, and refused `settings.json` after Claude added the non-security `theme` key. These are distinct failures. No existing credential payload or runtime home is an automatic repair input.

One Codex sign-in must serve every project and profile. The canonical credential owner remains `$IHAR_STORE/auth/codex/auth.json`; runtime homes retain a verified link to it. The credential writer is exclusive across ihar-managed Codex processes and the managed app-server daemon. This intentionally favors credential integrity over concurrent independent Codex runtimes. Claude is not subject to the Codex lease.

The rejected alternatives are independent per-runtime logins, because they violate the shared-login requirement; OS keyring as the sole owner, because the isolated guest cannot use the host keyring and availability is not assured; and parallel credential snapshots with compare-and-swap, because concurrent refresh may invalidate one snapshot's refresh token even when both byte copies are preserved. The pinned Codex file backend writes `CODEX_HOME/auth.json`; known app-server refresh races make parallel writers an unsafe assumption.

## Requirements and boundaries

### R1. Shared Codex credential owner

The existing store auth path remains the sole durable credential source for ordinary Codex launches. A normal runtime must contain the declared link, never a silently accepted materialized substitute. Store preparation, install, update, runtime reuse, and `ihar check` must continue to reject unsafe source topology and wrong runtime targets without deleting or overwriting bytes. The already materialized runtime file is preserved and reported as requiring a separate user-approved recovery action.

An ihar-managed Codex authentication command uses an owner-controlled, mode-0700 service/staging `CODEX_HOME` with a real `auth.json`, not the runtime symlink. Only authentication verbs run in this home; ordinary sessions, hooks, and managed policy do not move there. A successful first login may publish a new file to the canonical owner after provenance and quiescence checks. When the canonical file already exists, re-authentication stages a new result and requires explicit human approval before replacement; the prior bytes remain recoverable until durable publication is verified. A vendor-side account action may invalidate a prior token remotely, which byte preservation cannot prevent; the re-authentication prompt must state this limit. An absent, failed, or interrupted authentication must not replace the canonical owner.

### R2. Exclusive active Codex auth writer

Before any Codex process that may load or refresh credentials starts, ihar obtains one global auth-owner lease. The lease covers ordinary CLI, ACP, managed daemon/web, and isolated guest operation, not just the foreground shell process. Clients attached to the same verified managed daemon share that daemon's owner; an independent process, different runtime generation, or guest cannot become a second writer while the owner remains live. A surviving daemon retains ownership after its initiating CLI exits. A new launch must wait within a documented bound or return a specific busy diagnostic, not bypass the lease. The lease cannot be released until the exact owner and plausible children are quiescent. Unknown process identity, external/opaque consumer, or unverifiable quiescence fails closed.

Auth-link verification still applies before launch and after an owner exits. An unexpected materialized file, changed canonical source topology, or incomplete publication is preserved as evidence and blocks another writer. The lease is not a substitute for the existing runtime integrity, receipt, hook-trust, conformance, or profile gates.

### R3. Isolated guest and recovery

The microVM receives a private credential copy only while it owns the global lease. Its guest credential output is returned to the host only after guest shutdown and authenticated bundle ownership, nofollow topology, source-version, and quiescence checks. A changed guest credential is published to the same canonical owner through a recoverable transaction; a failed check retains the guest/recovery bytes and blocks reuse without exposing the payload in diagnostics. A crash must not erase the only newer credential copy. A missing or ambiguous guest output never becomes an implicit logout.

An existing materialized runtime credential, including the observed Codex file, is never adopted by R1-R3 automatically. Its recovery requires a separate user-approved proposal after safe ownership and consumer checks. No credential payload is read into logs, documentation, test output, or agent context.

### R4. Effective MCP runtime identity

Before selecting a runtime generation, both launch and `ihar check --diff` derive the same deterministic effective MCP identity from the validated registry, selected profile, presence of required environment variables, and resolved non-secret values that affect managed render content. Secret values are excluded. The identity is included in the generation hash for both vendors. It is computed before runtime-path-dependent rendering so it cannot depend on its own generation path. A changed selected server set or relevant endpoint creates a new immutable generation; an unchanged identity reuses the existing one. The final rendered bytes and identity are verified together, and no published generation is rewritten to accommodate an environment change.

### R5. Claude settings ownership

Claude's `settings.json` has an ihar-managed projection and explicitly classified vendor-owned fields. Hooks, sandbox, and `_iharGateway` must match the desired managed projection exactly; their deletion or alteration is drift. The observed top-level `theme` field is vendor-owned and may vary without selecting a new generation or causing drift. Unknown additional fields are not silently trusted: diagnostics name the field without its value, and launch remains fail-closed until it is classified. Managed settings remain read-only under enforced profiles; this requirement does not make security content writable.

### R6. Diagnostics, compatibility, and documentation

`ihar check --diff` and launch use one comparison model and report whether a failure concerns a credential owner/lease, mutable link, effective MCP identity, known vendor-owned setting, or managed-setting drift. No diagnostic prints credential data or environment values. Authentication routing preserves the user's existing `ihar codex -- login ...` entry point while keeping account authorization human-only. Existing `ihar claude`, `ihar codex`, daemon, ACP, web, and isolated paths must either satisfy these rules or fail with an explicit bounded reason; none may silently fall back to an unprotected credential owner.

The LLD must be updated to describe the verified shared-login owner, lease/daemon lifetime, authentication staging and human checkpoint, guest return, effective MCP hash, and Claude settings projection. An LLD statement that conflicts with verified safer behavior is revised; unrelated architecture is unchanged.

## Failure handling and human checkpoints

Publication of a newly created, uniquely owned credential may run under the approved guarded autonomy only after proving destination, owner, and quiescence and preserving the prior version until durability is established. Replacement of any pre-existing credential requires a human checkpoint. Ambiguous provenance, competing writers, opaque active consumers, unsafe ancestry, source mutation, unavailable atomicity, or incomplete rollback stops automatic work and retains every recoverable copy. In particular, this design does not authorize moving the observed materialized runtime `auth.json`.

The implementation plan must include a separate checkpoint before any live credential recovery and must not require a user to disclose a token. Vendor account login itself remains a human action. Tests use fabricated credentials only. Recovery and lease metadata may contain paths, hashes, process identities, and states, but no token bytes.

## Verification design

Focused tests first reproduce the current failures with fake vendor binaries: login replaces or deletes a runtime auth link; a surviving daemon holds the auth owner; competing profiles cannot write concurrently; a crashed guest retains changed auth; changing `requires_env` selection changes generation; Claude adds `theme`; managed settings are tampered with. Success requires the expected new generation or safe launch in the benign cases and unchanged bytes plus a specific refusal in conflict cases.

Regression tests cover mutable-link topology, state migration/quiescence, CLI/ACP/web/daemon launch paths, isolated bundle cleanup, `ihar check --diff`, MCP golden renders, and settings tamper checks. The final stable source state receives the full suite once. Live validation uses metadata-only status and human-run account authorization; it never prints a credential payload. The observed pre-existing Codex materialized file cannot be used for a live success claim until its separate recovery checkpoint is approved and completed. No test pass alone substitutes for observing both vendor launches and the intended Codex re-authentication behavior.

## Acceptance (from intent)

### Desired Outcomes

- An authenticated user can launch both installed Codex and Claude through ihar in the project without a false runtime-drift refusal.
- A subsequent Codex login preserves the user's credentials in the intended persistent owner and leaves the runtime-home link contract valid; login does not strand the only credential copy in a runtime home.
- Changing which configured MCP servers are available selects a correct immutable runtime generation; an existing generation is neither silently rewritten nor reused with different rendered MCP content.
- Vendor-owned, non-security settings changes do not cause a false drift refusal, while changes to ihar-managed hooks, policy, or security assets still fail closed.

### Done when

Both vendor launches work through ihar without false drift, repeated Codex authentication retains usable credentials, changed MCP availability produces a correct immutable generation, and focused plus relevant security regression checks pass without data loss or relaxed enforcement.
