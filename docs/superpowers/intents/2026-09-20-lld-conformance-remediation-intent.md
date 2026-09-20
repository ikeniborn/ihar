---
review:
  intent_hash: f6a6546dd0bb7dd8
  last_run: 2026-09-20
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

# Intent: lld-conformance-remediation

**Date:** 2026-09-20
**Status:** approved

## Objective

Bring `master` into complete, evidence-backed alignment with the unified harness LLD by closing the audited security, fresh-install, state-persistence, asset, CLI, integrity, and verification gaps before further product development.

Alignment is bidirectional: do not regress an effective implementation merely to match stale LLD text. When implementation evidence shows that an existing solution is safer or more effective, preserve it and update the LLD so the documented contract matches the proven behavior.

## Desired Outcomes

- Findings C2 through I6 are closed in the required order or explicitly converted into evidence-backed LLD corrections when the current implementation is the better contract.
- A fresh installation and every declared CLI scenario work from the tracked repository artifacts.
- Isolation and protected-path enforcement are not weakened.
- Claude and Codex persistent state is retained according to the reconciled contract.
- The complete relevant test suite passes, including new coverage for previously untested contracts.
- Code, LLD, tests, and iwiki documentation do not contradict one another.

## Health Metrics

- Fail-closed isolation and protected-path enforcement do not weaken.
- Existing profiles and CLI behavior remain compatible unless an approved contract correction says otherwise.
- User homes, history, and persistent state are not lost.
- Installation remains reproducible from a fresh clone.
- Launch time has no material regression attributable to this remediation.
- The existing 26-of-26 test-file baseline remains green; new contract checks add coverage without replacing it.

## Strategic Context

- Interacts with: `ihar`, the `iclaude` and `icodex` integrations, installer, runtime homes, sandbox hooks, migration framework, public CLI, tests, LLD, and iwiki.
- Priority trade-off: trust, then correctness, compatibility, speed, and cost.

## Constraints

### Steering (behavioral guidance)

- Work in strict order: C2, C1, I2, I1, I3/I4, then I5/I6.
- Keep changes minimal and reproduce or test the relevant behavior before changing it.
- Preserve effective existing solutions; prefer an evidence-backed LLD correction over an implementation regression.
- Show every substantive LLD correction explicitly in the diff and connect it to verified behavior.

### Hard (architectural enforcement)

- Preserve fail-closed quiescence and do not weaken the sandbox or protected-path boundary.
- Do not lose or destructively rewrite user data.
- Do not silently change a public CLI, persistence, installation, migration, or security contract.
- Resolve every code-to-LLD conflict on the correct side using executable evidence.
- Do not commit or merge directly to `master`; delivery uses a development branch and PR.

## Autonomy Zones

- Full autonomy (reversible, low risk): local reversible code, test, and documentation changes inside the approved scope.
- Guarded (log + confidence threshold): migration, persistent-state, and compatibility changes with explicit backup and rollback verification.
- Proposal-first (needs approval): changes to LLD meaning, public CLI contracts, or the security model.
- No autonomy (human only): deleting user data, weakening fail-closed behavior, force-pushing, or committing or merging directly to `master`.

> These zones OVERRIDE subagent-driven-development's "continuous execution,
> don't pause" default. Any task touching proposal-first / no-go decisions
> is marked HUMAN CHECKPOINT in the plan.

## Stop Rules

- Halt if: work introduces credible user-data-loss risk, unexplained isolation weakening, or an unresolved requirement contradiction.
- Escalate if: two materially different strategies fail to resolve the same critical problem.
- Done when: C2 through I6 are reconciled between code and LLD, observable scenarios pass, the regression suite is green, iwiki is current, and delivery is ready to close through a PR.
