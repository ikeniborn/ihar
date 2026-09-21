---
review:
  intent_hash: 71a2153a593a13f9
  last_run: 2026-09-21
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

# Intent: install-hook-conformance-diagnostics

**Date:** 2026-09-21
**Status:** approved

## Objective

Make a first `ihar install` usable when no Claude or Codex authentication exists in the active store. The current installation requires live hook conformance before activation, while a fresh store has no vendor credentials. This prevents installation from completing and hides the failed-case detail. Resolve the bootstrap conflict now because it blocks initial use, without weakening the fail-closed guarantee of enforced profiles. Correct the local project configuration values that currently turn shell-style placeholders into literal filesystem paths.

## Desired Outcomes

- A fresh user can complete the first installation without pre-existing vendor authentication.
- The installed `standard` profile can launch after that first installation, subject to the vendor's own authentication requirements.
- A profile with enforced hooks refuses to launch until the installed vendor version has passed live conformance; an unauthenticated installation never claims that proof.
- After vendor authentication is available, the user can run conformance and then launch an enforced profile when all required cases pass.
- A failed conformance run reports which vendor and required cases failed without exposing credentials or raw vendor output.
- The user's project configuration resolves the store and state roots to the intended absolute paths rather than literal shell placeholders.

## Health Metrics

- Zero enforced-profile launches with missing, stale, incomplete, or failed conformance evidence.
- Zero credential bytes copied into the repository or emitted in installer or conformance diagnostics.
- A failed install or update leaves the previously active generation and receipt unchanged.
- Vendor authentication, transcripts, and mutable state remain owned by their existing locations; no user data is deleted.
- Existing supported `standard` launches and authenticated install/update paths remain operational.

## Strategic Context

- Interacts with: installer and activation transaction, the active store's vendor authentication, Claude and Codex live conformance, profile launch gates, project configuration parsing, tests, LLD, README, and iwiki.
- Priority trade-off: trust and reliability before installation speed or cost.

## Constraints

### Steering (behavioral guidance)

- Keep the bootstrap path minimal and distinguish component installation from live proof in user-facing status and diagnostics.
- Diagnose vendor failures with bounded, non-sensitive case summaries; do not print raw vendor output.
- Use observable first-install, standard-launch, enforced-refusal, and post-authentication scenarios to select and verify the implementation.
- Keep code, tests, LLD, README, and iwiki aligned with the effective behavior.

### Hard (architectural enforcement)

- An unauthenticated first installation may prepare and activate components but must not manufacture, skip, or inherit a successful conformance record.
- An enforced profile must fail closed until the exact installed vendor version and hook manifest pass all required live cases.
- Failed activation must preserve the previous generation and receipt; mutable vendor authentication must not be deleted or moved into the repository.
- Project configuration remains data, not executable shell, and must not evaluate placeholder expressions.
- Do not weaken rules for access to secrets or fail-closed enforcement without a separate explicit user decision.
- Do not commit or merge directly to `master`; deliver tracked changes through the task branch and a PR.

## Autonomy Zones

- Full autonomy (reversible, low risk): edit task-scoped code, tests, documentation, and the user's local project configuration; run isolated checks.
- Guarded (log + confidence threshold): rerun installation and conformance against the local user store after checking the exact target and preserving rollback evidence.
- Proposal-first (needs approval): change rules for access to secrets, weaken fail-closed enforcement, or change vendor authentication ownership.
- No autonomy (human only): expose credential contents, delete user data, force-push, or commit or merge directly to `master`.

## Stop Rules

- Halt if: a proposed bootstrap path would let an enforced profile launch without current successful live proof, expose a credential, or replace a usable generation after a failed transaction.
- Escalate if: the vendor requires an authentication flow that cannot be completed through the current owner-controlled paths, or two distinct diagnostic strategies cannot explain the same failed case.
- Done when: a fresh installation completes without prior vendor credentials; `standard` launches subject to native vendor authentication; enforced launch fails before proof and succeeds only after all required cases pass; failure diagnostics identify the vendor and cases without secrets; rollback, configuration, and relevant regression checks pass.
