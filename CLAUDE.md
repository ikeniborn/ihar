# CLAUDE.md — ihar

`ihar` is a vendor-neutral control and security plane that launches native Claude Code and Codex CLI binaries. It owns configuration, hooks, sandbox, model egress, session metadata and handoff. It is not an agent runtime, not a transcript format, and never calls a model API itself.

These rules add to the global instructions and override them only where stated.

## Authority

Three documents bind the work. They carry decisions already reviewed; code contradicting them re-decides without review.

| Document | Fixes | Change route |
|----------|-------|--------------|
| `docs/hld/unified-harness.md` | architecture, requirements R1–R8 | new HLD revision, user approval |
| `docs/lld/unified-harness.md` | contracts, schemas, algorithms, failure classes | new LLD revision, user approval |
| `ihar/reference/plans/unified-harness-implementation` (iwiki) | phase order, tasks, gates | plan update recorded on the topic |

Read the slice table on iwiki topic `unified-harness-implementation` before starting; record material events per the global task-ledger rule.

**If code and a document disagree, the document wins and the code is wrong.** Never edit a document to match code. If the document is wrong, stop and say so.

**Keep the HLD and the LLD current in the same change that makes them stale.** They bind the work only while they describe it; a document that is six slices behind is read once, found wrong, and then ignored — at which point nothing binds anything. So:

- A slice that resolves an open decision from LLD §20 writes the answer into the section that owned it and removes the entry, in the same commit.
- A slice that measures something the document asserts, and finds it different, corrects the assertion and records the measurement so the next reader sees why. The state layout of revision 4 is the worked example: §2.2 claimed about 90 bytes, the real path was 120, and the section now carries both.
- A slice that changes a contract, a schema, an algorithm or a failure class updates the LLD section and the contract table in §15, and bumps the revision line at the top.
- A slice that changes what a profile guarantees, a requirement, or the shape of the architecture updates the HLD too.
- Correcting a document to match measured reality is not the same as editing it to match code. The first is required; the second is forbidden. The test is whether the code or the world decided: measurement wins, convenience does not.

Both are proposal-first (see the intent's autonomy zones): propose the revision with the evidence, wait, then write it. A pull request that changes behaviour without touching the document that describes it is incomplete.

## Structure

- **Bash 5** — CLI, launcher, state, locks, profiles, adapters, install. `set -euo pipefail` in `ihar.sh`. Public functions `ihar_<area>_<verb>`, private `_ihar_<area>_<verb>`.
- **Python 3.11+** — anything parsing JSON, JSONL, SQLite or TOML, speaking JSON-RPC, or terminating a connection. One package, `lib/python/ihar/`.
- **Hooks are the exception** — system interpreter, stdlib plus `hooks/_shared/` by absolute path, because a hook must run when the venv is broken.
- **No `jq` on a correctness path** — not guaranteed installed, fails quietly. Merge JSON in Python; fail closed when the interpreter is missing.
- **Parse configuration, never source it** — sourcing executes file contents, and `.ihar_config` sits in an agent-writable checkout. Accept `IHAR_[A-Z0-9_]+` lines only; unknown key is exit 2.
- Document every public function's stdout contract and exit code above it.

## Commands

Nothing below `ihar.sh` exists yet; the suite and the CLI land in phases S0 and S2. Until then the only runnable commands are the vendor probes.

Run the whole test suite, and the one file a task touches:

```bash
tests/run.sh
tests/test_state.sh
```

Print the effective profile, every enforcement point and the known gaps:

```bash
ihar check --json
```

Invoke a package module and a hook, the two calling conventions that never vary:

```bash
PYTHONPATH="$IHAR_ROOT/lib/python" "$IHAR_PY" -m ihar.sessions.index
python3 -I hooks/security-pretool.py --vendor codex
```

Read a vendor fact from the pinned binaries rather than from memory:

```bash
.ihar-isolated/bin/codex app-server generate-json-schema --out /tmp/codex-schema
.nvm-isolated/npm-global/bin/claude --help
```

## Failure Classes

Every code path declares one class, named in the function comment and in LLD §17. An undeclared class does not merge: the caller cannot tell whether a failure aborted or was swallowed.

| Class | Behaviour | Exit |
|-------|-----------|------|
| fail-closed | one line on stderr, abort before the vendor starts | 3 |
| usage | print the offending input, abort | 2 |
| runtime | abort naming the failing step | 1 |
| fail-soft | warn, continue | 0 |

**Security layers are fail-closed; convenience layers are fail-soft.** Security: hooks, sandbox, gateway, store integrity, hook trust, conformance, handoff sanitisation. Convenience: session index, telemetry, statusline caches, distiller.

## Contracts

Every JSON contract in LLD §15 carries `schema`, validated by `ihar.jsonio.check` on read and write. An unknown key or wrong type is an error, never a warning — a tolerated key becomes an undocumented contract.

- Add a field and its schema edit in one change, or the write is rejected.
- Convert foreign representations before the check, never after. Codex `createdAt` is int64 Unix seconds, stored as an ISO-8601 string.
- Never reuse a vendor field name whose meaning differs: Codex `Thread.source` is a thread origin, canonical `source` is ihar's provenance. Mapping them corrupts provenance silently.
- The session index holds metadata only — `ihar` does not own transcripts, and a content field would put a second uncontrolled copy outside the vendor store. No message, tool result or summary field.

## Security Invariants

Defects the architecture review caught. Reintroducing one is a defect regardless of test results.

- **Never render `bypass_hook_trust`** — it is global, so any repository's `.codex/hooks.json` becomes trusted. Use `hooks.managed_dir` and `managed_hooks_only` under enforced profiles; verify through `hooks/list`.
- **Never write into an existing runtime home** — a live launch reads it, so mutation changes policy under a running process. A config change produces a new `rt/<config-hash>/`; drift in an existing one is exit 3.
- **Never place the store inside the checkout** or any agent-writable path — it holds hook scripts and credentials, so write access is code execution as the user.
- **Never relay an unrecognised gateway route** — an unparsed body cannot be masked, so relaying leaks it. Refuse unknown route, unknown content block, non-text payload, unparseable or compressed body. With masking off, relay is allowed.
- **Never mask with no gateway** — nothing in the path can mask, so the guarantee is silently unmet. Masking above `off` under a gateway-less profile is exit 2, not a silent gateway promotion.
- **Never scan nothing** — an unscanned string is an exfiltration path. Inspect every string in a model request: structural keys with the secrets ruleset, the rest at full level.
- **Never derive launch identity from the environment inside a Codex hook** — the daemon may carry another launch's environment, applying the wrong policy. Use the payload `session_id` and the runtime home's policy file.
- **Never use a shared handoff file** — concurrent packages overwrite each other and one launch reads another's context. Each package gets its own token under `handoff/pending/`.
- **Never add a second hook returning `updatedInput`** for one event and tool set — Codex runs matching hooks concurrently, so the winning rewrite is a race. The manifest linter rejects it.
- **Never fail open a lock guarding a security asset** — proceeding without it puts two writers on the protected asset. Use `ihar_with_lock --required` for store mutation, CA generation, runtime materialisation, gateway refcounting, daemon reconciliation, install and update.
- **Never claim `hooks: enforced` without a passing conformance record** for the installed vendor version — rendering a hook is not evidence the vendor fired it.

## Vendor Facts

The two binaries disagree with each other and between versions. Measure, never assume.

- Check the pinned binaries before depending on a flag, method or schema. `--help` and `generate-json-schema` are authoritative; binary strings are a hint.
- `--` is a Claude passthrough separator only — `codex -- mcp list` fails. Use `capabilities().passthrough_separator`.
- Record an unresolved vendor fact in LLD §20 as an open decision naming its owning slice. Never let it become an assumption in code.
- Version-guard any vendor format declared internal. Above the guard, report the item unreadable; never guess.

## Testing

`tests/run.sh` runs every `test_*.sh` and `test_*.py`, one line per file, non-zero on any failure. It is created by task S0.6; until then a task ships the first tests of its own area. The style is the one `iclaude/tests` and `icodex/tests` already use, so read those before inventing a variant.

- **Bash** — source the module, stub the logging helpers, use `assert_eq`, `assert_exit`, `assert_contains` from `tests/helpers.sh`, keep `PASS`/`FAIL` counters, end with `finish`.
- **Python** — import modules by path, plain asserts, runnable standalone and under pytest.
- **Isolate every test** — set `IHAR_STORE` and `IHAR_STATE_ROOT` to its own temporary directory, removed on exit. Touching the real store, state root or user homes makes tests depend on machine state and able to destroy it.
- **Use fakes** — `tests/fakes/record-exec.sh` records argv and environment. Skip cleanly when a real binary is absent, except the conformance suite, which runs at install and update and is never skipped for an enforced profile.
- **Update the golden file in the same commit** as a renderer change; review that diff as the real change.
- **Write a negative test for every security behaviour** — a deny path without a test proving the action did not happen is untested. A rewrite path needs a test proving the rewritten input executed.
- **Grow `tests/test_concurrency.sh` with every slice** — two profiles in one project, two gateway instances, parallel installs, consumer release.

## Verification

**"It works" without an execution is not works.** Run the affected test files and the full suite before reporting a task complete; quote the command and its exit status.

Rendered output and stdin fixtures prove ihar emits the right thing and a script decides correctly. They do not prove the vendor loaded the hook, fired it and honoured the decision — only the conformance suite proves that.

A task is done when its tests pass, its failure class is declared, its contract schema is updated, its wiki page reflects the change, `ihar check` reports it truthfully under every profile including those where it is absent, and the ledger event is recorded.

## Phase Gates

A profile that has not passed its gate is absent from `manifests/profiles/` — present but undocumented means a user can select it without the enforcement it implies.

| Gate | After | Makes declarable |
|------|-------|------------------|
| G0 | contracts | nothing; unblocks enforcement work |
| G1 | state and runtime homes | nothing; every later phase writes into that layout |
| G2 | hooks, trust, conformance | any profile with `hooks: enforced` |
| G3 | explicit gateway | `protected` |
| G4 | transparent spike | no-go: `remote-protected` dropped by user decision in S11 |
| G5 | microVM and guest network | `isolated` |
| G6 | multi-session console | `console: allow` in a shipped profile |

G6 applies the rule above to a field rather than a whole profile, because `console: allow` authorises a local surface that starts launches as the user. It passes when a non-loopback bind is refused, a request without the token cookie or with a foreign `Origin` is refused, a tab writes no terminal output to disk, a tab receives the base environment only, and `ihar check` states the cross-project reach.

Never implement a later phase's enforcement to unblock an earlier one. **If a gate cannot be met, stop and report the evidence.** Dropping a profile is the user's decision, not yours, because it removes a capability they may be relying on; weakening one to pass its gate is never an option, because the profile's name is the guarantee.

## Scope

- Implement the slice in the plan, not the slice plus improvements. New scope appends a task to the plan and a slice to the ledger.
- Add no configurability, fallback path or abstraction the present contract does not need — unused machinery hides which pressures are real. The LLD names what exists.
- Keep lifted code's behaviour and cite its origin: `# lifted from iclaude:<path>:<symbol>`. Changing lifted behaviour goes through the LLD.
- Leave adjacent code alone. Remove orphans your change creates; mention pre-existing dead code, do not delete it.

## Git

**One slice, one branch, one worktree, one pull request.** A slice never shares a branch with another slice, because slices merge independently and a shared branch makes one slice's review block the other's.

Names are fixed. Branch `dev-<topic>-<slice>`, worktree `../ihar-<branch>` as a sibling of the checkout, never inside it:

```bash
git fetch origin
git worktree add -b dev-unified-harness-implementation-s2 ../ihar-dev-unified-harness-implementation-s2 origin/master
```

**Cut a slice branch from an up-to-date `master` only after every slice it depends on has merged.** The slice table names the dependencies; branching earlier means the dependency's code is absent and the tests cannot pass for a real reason.

Never commit to `master`. Integration is a pull request, always, including for a one-line fix.

Before opening the pull request: the slice's own test files pass and so does the full suite. Quote both commands and their exit status in the pull request body — a pull request asserting green without the output is not evidence.

```bash
tests/run.sh; echo "exit=$?"
gh pr create --base master --title "feat(s2): security contracts" --body-file -
```

After the pull request merges, remove the worktree, then the branches, in that order:

```bash
git worktree remove ../ihar-dev-unified-harness-implementation-s2
git worktree prune
git branch -d dev-unified-harness-implementation-s2
git push origin --delete dev-unified-harness-implementation-s2
```

Delete a branch only when it is listed by `git branch --merged origin/master`, `git log origin/master..<branch>` is empty, no open pull request names it, and its worktree is clean or gone. Any check failing means the branch stays; never force the deletion.

**The ledger slice moves to `done` when the pull request merges, not when the code is written.** Until then it is `in-progress`, and its events record the branch.

## Documentation

Every change altering behaviour updates, in the same pull request: the HLD or the LLD when it describes what changed (see **Authority**), the iwiki subsystem page, `README.md` and `docs/README.ru.md` when usage or setup changed, and the ledger event on the topic.

The definition of done in **Verification** includes this. A slice is not finished while a document still describes the previous behaviour.

Documentation and code comments are English; conversation is Russian.
