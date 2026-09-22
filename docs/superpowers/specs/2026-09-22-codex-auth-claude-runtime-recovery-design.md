---
review:
  spec_hash: c90da10c220af852
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

Before the first ihar-managed Codex executable can start, one global, long-lived auth guardian obtains the owner record. It remains the same owner throughout prelaunch materialisation, managed-hook seal and verification, foreground CLI or ACP, daemon/web startup and lifetime, and isolated guest return. No phase releases the record for another process to reacquire it; there is no ownership handoff gap. Only a control channel bound to that guardian may admit its child work. An environment variable or reusable owner ID alone is not authorization. Clients attached to the exact verified managed daemon participate in its owner, while an independent process, different generation, or guest is refused. A surviving daemon retains the guardian after its initiating CLI exits. A new independent launch waits no more than two seconds or returns the busy diagnostic.

All ihar entry points that can invoke Codex share this admission boundary: ordinary launch, login/logout/status, ACP, web/daemon control, runtime seal and trust verification, `ihar check`, `ihar check --conformance`, install/update conformance, and Codex fork/archive during `ihar switch`. A read-only check or dry-run may proceed without ownership only when its path is proven not to start any Codex executable; if proof is unavailable it must acquire ownership or fail closed. Install/update conformance uses its staged home only under the same owner; if that home contains a possible newer credential after a failure, cleanup retains it for reconciliation instead of deleting it. No version probe, subprocess, or alternate `CODEX_HOME` may silently bypass admission.

The guardian releases ownership only after its exact Codex process identities, plausible descendants, managed daemon socket/process, and guest process are proven quiescent, and any guest credential candidate is durably reconciled or retained. The guardian's premature exit leaves a durable blocking record; it does not imply release. PID reuse, a missing process table, an untrusted daemon identity, an external/opaque consumer, and uncertain quiescence all fail closed. A stale record may be cleared only after protected evidence proves the old owner and its plausible writers are gone. The lease is global across ihar-managed launches, not a claim that ihar controls arbitrary external Codex processes.

Auth-link verification still applies before launch and after an owner exits. An unexpected materialized file, changed canonical source topology, or incomplete publication is preserved as evidence and blocks another writer. The lease is not a substitute for the existing runtime integrity, receipt, hook-trust, conformance, or profile gates.

### R3. Isolated guest and recovery

The microVM receives a private credential copy only while the continuous host guardian owns the global lease. Guest creation, Firecracker lifetime, guest shutdown, and credential return remain within that one ownership interval. Its guest credential output is returned to the host only after verified guest shutdown and authenticated bundle ownership, nofollow topology, unchanged canonical baseline, and quiescence checks. A changed guest credential generated by that sole verified owner may be published automatically to the same canonical owner through a recoverable transaction; the previous version remains recoverable until durability is proven. A failed check retains the guest/recovery bytes and blocks reuse without exposing the payload in diagnostics. A crash must not erase the only newer credential copy. A missing or ambiguous guest output never becomes an implicit logout.

An existing materialized runtime credential, including the observed Codex file, is never adopted by R1-R3 automatically. Its recovery requires a separate user-approved proposal after safe ownership and consumer checks. No credential payload is read into logs, documentation, test output, or agent context.

### R4. Effective MCP runtime identity

Before selecting a runtime generation, both launch and `ihar check --diff` derive the same deterministic effective MCP identity from the validated registry, selected profile, presence of required environment variables, and resolved non-secret values that affect managed render content. Secret values are excluded. The identity is included in the generation hash for both vendors. It is computed before runtime-path-dependent rendering so it cannot depend on its own generation path. A changed selected server set or relevant endpoint creates a new immutable generation; an unchanged identity reuses the existing one. The final rendered bytes and identity are verified together, and no published generation is rewritten to accommodate an environment change.

### R5. Claude settings ownership

Claude's `settings.json` has an ihar-managed projection and explicitly classified vendor-owned fields. Hooks, sandbox, and `_iharGateway` must match the desired managed projection exactly; their deletion or alteration is drift. The observed top-level `theme` field is vendor-owned and may vary without selecting a new generation or causing drift. Unknown additional fields are not silently trusted: diagnostics name the field without its value, and launch remains fail-closed until it is classified. Managed settings remain read-only under enforced profiles; this requirement does not make security content writable.

### R6. Diagnostics, compatibility, and documentation

`ihar check --diff` and launch use one comparison model and report whether a failure concerns a credential owner/lease, mutable link, effective MCP identity, known vendor-owned setting, or managed-setting drift. No diagnostic prints credential data or environment values. Authentication routing preserves the user's existing `ihar codex -- login ...` entry point while keeping account authorization human-only. Existing `ihar claude`, `ihar codex`, daemon, ACP, web, and isolated paths must either satisfy these rules or fail with an explicit bounded reason; none may silently fall back to an unprotected credential owner.

The LLD must be updated to describe the verified shared-login owner, lease/daemon lifetime, authentication staging and human checkpoint, guest return, effective MCP hash, and Claude settings projection. An LLD statement that conflicts with verified safer behavior is revised; unrelated architecture is unchanged.

## Failure handling and human checkpoints

Publication of a newly created, uniquely owned credential may run under the approved guarded autonomy only after proving destination, owner, and quiescence and preserving the prior version until durability is established. The same guarded rule permits a refresh from the sole verified microVM owner to the existing canonical file only when the canonical baseline is unchanged. Re-authentication replacement of an existing canonical credential and adoption or replacement of any pre-existing materialized or ambiguously owned credential require a human checkpoint. Ambiguous provenance, competing writers, opaque active consumers, unsafe ancestry, source mutation, unavailable atomicity, or incomplete rollback stops automatic work and retains every recoverable copy. In particular, this design does not authorize moving the observed materialized runtime `auth.json`.

The implementation plan must include a separate checkpoint before any live credential recovery and must not require a user to disclose a token. Vendor account login itself remains a human action. Tests use fabricated credentials only. Recovery and lease metadata may contain paths, hashes, process identities, and states, but no token bytes.

## Verification design

Focused tests first reproduce the current failures with fake vendor binaries: login replaces or deletes a runtime auth link; a surviving daemon holds the auth owner; competing profiles cannot write concurrently; an occupied owner blocks a dry-run before managed-hook seal can spawn `app-server`; a crashed guest retains changed auth; changing `requires_env` selection changes generation; Claude adds `theme`; managed settings are tampered with. Success requires the expected new generation or safe launch in the benign cases and unchanged bytes plus a specific refusal in conflict cases. Tests also cover guardian crash and PID reuse, authenticated admission of prelaunch child work, daemon survival after launcher exit, check and conformance refusal under an occupied owner, preservation of a staged conformance credential, Codex fork/archive admission, and no ownership gap through guest return.

Regression tests cover mutable-link topology, state migration/quiescence, CLI/ACP/web/daemon launch paths, isolated bundle cleanup, `ihar check --diff`, MCP golden renders, and settings tamper checks. The final stable source state receives the full suite once. Live validation uses metadata-only status and human-run account authorization; it never prints a credential payload. The observed pre-existing Codex materialized file cannot be used for a live success claim until its separate recovery checkpoint is approved and completed. No test pass alone substitutes for observing both vendor launches and the intended Codex re-authentication behavior.

## Acceptance (from intent)

### Desired Outcomes

- An authenticated user can launch both installed Codex and Claude through ihar in the project without a false runtime-drift refusal.
- A subsequent Codex login preserves the user's credentials in the intended persistent owner and leaves the runtime-home link contract valid; login does not strand the only credential copy in a runtime home.
- Changing which configured MCP servers are available selects a correct immutable runtime generation; an existing generation is neither silently rewritten nor reused with different rendered MCP content.
- Vendor-owned, non-security settings changes do not cause a false drift refusal, while changes to ihar-managed hooks, policy, or security assets still fail closed.

### Done when

Both vendor launches work through ihar without false drift, repeated Codex authentication retains usable credentials, changed MCP availability produces a correct immutable generation, and focused plus relevant security regression checks pass without data loss or relaxed enforcement.
