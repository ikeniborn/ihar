---
review:
  intent_hash: acd6eb25f2d9d7b0
  last_run: 2026-09-19
  phases:
    structure:   { status: passed }
    completeness:{ status: passed }
    clarity:     { status: passed }
    consistency: { status: passed }
    alignment:   { status: passed }
  findings:
    - id: F-001
      phase: alignment
      severity: WARNING
      section: Stop Rules
      section_hash: null
      fragment: "never weaken the profile and never drop it unilaterally"
      text: "The wiki plan's risk register and phase-gate table read as if a failing gate drops a profile automatically, which contradicts the intent making that the user's decision."
      fix: "Reword the plan's Risk register and Phase gates sections to state that a fallback is proposed and the drop is decided by the user."
      verdict: fixed
      verdict_at: 2026-09-18
workflow:
  route: chain
  continuation: execute
result_check:
  verdict: OK
  source: intent
  intent_hash: acd6eb25f2d9d7b0
  last_run: 2026-09-19
  reviewed: true
  docs_checked: true
---
# Intent: unified-harness-implementation

**Date:** 2026-09-18
**Status:** approved

## Objective

Two wrappers, `iclaude` and `icodex`, each own a per-project config home, a hook layer, an MCP registry and a PII proxy for one vendor. The layers have drifted: the hook scripts differ by hundreds of lines, `icodex` masks only the API-key path so subscription traffic leaves unmasked, and neither can list or continue the other's sessions. Every new policy is implemented twice and lands differently twice.

`ihar` replaces both with one vendor-neutral control and security plane that owns the environment both native agents run in, so that adding an agent costs an adapter and renderers rather than a second copy of security, sessions, handoff, MCP and project isolation.

Now, because the design is complete and reviewed: the HLD is at revision 2, the LLD at revision 3 after an external architecture review of 9 P0, 11 P1 and 5 P2 findings, and the implementation is decomposed into 87 tasks across 13 phases with five gates. The contracts are frozen; nothing is blocked on further design.

## Desired Outcomes

Observable states, each checked by running the real thing rather than by a green test:

- One command launches either agent in the same project with the same hooks, MCP servers and skills: `ihar claude` and `ihar codex` in one repository produce two sessions whose enforcement is identical and whose configuration came from one manifest.
- `ihar sessions` lists both vendors' sessions for the project in one table, and `ihar sessions resume <id>` continues any of them with the profile it was started under.
- `ihar switch --to codex` carries the work: the target session begins with the branch, the changed files, the open items and the decisions of the source, and the package is masked before it is written.
- Under the `protected` profile a model request carrying a credential or personal data leaves the machine masked, and a request the gateway cannot parse does not leave at all.
- Under the `protected` profile a hook that denies a command actually prevents it on both vendors, proven against the pinned binaries rather than against a fixture.
- `ihar check` states, per profile, exactly which enforcement points are active and which guarantee holds, including saying plainly that a guarantee is absent.
- A project migrated from `.claude-homes` and `.codex-homes` keeps its transcripts and its login, and the legacy homes are untouched.

## Health Metrics

What must not degrade relative to the two wrappers in use today:

- Launch latency: the time from `ihar claude` to a usable TUI stays within the current `iclaude` launch, gateway start included.
- Vendor sessions remain readable by the vendor's own tooling. `claude --resume` and `codex resume` keep working outside `ihar`, and no vendor state is rewritten by the harness.
- The shared vendor logins keep working across every project home, and no credential is ever copied out of the store or read by the harness.
- Existing hook coverage does not shrink: every path and secret pattern the two wrappers block today is still blocked by the unified hook.
- A failing harness component never silently downgrades protection. Convenience layers degrade, security layers abort.
- Disk: one store plus per-project state, without the 15 GB of untraceable homes `icodex` accumulated.

## Strategic Context

- Interacts with: Claude Code and Codex CLI binaries and their native session stores; the vendor authentication files; MCP servers, including the iwiki servers this project itself uses; the model provider endpoints; Firecracker for the isolated profile; the ACP adapters as an optional surface.
- Replaces: `iclaude` and `icodex`, which stay in service until `protected` has carried daily work.
- People: a single maintainer today, so operability matters more than team process, and a fail-closed abort must always say what to do next.
- Priority trade-off: **trust**. Where correctness of a guarantee conflicts with delivery speed inside a slice, the guarantee wins. This is the same disposition the LLD already encodes as fail-closed security layers.

## Constraints

### Steering (behavioral guidance)

- Implement the slice in the plan, not the slice plus improvements.
- Prefer lifting proven code from `iclaude` and `icodex` over rewriting it, and cite the origin.
- Add no configurability, fallback path or abstraction the present contract does not need.
- Measure vendor behaviour against the pinned binaries; never infer it from memory or from an older version.
- Keep the conversation in Russian and every artifact in English.

### Hard (architectural enforcement)

- The HLD and the LLD are fixed inputs. Code that contradicts them is wrong; changing them is a new revision with approval.
- Security layers are fail-closed, convenience layers are fail-soft, and every code path declares its class.
- The twelve security invariants in `CLAUDE.md` hold without exception, including: no global `bypass_hook_trust`, no mutation of an existing runtime home, no store inside an agent-writable path, no relay of an unrecognised gateway route, no masking without a gateway, and no `hooks: enforced` without a passing conformance record.
- `ihar` never calls a model API itself and never holds a vendor credential.
- One slice, one branch, one worktree, one pull request into `master`; no direct commit to `master`.
- A profile that has not passed its gate is absent from `manifests/profiles/`, never present and weakened.

## Autonomy Zones

- **Full autonomy** (reversible, inside a slice): files, functions, module boundaries within the LLD's named layout, tests, fixtures, commit messages, opening the pull request, wiki subsystem pages, ledger events.
- **Guarded** (do it, log the reasoning): choosing among implementations the LLD leaves open, resolving an open decision from section 20 by measurement, lifting and adapting wrapper code.
- **Proposal-first** (needs approval): any change to an LLD or HLD contract, a new external dependency, a change to the slice table or the plan's phase order, merging a pull request into `master`.
- **No autonomy** (human only): dropping or weakening a security profile, relaxing a security invariant, anything that would make a stated guarantee untrue.

> These zones override subagent-driven-development's continuous-execution default. A task touching a proposal-first or no-go decision is marked HUMAN CHECKPOINT in the plan.

## Stop Rules

- **Halt if** a phase gate cannot be met: the transparent spike fails, the vendor does not honour managed hooks, conformance does not pass on a pinned version, or a guarantee cannot be delivered as written. Report the evidence and wait; never weaken the profile and never drop it unilaterally.
- **Halt if** implementation contradicts the LLD. Return to the document, propose the revision, and wait.
- **Escalate if** a vendor change breaks a contract mid-slice, if two slices are found to need the same unwritten contract, or if a security invariant would have to bend to finish a task.
- **Done when**, per slice: its tests pass, the full suite passes, the gate condition holds if the slice carries one, `ihar check` reports its enforcement points truthfully under every profile including those where they are absent, and the pull request is merged.
- **Done when**, per topic: the four profiles are declarable or explicitly dropped by decision; both vendors launch, resume, fork, list, switch and expose a web surface through one entry point; a real project has been migrated once from the legacy homes with its transcripts and login intact.
