---
review:
  intent_hash: d21d7719748e2853
  last_run: 2026-09-22
  phases:
    structure: { status: passed }
    completeness: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
    alignment: { status: passed }
  findings: []
workflow:
  route: chain
  continuation: full
---

# Intent: codex-auth-claude-runtime-recovery

**Date:** 2026-09-21
**Status:** approved

## Objective

Restore Codex and Claude launches through ihar after the observed authentication and runtime-home drift failures, and prevent the same failures from recurring on later logins or changes in available MCP destinations. The current failure is urgent because device authorization succeeded but Codex still cannot launch, while Claude rejects a runtime whose effective MCP selection or vendor-owned settings changed.

## Desired Outcomes

- An authenticated user can launch both installed Codex and Claude through ihar in the project without a false runtime-drift refusal.
- A subsequent Codex login preserves the user's credentials in the intended persistent owner and leaves the runtime-home link contract valid; login does not strand the only credential copy in a runtime home.
- Changing which configured MCP servers are available selects a correct immutable runtime generation; an existing generation is neither silently rewritten nor reused with different rendered MCP content.
- Vendor-owned, non-security settings changes do not cause a false drift refusal, while changes to ihar-managed hooks, policy, or security assets still fail closed.

## Health Metrics

- No loss, overwrite, disclosure, or accidental migration of existing Codex or Claude credentials and session state.
- No weakening of fail-closed checks, runtime isolation, hook integrity, or conformance gates.
- No regression in launches with unchanged effective configuration, and no security regression in protected or isolated profiles.

## Strategic Context

- Interacts with: Codex, Claude, and the human user who completes authentication. ihar's shared store, immutable runtime homes, MCP renderer, and mutable-link inventory are the affected boundaries.
- Priority trade-off: reliability and protection take precedence over installation or launch speed and implementation cost.

## Constraints

### Steering (behavioral guidance)

- Prefer the smallest change that repairs the observed failures and keeps the existing effective protections.
- Update the LLD when a verified implementation clarifies or improves its prior runtime or authentication contract.

### Hard (architectural enforcement)

- Do not delete or overwrite existing credentials, session state, or runtime homes when ownership or quiescence is uncertain.
- Retain fail-closed behavior for real drift and tampering; do not make managed security content writable merely to avoid the refusal.
- Keep authentication as a human action. Never read credential payloads into logs, documentation, test output, or agent context.
- Preserve immutable-generation semantics: a changed effective render must not mutate a published generation.

## Autonomy Zones

- Full autonomy (reversible, low risk): inspect non-secret metadata, diagnose, write tests and code, update documentation, and run focused and regression checks.
- Guarded (log + confidence threshold): create and verify a new runtime generation or recovery mechanism after proving its inputs and existing data ownership; reconcile a new Codex credential file produced by an ihar-launched vendor process only when its sole owner, destination, and consumer quiescence are proven, preserving the prior version until durable publication succeeds.
- Proposal-first (needs approval): move or replace any pre-existing or ambiguously owned credential file, including the materialised Codex `auth.json` currently preserved in a runtime home.
- No autonomy (human only): complete vendor account login, disclose or select account credentials, or weaken fail-closed protection.

## Stop Rules

- Halt if credential ownership, an active runtime consumer, or the expected destination cannot be established without ambiguity.
- Escalate if repair risks loss or disclosure of credentials or session state, if quiescence cannot be proven, or if a required security check would need weakening.
- Done when both vendor launches work through ihar without false drift, repeated Codex authentication retains usable credentials, changed MCP availability produces a correct immutable generation, and focused plus relevant security regression checks pass without data loss or relaxed enforcement.
