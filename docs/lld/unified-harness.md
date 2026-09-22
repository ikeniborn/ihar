# ihar — Unified Agent Harness: Low-Level Design

| Field | Value |
|-------|-------|
| Status | revision 18 (console front end served from a pinned terminal asset; the asset decision is closed) |
| Date | 2026-09-21 |
| Derived from | `docs/hld/unified-harness.md` revision 4 (§6.10 console, R9 and R10) |
| Review | `docs/lld/ihar_lld_architecture_review.md` — 9 P0, 11 P1, 5 P2 findings; disposition in §21 |
| Verified against | Claude Code 2.1.274, Codex CLI 0.154.0 (`--help`, `app-server generate-json-schema`, binary strings), iclaude and icodex checkouts on this machine |
| Scope | Implementation-level design for HLD §6–§9, plus the threat model, the test plan and the delivery plan |

## 1. Conventions and threat model

This document fixes names, file paths, schemas and algorithms so each slice can be implemented without re-deciding structure. Where a fact comes from the existing wrappers it names the source function so the implementation can lift it. Items marked VERIFY are decisions a slice must confirm against the vendor before relying on them.

### 1.1 Languages and layout rules

- Bash 5, `set -euo pipefail` in the entry point, modules sourced from `lib/<area>/<file>.sh`. Public functions are `ihar_<area>_<verb>`; private helpers are `_ihar_<area>_<verb>`. Every public function documents its stdout contract (text for humans, JSON lines for machines, nothing for side-effect functions) and its exit code.
- Python 3.11+ for anything that parses JSON, JSONL, SQLite or TOML, speaks JSON-RPC, or terminates a connection. All Python lives in one package `lib/python/ihar/`, invoked as `"$IHAR_PY" -m ihar.<module>`. The `ihar_python` helper carries both calling conventions, a module and `-c <script>` for the short inline readers the shell needs, because `-m -c` asks Python for a module named `-c`: the shipped `ihar switch` used that form at four call sites and assembled empty JSON, which only a test stub that branched on `-c` had been hiding. The interpreter is the store venv (§2.3), built with the pinned `uv`.
- Hook scripts are the exception: they run under the system interpreter as `python3 -I <script>` so that neither a broken venv nor user site customisation can affect enforcement, and they import only the stdlib plus `_shared/` loaded from an absolute trusted path.
- No `jq` dependency on correctness paths. iclaude degrades to a warning without it; ihar performs JSON merges in Python and fails closed when the interpreter is missing, because settings sync carries the hook block.
- Configuration files are parsed, never sourced. `.ihar_config` follows icodex `load_config` (`lib/config/env.sh:6-27`): `KEY=value` lines, only `IHAR_[A-Z0-9_]+` keys accepted. This closes the code-execution path that sourcing `.claude_config` leaves open in iclaude.

### 1.2 Failure classes and exit codes

| Class | Behaviour | Exit code | Examples |
|-------|-----------|-----------|----------|
| fail-closed | one line on stderr, abort before the vendor binary starts | 3 | a mandatory gateway is unhealthy; sandbox cannot start; hook integrity or trust mismatch; hook conformance unproven for this vendor version; handoff sanitisation impossible; a required lock cannot be taken |
| usage or configuration | print the offending key or usage, abort | 2 | unknown command or profile, invalid `.ihar_config` key, an override that would loosen a profile, masking requested without a gateway |
| runtime | abort naming the failing step | 1 | vendor binary missing, state directory not writable |
| fail-soft | warn on stderr, continue | 0 | session index append, statusline cache, telemetry, distiller timeout, a best-effort lock |

Handoff is security layer 5 (HLD §7) and is fail-closed; only its optional summary is fail-soft. The vendor's own exit code is propagated unchanged.

### 1.3 Environment naming

`_IHAR_NATIVE_LIST` names the variables exported verbatim to the child:

```text
IHAR_VENDOR IHAR_PROJECT_ROOT IHAR_STATE IHAR_RUNTIME IHAR_LAUNCH_ID IHAR_PROFILE
IHAR_GATEWAY_ACTIVE IHAR_GATEWAY_MODE IHAR_GATEWAY_ACTIVE_PORT
IHAR_GATEWAY_MASKING_LEVEL IHAR_SANDBOX_MODE IHAR_CHAT_LANG IHAR_DOC_LANG IHAR_ASSUME_YES
```

Anything else set through `.ihar_config` is exported de-prefixed exactly like iclaude `apply_iclaude_env_map` (`lib/config/env-map.sh:38-52`). Harness-internal variables, never exported: `IHAR_ROOT`, `IHAR_STORE`, `IHAR_STATE_ROOT`, `IHAR_NVM`, `IHAR_PY`, `IHAR_CLAUDE_BIN`, `IHAR_CODEX_BIN`, `IHAR_PASSTHROUGH`, `IHAR_GATEWAY_*_UPSTREAM`.

**`IHAR_LAUNCH_ID` is not an identity mechanism for hooks.** A Codex hook may run under a long-lived daemon that inherited another launch's environment (§5.5), so hooks derive identity from the payload `session_id` and read policy from the runtime config on disk, never from these variables. They are exported for the statusline and for diagnostics only.

Vendor-facing variables are set by adapters alone: `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_EXECUTABLE`, `ANTHROPIC_BASE_URL` for Claude; `CODEX_HOME`, `CODEX_PATH` for Codex.

### 1.4 Threat model and the scope of R4

HLD R4 asks that "no PII leaves the machine in a model request" in a strict mode. A model egress gateway alone cannot deliver that, because an agent with a shell and network access can exfiltrate through any channel. The scope is therefore stated per profile, and each profile's wording is what `ihar check` prints:

| Profile | Guarantee |
|---------|-----------|
| `standard` | none. Masking is off and no egress is controlled. |
| `protected` | **model egress**: no unmasked supported content reaches a model provider, and unsupported content is refused rather than sent. MCP servers are restricted to a registry allowlist. Other tool network egress is not controlled, and `ihar check` says so. |
| `isolated` | **machine egress**: deny by default at the guest boundary; only the gateway, allowlisted MCP endpoints and profile-listed hosts are reachable. This is the only profile in which a data-loss claim covers arbitrary tool traffic. |

Three egress channels exist and each has its own control: the model request (§8), MCP servers (§7.3), and arbitrary tool network use (§9.2). A guarantee that names only the first is stated as covering only the first.

Trust boundaries: the store (§2.3) holds hook scripts, manifests, profiles, pinned binaries and vendor credentials; it is **outside every directory an agent can write**, which is why it no longer lives in the project checkout. The project workspace is agent-writable. The runtime home (§2.4) is agent-readable and, under enforced profiles, agent-read-only.

The console (§13.2) adds one boundary and widens no other. Its broker holds no vendor credential and never sees a model payload, but it starts launches on request, and a launch runs vendor code as the user. Its token is therefore a local credential of shell weight, and because the broker is per user rather than per project, that one token reaches every project state on the machine — the single place in this design where an authorisation is not scoped to one checkout. It lives at mode 600 under `$IHAR_STATE_ROOT/console/`, which is outside every agent-writable path for the same reason the store is (§2.1); an agent that could write it could drive the broker. Binding is loopback-only, so the boundary holds against the network and not against a process already running as this user, and `ihar check` states exactly that rather than implying more.

## 2. Layout

### 2.1 Three roots, deliberately separate

Revision 2 put everything under the checkout and one per-project home. That produced three defects the review names: an agent could write the store under a workspace-write sandbox (P1.3), two launches with different profiles raced on one mutable config (P0.6), and the Codex daemon socket path overflowed the platform limit (P1.11) — measured at 117 bytes against a `sun_path` maximum of about 108 on Linux. The split below fixes all three.

| Root | Default | Holds | Agent access |
|------|---------|-------|--------------|
| `IHAR_ROOT` | the checkout | `ihar.sh`, `lib/`, `hooks/`, `manifests/`, `skills/`, `.ihar-lockfile.json`, `.ihar_config` | writable (it is the project, when ihar develops itself) |
| `IHAR_STORE` | `${XDG_DATA_HOME:-$HOME/.local/share}/ihar` | binaries, venv, copied hooks and manifests, auth, plugin caches, CA, verification records | none under enforced profiles |
| `IHAR_STATE_ROOT` | `${XDG_STATE_HOME:-$HOME/.local/state}/ihar` | project state, runtime homes, gateway and daemon state | read-only under enforced profiles |

Both are overridable for tests and for machines where `$HOME` is unusual. The Node tree `IHAR_NVM` is a sibling of the store, never a child: iclaude states the reason at `lib/core/init.sh:57-62`, and ihar adds a second one, that no install step may run inside the directory holding the CA private key.

### 2.2 Path length budget

`IHAR_STATE_ROOT` is short by design because the Codex daemon opens `<CODEX_HOME>/app-server-control/app-server-control.sock`, and a Unix socket path over `sun_path` fails at bind: 108 bytes including the terminating NUL on Linux, so 107 characters. `ihar_state_preflight` computes the exact socket path at state setup and aborts with a specific message when it exceeds `IHAR_SOCKET_PATH_MAX` (default 107; no margin is subtracted, because the computed path is the real one and an arbitrary margin would reject layouts that work):

```text
state path too long for a Codex daemon socket (<n> > <max> bytes)
set IHAR_STATE_ROOT to a shorter directory
```

The default layout is `~/.local/state/ihar/<id>/r/<hash>/codex/app-server-control/app-server-control.sock`, measured at 102 characters. Every segment after the state root is sized by that budget: the vendor's own `codex/app-server-control/app-server-control.sock` costs 49 characters and cannot be changed, which leaves 58 for everything else.

Revision 3 of this document specified a readable id, `<sanitized-basename>-<sha256[:12]>`, and a two-character runtime segment. Measured on a real machine that produced 112 characters for this project and 120 for an ordinary longer name, so the documented layout would never have started a daemon anywhere. The id is therefore the hash alone and the runtime segment is one character. The project a state directory belongs to is read from its marker instead, which `ihar homes list` already does.

### 2.3 Store `$IHAR_STORE`

| Entry | Content | Owner |
|-------|---------|-------|
| `bin/codex`, `bin/codex-code-mode-host`, `bin/.codex-version` | pinned static Codex (icodex `lib/binary/install.sh:184-259`) | `ihar install` |
| `bin/uv`, `bin/rg`, `bin/tree`, `bin/firecracker`, `bin/vmlinux`, `bin/rootfs.ext4` | tools and microVM assets | `ihar install` |
| `venv/` | `requests`, `presidio-analyzer`, `presidio-anonymizer`, optional spaCy models, optional `claude-agent-sdk` | `ihar install` |
| `skills/`, `hooks/`, `manifests/` | copies of declared tracked release content; inventory validates type and required presence, while only hook files named in the release lock carry SHA-256 pins | `ihar install` |
| `auth/claude/.credentials.json`, `auth/codex/auth.json` | globally shared mutable vendor logins | vendors through `manifests/mutable-links.json` |
| `plugins/claude/`, `plugins/codex/` | globally shared mutable plugin state | vendors through `manifests/mutable-links.json` |
| `verification/<vendor>-<version>.json` | live hook conformance records (§6.6) | `ihar install`, `ihar update` |
| `acp/` | pinned ACP adapters | `ihar install --acp` |
| `install-receipt.json` | atomic machine-local evidence: release-lock digest, installed versions and executable SHA-256 values | `ihar install`, `ihar update` |
| `.ihar-store.lock`, `.last-lockfile-hash` | store lock and drift marker | store |

Installer-owned generation paths and vendor-owned mutable paths are separate contracts. An install or update transaction replaces only the explicit installer-owned paths, the staged Node tree, `.last-lockfile-hash`, and `install-receipt.json`; it never snapshots or activates `auth/`, `plugins/`, or the store-lock inode. `manifests/assets.json` validates each declared source's type and required presence before copying tracked release content; it is not a whole-tree digest manifest. Release-lock SHA-256 pins cover only the hook files explicitly listed there. Runtime publication and reuse separately require exact links from declared runtime targets to their installed store sources. `manifests/mutable-links.json` is the closed schema-1 inventory for the four mutable runtime links: Claude and Codex auth files plus their vendor plugin directories. These entries are deliberately absent from `manifests/assets.json`, whose content is installer-owned release input.

Every mutable source and runtime target is a canonical safe relative path. Sources are unique, targets are unique per vendor, auth sources are regular files below `auth/<vendor>/`, and plugin sources are real directories exactly at `plugins/<vendor>`. Dot segments, repeated/trailing-separator aliases, symlinked ancestors or leaves, non-directory ancestors and wrong leaf types fail closed before store preparation or runtime linking. Preparation walks retained directory descriptors with `O_NOFOLLOW`, creates only missing parents or plugin directories, keeps the auth root mode `0700`, and never creates, copies, removes or replaces an auth-file payload or existing plugin bytes. A missing auth file may therefore remain the intentional target of a dangling runtime link until the vendor creates it.

### 2.4 Project state and runtime homes under `$IHAR_STATE_ROOT`

```text
$IHAR_STATE_ROOT/<id>/
  home.json                     marker, schema 3
  .ihar.lock
  sessions.jsonl                session index (§10), 600
  ephemeral.jsonl               ids the index must ignore (§11.3), 600
  handoff/pending/<token>.md    per-launch handoff packages (§11.5), 700
  handoff/<ihar_id>.json|.md
  daemons/codex.json            managed daemon record (§5.5)
  recovery/runtime-state/<vendor>/<generation>-*/
                                retained pre-upgrade runtime bytes and prior canonical tree
  st/claude/                    Claude state declared by manifests/state.json
  st/codex/                     Codex state declared by manifests/state.json
  r/<config-hash>/claude/       = CLAUDE_CONFIG_DIR
  r/<config-hash>/codex/        = CODEX_HOME
```

`<id>` is `sha256(project_root)` truncated to eight characters. iclaude prefixes the sanitised basename (`resolve_claude_home_id`, `lib/config/isolated.sh:82-89`) and that reads better, but it does not fit the socket budget above. Eight hex is 32 bits, so two projects can in principle collide; the marker guard makes that an abort rather than a silent cross-attachment.

**`<config-hash>` is the first 8 hex characters of `sha256` over everything that decides how the vendor behaves**: profile name, effective masking level, gateway mode, sandbox mode, MCP strictness, the rendered hook manifest digest, the registry digest, the pinned vendor version, the stable semantic digest of the validated persistent-state manifest, and the canonical identity of every `runtime:true` asset entry plus its nofollow topology in the actual store. Asset bytes do not select a runtime because the home links to the store, but declared source/target/kind/required semantics and installed presence do; adding or removing an optional installed source therefore selects a new generation. Two launches with the same effective configuration share a runtime home and race on nothing; two launches with different configurations get different directories, which is what removes the last-writer-wins window of revision 2. A runtime home is written once, under the state lock, and is thereafter **immutable**: a configuration change produces a new directory rather than a rewrite.

A runtime home contains the rendered configuration plus symlinks:

```text
r/<hash>/claude/
  settings.json  mcp/ihar.json                       rendered, read-only (444) under enforced profiles
  hooks commands agents scripts CLAUDE.md skills     → immutable store assets
  .credentials.json plugins                          → mutable global store owners
  projects sessions session-env history.jsonl
  .claude.json                                       → ../../st/claude/*
r/<hash>/codex/
  config.toml  hooks.json  AGENTS.md                 rendered, read-only under enforced profiles
  hooks rules agents profiles skills                 → immutable store assets
  auth.json plugins                                  → mutable global store owners
  sessions history.jsonl session_index.jsonl shell_snapshots
  state_5.sqlite goals_1.sqlite memories_1.sqlite logs_2.sqlite
  app-server-control                                 → ../../st/codex/*
```

`manifests/state.json` is the single inventory for these state links and for legacy migration. It declares each vendor-relative entry as a directory, file or SQLite family. A declared file link may initially be dangling so the vendor creates the canonical target under `st/`; an SQLite family includes its `-wal` and `-shm` sidecars. The inventory follows the pinned vendor versions, so a vendor upgrade must re-run conformance before changing it.

Before an existing runtime is reused, ihar verifies the rendered files, actual-store topology and every `runtime:true` tracked-asset link, every mutable auth/plugin link, and every state link in that order. A required tracked source or link that is missing, a source whose nofollow topology differs from its declared kind, a wrong-target link, or a materialised tracked/mutable entry fails closed without repair or deletion. A missing optional tracked source may remain absent, but an optional target that is present and wrong still fails closed. New generations perform the same required-asset source preflight before any persistent-state upgrade or runtime mutation. Mutable links are preflighted against the canonical source topology before any link is created. Persistent-state entries materialised by a pre-manifest runtime are not treated as drift requiring manual copying: §4.5 migrates one unambiguous owner transactionally before canonical state links are reconciled.

Vendor state therefore persists across profile switches while configuration does not leak between them. Under `standard` the rendered files stay mode 600 and writable, so a user can experiment in place; under enforced profiles they are 444 and the sandbox denies the directory (§9.2).

Garbage collection: `ihar homes clean` considers runtime homes not used for 30 days in the current project state; `ihar homes clean <id>` applies the same runtime-only operation to the exact state id. Under the required state lock, cleanup runs candidate-scoped upgrade and quiescence for every vendor present in the generation before deletion. A materialised pre-manifest owner is migrated transactionally; even a link-only candidate must prove that exact generation has no selector, cwd, open-file or plausible opaque consumer. Ambiguous ownership, invalid ancestry, conflicting state, unavailable observation or atomic exchange, and any failed upgrade abort cleanup before deletion and preserve the candidate. Only successfully removed hashes leave `home.json`. Orphan states are reported, never removed automatically, and neither form removes `st/`.

### 2.5 Repository

```text
ihar.sh   VERSION   .ihar-lockfile.json
lib/
  core/       init.sh logging.sh lock.sh config.sh validation.sh
  cli/        args.sh commands.sh usage.sh
  store/      store.sh lockfile.sh install.sh update.sh verify.sh
  state/      state.sh runtime.sh links.sh migrate.sh gc.sh
  profile/    profile.sh enforce.sh
  render/     hooks.sh mcp.sh config.sh
  adapters/   adapter.sh claude.sh codex.sh daemon.sh
  gateway/    gateway.sh
  sandbox/    sandbox.sh netpolicy.sh microvm.sh
  sessions/   index.sh
  handoff/    handoff.sh
  web/ acp/ check/
  python/ihar/
    jsonio.py  toml_regions.py  runtime_state_upgrade.py
    sessions/{claude,codex,index}.py
    handoff/{build,distill}.py
    mask/{engine,shapes,policy}.py
    gateway/{explicit,routes,limits,log,mitm_addon,supervisor}.py
    render/{hooks,mcp,config_toml}.py
    codex/{appserver,hooks_trust,daemon}.py
    conformance/{run,cases}.py
hooks/
  _shared/{hookio.py,patterns.py,secrets.py,policy.py}
  security-pretool.py chain-gate.py gwt-gate.py session-register.py handoff-inject.py
  claude-only/…
manifests/
  hooks.json  assets.json  mutable-links.json  state.json  tests.json
  mcp/registry.json  profiles/*.json  netpolicy/*.json
  config/claude/…  config/codex/…
skills/  tests/  docs/
```

### 2.6 Project configuration `.ihar_config`

Keys: `IHAR_PROFILE`, `IHAR_DEFAULT_AGENT`, `IHAR_GATEWAY_MASKING_LEVEL` (tighten-only, §12.3), `IHAR_GATEWAY_ENGINE`, `IHAR_STATE_ROOT`, `IHAR_STORE`, `IHAR_PROXY_URL`, `IHAR_PROXY_CA`, `IHAR_PROXY_INSECURE`, `IHAR_TELEMETRY`, `IHAR_CHAT_LANG`, `IHAR_DOC_LANG`, `IHAR_IWIKI_*`, `IHAR_DISTILLER`, `IHAR_SOCKET_PATH_MAX`, `IHAR_CONSOLE_PORT`, `IHAR_CONSOLE_MAX_SESSIONS`, `IHAR_HANDOFF_HISTORY`, `IHAR_HANDOFF_TRANSCRIPT_BYTES`. An unknown `IHAR_*` key is exit 2. Precedence is defaults < file < flags, with the tighten-only exception of §12.3. There is no shared-home mode. The two console keys are read by the broker, which is per user rather than per project (§13.2): the project file that starts the broker wins, and a second project cannot retune a running one.

## 3. Control plane

### 3.1 Grammar

```text
ihar [global flags] <command> [command flags] [-- vendor args]
```

Commands: `claude`, `codex`, `sessions list|resume|name`, `switch --to <vendor>`, `web <vendor>`, `acp <vendor>`, `install`, `update`, `check`, `homes list|clean|clean <id>|migrate`, `daemon status|stop|restart`, `console start|status|stop|restart`. Global flags: `--profile`, `--dry-run`, `--json`, `--assume-yes`, `-h`. Launch flags: `--resume`, `--fork`, `--name`, `--model`, `--effort`, `--approval`, `--web`, `--mask-level`.

### 3.2 Argument parsing and vendor passthrough

One `while`/`case` loop with three rules that fix the iclaude passthrough defect (`iclaude.sh:692-695`): the first positional token is the command and an unknown global flag is a usage error; after the command only its own flags are parsed and an unknown flag is a usage error hinting at `--`; `--` ends parsing and the remainder becomes `IHAR_PASSTHROUGH`.

How that reaches the vendor is per vendor, because the parsers disagree. Verified here:

```text
claude -- mcp list      dispatches the subcommand        (2.1.274, commander)
codex  -- mcp list      error: unexpected argument 'list'  (0.154.0, clap)
```

`capabilities()` reports `passthrough_separator` as `"--"` for Claude and `"none"` for Codex; the Codex adapter appends the tokens with no separator. Both give the user the same `ihar <vendor> -- mcp list` form.

### 3.3 Launch lifecycle

Order is fixed by four dependencies: the profile decides how severe a store mismatch is; the effective configuration decides the runtime home; the gateway port is an input to the Codex provider render; the rendered fragments are the content of the runtime home.

| # | Function | Effect | Class |
|---|----------|--------|-------|
| 1 | `ihar_config_load` | parse `.ihar_config`, apply the env map | usage |
| 2 | `ihar_profile_resolve` | flag > file > `standard`; resolve the effective masking level and validate it against the gateway (§12.3) | usage |
| 3 | `ihar_store_verify <vendor> <selected-binary>` | lockfile drift, selected executable bytes against the install receipt, hook sha256, and for enforced profiles the hook conformance record for this vendor version (§6.6) | fail-soft for receipt failure under `standard`; otherwise fail-closed |
| 4 | `ihar_state_setup "$root"` | marker, `st/`, socket path preflight (§2.2) | runtime |
| 5 | `ihar_enforce_start` | gateway (§8.1), sandbox and network policy (§9), all fail-closed | fail-closed |
| 6 | `ihar_render_all <vendor>` | hooks, MCP, config fragments, using the gateway result; compute `<config-hash>` | fail-closed |
| 7 | `ihar_runtime_materialise <vendor>` | create `r/<hash>/<vendor>/` if absent, under a **required** lock; verify it if present; never rewrite | fail-closed |
| 8 | `ihar_codex_daemon_reconcile` | Codex only: stop or refuse a daemon whose binary version or config hash differs (§5.5) | fail-closed |
| 9 | `ihar_index_append` | launch record | fail-soft |
| 10 | `ihar_env_prepare <vendor>` | child environment (§3.4) | — |
| 11 | `adapter_<vendor>_launch` | assemble argv, `exec` | runtime |

With a refcounted gateway, step 11 runs the vendor in the foreground under a trap calling `ihar_gateway_release`, the iclaude pattern (`lib/launcher/launch.sh:842-856`); otherwise it `exec`s.

### 3.4 Child environment

Under `standard` the child gets the parent environment minus the harness-internal names of §1.3, minus `ANTHROPIC_BASE_URL` and `OPENAI_BASE_URL` when the profile owns the gateway, minus `CHROME_DESKTOP`.

Under enforced profiles the model inverts: the child gets a **base environment** (`HOME`, `PATH`, `TERM`, `LANG`, `SHELL`, `USER`, `TMPDIR`, `XDG_*`, `SSH_AUTH_SOCK` when the profile allows it), the `_IHAR_NATIVE_LIST`, the vendor variables, and only the names a project lists in `manifests/profiles/<name>.json` under `env_passthrough`. Everything else is dropped, because a developer shell routinely carries `AWS_*`, `GITHUB_TOKEN`, `DATABASE_URL` and `*_PASSWORD`, and an agent that can read its own environment can exfiltrate them through any channel the profile does not close. `ihar check` prints which names were dropped, without their values.

## 4. State, runtime homes and locks (slice S1)

### 4.1 Marker `home.json`

```json
{"schema": 3, "project_root": "/abs/path", "created": "…",
 "vendors": ["claude", "codex"],
 "runtimes": {"<config-hash>": {"profile": "protected", "created": "…", "last_used": "…"}},
 "migrated_from": {"claude": "…", "codex": "…"}}
```

Schema 1 is iclaude's marker and schema 2 was revision 2's; both are upgraded in place.

### 4.2 Functions

| Function | Semantics |
|----------|-----------|
| `ihar_project_root` | `git rev-parse --show-toplevel` else `pwd -P` |
| `ihar_state_setup root` | resolve `<id>`, create the state tree and `st/<vendor>/`, run `ihar_state_preflight`, write the marker; exports `IHAR_STATE` |
| `ihar_runtime_materialise vendor hash` | under `ihar_with_lock --required "$IHAR_STATE/.ihar.lock" 30`: if `r/<hash>/<vendor>` exists, verify rendered files and actual-store asset topology/links before mutable links or automatic state upgrade, then reconcile state links; else preflight required actual-store asset topology before state upgrade, link all three inventories in a temporary directory, `chmod 444` only the rendered security files under enforced profiles, then rename into place. Exports `IHAR_RUNTIME` |
| `ihar_link_runtime` | consumes `manifests/assets.json`, `manifests/mutable-links.json` and `manifests/state.json`; initial publication reports absent optional assets and creates canonical state/mutable owners without replacing existing vendor bytes |
| `ihar_verify_runtime_asset_links` / `ihar_verify_runtime_mutable_links` / `ihar_verify_runtime_state_links` | reuse verifiers require each declared link to resolve to its exact source, preserve wrong or materialised entries and fail closed; required asset links are never repaired in place, while missing state links are added only after the complete declared set passes validation |
| `ihar_asset_manifest_identity` | hashes validated `runtime:true` asset semantics plus nofollow topology in the actual store; bytes behind store links are excluded |
| `ihar_upgrade_runtime_state` | consumes the state inventory and migrates exactly one unambiguous pre-manifest materialised owner through the transaction in §4.5; a cleanup candidate proves exact-generation quiescence even when link-only |
| `ihar_with_lock MODE lockfile timeout cmd…` | §4.3 |

`manifests/assets.json` is the authoritative required/optional inventory for repository-owned store and runtime assets. It carries common `hooks`, `manifests` and `skills`, Claude instructions and optional extension directories, and Codex instructions and optional rules/agent/profile directories without hard-coded linker lists. Authentication, plugins, generated settings, caches, transcripts and vendor state are forbidden tracked assets. `manifests/mutable-links.json` separately owns global auth/plugin links (§2.3); `manifests/state.json` owns project-scoped persistent state (§2.4). No inventory may absorb another inventory's ownership.

### 4.3 Locks have two modes

Revision 2 inherited iclaude's single fail-soft lock (`lib/core/lock.sh:25-55`). That is right for the session index and wrong for anything that mutates a security asset:

```text
ihar_with_lock --required   missing flock, unwritable lock or timeout → exit 3
ihar_with_lock --best-effort  warn and run unlocked, the iclaude behaviour
```

`--required` is used for store mutation, CA generation, runtime materialisation, gateway refcounting, daemon reconciliation and install or update. `--best-effort` is used for the session index and cache refreshes. Passing neither is a programming error the linter rejects.

### 4.4 Rendered configuration

Claude managed keys are `hooks`, `enabledPlugins`, `statusLine`, `extraKnownMarketplaces`, `sandbox`. Because a runtime home is immutable, there is no merge-on-launch step: `ConfigRenderer` produces the complete `settings.json` from the store template plus the managed block, and user-owned keys come from `manifests/config/claude/settings.json` and from `.ihar_config`. A user who edits a runtime `settings.json` under `standard` changes the configuration hash on the next launch and gets a new runtime home, which is visible in `ihar check --diff`.

Codex `config.toml` is likewise rendered whole from the template plus regions, using the same `ihar.toml_regions` writer so that a migrated user file can still be adopted once. Regions: `mode` (top of file; `sandbox_mode`, `approval_policy`, `default_permissions`), `hook-trust` (end of file; `[hooks.state.*]` entries written after publication, per §6.4), `provider` (top of file; `model_provider`), `provider-table`, `mcp`, `projects`, `telemetry` (all at the end, since TOML requires top-level keys before the first table).

### 4.5 Migration

`ihar homes migrate` copies, never moves: for the current id it looks for `../iclaude/.claude-homes/*-<hash>` and `../icodex/.codex-homes/*-<hash>`, requires the iclaude marker's `project_root` to match (icodex has no marker, so the hash is accepted), copies only entries declared by `manifests/state.json` into `st/<vendor>/`, drops legacy configuration files because they are re-rendered, and records `migrated_from`. Updated `iclaude` and `icodex` wrappers hold a shared flock on `<legacy-home>.ihar-lifecycle.lock` from before home creation through vendor exit; migration holds both files exclusively through copy and marker publication. Failure to take any lock aborts without a force bypass. Process environment/open-descriptor probes remain a compatibility guard for old wrapper processes. For every vendor, content and metadata fingerprints of the source before copy, source after copy and staged tree must match; any mismatch discards the stage. SQLite WAL and SHM sidecars are copied with their databases so committed state is preserved after a clean stop. Symlinks, devices and special files are excluded.

Runtime reuse and generation changes also invoke an automatic compatibility transaction for state that an older runtime materialised locally instead of linking into `st/`. The validated state inventory is expanded first, including SQLite `-wal` and `-shm` paths; duplicate, aliased or overlapping ownership is rejected before filesystem inspection. All state-root, `r/`, generation, vendor, entry, staging and recovery ancestry is opened through retained directory descriptors with `O_NOFOLLOW`. Symlinked ancestry, wrong-target state links, special entries, multiple materialised owners, or a canonical conflict fail closed while preserving both source and canonical bytes.

The automatic transaction runs while the required project-state lock is held. On Linux, `/proc` observes every same-UID process; on Darwin, `/bin/ps` supplies identity, command line and environment while `/usr/sbin/lsof` supplies cwd and open files. Both platforms inspect readable `IHAR_RUNTIME`, `CODEX_HOME` and `CLAUDE_CONFIG_DIR` selectors and cwd or open descriptors below any same-vendor runtime, the materialised owner or canonical state. Direct references always block. If evidence is unreadable or partial, it blocks only when executable or command-line evidence classifies the process as the current vendor, its ACP adapter, the ihar wrapper, or as referring to a protected root; unrelated opaque session daemons are not consumers. Only the exact migration process is excluded, so ancestors and detached candidates cannot bypass the gate. An unsupported platform or unavailable observation fails closed.

The single materialised owner is fingerprinted before and after copying into a mode-`0700` private stage below `st/`. The stage begins as a copy of the current canonical vendor root, then receives the materialised entries. A second quiescence gate and source fingerprint run immediately before publication. Linux uses `renameat2(RENAME_EXCHANGE)` and Darwin uses `renameatx_np(RENAME_SWAP)` to atomically exchange the complete staged and canonical vendor directories. Platform selection and syscall availability are preflighted before staging; unsupported or failed exchange preserves both directories rather than creating an absence window. Published and source fingerprints are checked again before and after relinking. Original runtime entries move to `recovery/runtime-state/<vendor>/<generation>-*/`, canonical links replace them, and the prior canonical root is retained there as `.canonical-before`. Success therefore preserves both recoverable inputs; repeat materialisation is idempotent.

Any failure before commit attempts to exchange the prior canonical tree back and restore moved runtime entries. An incomplete rollback fails closed and names the retained recovery or stage path; cleanup never deletes incomplete evidence. This is automatic recovery for ordinary pre-manifest materialised state, not an instruction to copy it manually. Ambiguous owners, wrong links and conflicting canonical bytes still require explicit human resolution because ihar cannot choose which data is authoritative without risking loss.

`ihar install --migrate-store` applies the store analogue across the whole command, not as a separate pre-install publication. It takes required lifecycle locks for every eligible legacy source, rejects any process with an open descriptor at or below a source, and records each source inode identity plus content/metadata fingerprint around staging. After binaries, assets, conformance records and the new receipt are built, the command rechecks every legacy source identity, fingerprint and open-descriptor consumer immediately before activation. Any change or late consumer discards the combined stage; one activation publishes only revalidated evidence. Any install, conformance, receipt, revalidation or activation failure leaves the previous active generation and receipt usable; incomplete activation rollback retains and reports its recovery backup. Source locks are held until the command finishes, and legacy sources are copy-only and never deleted.

## 5. Adapters (slices S2, S7, S8, S9)

### 5.1 Operations

`ihar_adapter <vendor> <op> [args…]`.

| Op | Stdout | Exit |
|----|--------|------|
| `capabilities` | one JSON object (§5.2) | 0 |
| `launch`, `resume`, `fork` | none; `exec`s | vendor's |
| `exec_once home id prompt timeout` | the model's last message; prints the created fork id on fd 3 | 0 / 1 / 124 |
| `list_sessions home` | JSON lines, canonical records (§10.1) | 0 / 1 |
| `get_session home id` | JSON lines of normalised events | 0 / 1 |
| `export_context home id` | one JSON object (§11.2) | 0 / 1 |
| `switch_model model effort` | argv fragment | 0 |
| `start_remote home id mode` | argv fragment, or starts the daemon | 0 / 1 |
| `inject_context home token` | argv fragment; writes side files | 0 / 1 |
| `set_title home id title` | none | 0 / fail-soft |
| `archive home id` | none | 0 / fail-soft |
| `hooks_status home` | JSON: each required hook with trust state (§6.5) | 0 / 1 |

Adapters implement no policy; they receive rendered files and enforcement results.

### 5.2 `capabilities()`

```json
{"schema": 1, "vendor": "claude", "passthrough_separator": "--",
 "remote_control": true, "fork": true, "archive": false,
 "session_list_api": "sdk|jsonl", "session_id_preset": true,
 "hook_trust_api": false, "managed_hooks": false,
 "hook_events": ["SessionStart", "…"], "hook_input_rewrite": true,
 "sandbox_modes": ["vendor-default", "read-only", "vendor", "microvm"],
 "context_injection": ["initial_prompt", "append_system_prompt", "session_start_hook"]}
```

Codex reports `passthrough_separator: "none"`, `archive: true`, `session_list_api: "app-server|sqlite"`, `session_id_preset: false`, `hook_trust_api: true`, `managed_hooks: true`, and `context_injection: ["initial_prompt", "session_start_hook"]`.

### 5.3 ClaudeAdapter

Binary `IHAR_CLAUDE_BIN="$IHAR_NVM/npm-global/bin/claude"`; the PATH `claude` is never used.

```text
claude --session-id <uuid> [-n <title>] [--model <m>] [--effort <e>]
       --mcp-config <rt>/claude/mcp/ihar.json [--strict-mcp-config]
       [--remote-control [name]] [<initial prompt>] -- <passthrough>
```

`resume`: `--resume <id>`; `fork`: `--resume <id> --fork-session`; `exec_once`: `claude -p --resume <id> --fork-session --output-format json`, which reports the new session id in its JSON result, captured for §11.3. `set_title` records in the index only, because `-n` is launch-only in 2.1.274; `archive` is unsupported and returns 0.

`list_sessions` (`ihar.sessions.claude`): the Agent SDK `list_sessions()` when `claude_agent_sdk` imports from the store venv; otherwise a line-by-line reader over `st/claude/projects/<mangled-root>/*.jsonl`, where mangling turns every character outside `[a-zA-Z0-9]` into `-`, taking `created_at` from the first record, `updated_at` from the mtime, `cwd` and `gitBranch` from the first record carrying them, and the title from the last `custom-title` or `ai-title` record, else the first user message truncated to 80 characters. Results are cached by `(path, mtime, size)`. A first record whose `version` exceeds `IHAR_CLAUDE_JSONL_MAX_VERSION` makes that session unreadable rather than guessed. `claude agents --json` marks live background sessions.

`inject_context` prints the package as the initial prompt argument (§11.5).

`start_remote` prints `--remote-control [name]` when the gateway mode is `off`, and exits 1 under an explicit gateway naming the profile.

### 5.4 CodexAdapter

Binary `IHAR_CODEX_BIN="$IHAR_STORE/bin/codex"`; `PATH` is prefixed with the store `bin` for the `rg` and `tree` shims.

```text
codex [-m <model>] [-c model_reasoning_effort="<e>"] [<initial prompt>] <passthrough>
```

Mode, approval, trust, provider, MCP and hooks live in the rendered `config.toml`, so `codex mcp list`, `codex resume` and the daemon see what the TUI sees. `resume`: `codex resume <id>`; `fork`: `codex fork <id>`; `exec_once`: `codex exec fork <id> -o <file>`; `archive`: `codex archive <id>`.

`list_sessions` (`ihar.sessions.codex`) has three transports: the daemon control socket when one is running; otherwise a `codex app-server` stdio child using the JSON-RPC client lifted from icodex `lib/profile/app_server.py` (incrementing ids, `initialize` then `initialized`, server-initiated requests declined with `-32601`); and finally `st/codex/state_5.sqlite` opened `?mode=ro` behind a `PRAGMA user_version` guard.

**The control socket is a WebSocket endpoint carried over a Unix domain socket.** Revision 5 left the framing open (§20, "against stdio"); slice S8 measured it on 0.154.0 rather than guessing. A newline-delimited JSON-RPC request written straight to the socket gets no reply at all, for any framing tried — bare, newline-terminated or `Content-Length`. An RFC 6455 upgrade request is answered `HTTP/1.1 101 Switching Protocols`, and after it the messages are the same JSON objects the stdio transport exchanges. `ihar.codex.appserver` therefore shares one protocol layer between `AppServer` (a stdio child) and `DaemonClient` (the socket), and implements only the frames a JSON-RPC conversation uses: text, continuation, ping and close, with every client frame masked as the RFC requires.

`codex app-server proxy` is not a way around that. Its help says it proxies stdio *bytes* to the control socket, and it behaves that way: piped a plain JSON-RPC request it stays alive and answers nothing. The framing belongs to the client either way, so ihar connects to the socket directly and saves the extra process.

Request `thread/list {"cwd", "limit": 200, "sortKey": "updated_at", "sortDirection": "desc", "archived": false}`, paging on `nextCursor`. Mapping, verified against the 0.154 `Thread` definition:

| `Thread` | Canonical | Conversion |
|----------|-----------|------------|
| `id` | `vendor_session_id` | — |
| `name`, else `preview` truncated | `title` | `name` is nullable |
| `cwd`, `model`, `gitInfo.branch` | `cwd`, `model`, `git_branch` | — |
| `createdAt`, `updatedAt` | `started_at`, `updated_at` | **int64 Unix seconds → ISO-8601 UTC** |
| `source` | — | dropped: it is the thread's origin, a different meaning from the canonical `source` |
| `modelProvider` | — | dropped, not in the canonical record |

`set_title`: `thread/name/set {"threadId", "name"}`, both required, confirmed as `ThreadSetNameParams`. HLD §6.6 names `thread/metadata/update`, which carries only `threadId` and `gitInfo`.

`get_session`: `thread/read {"threadId", "includeTurns": true}` then paged `thread/items/list`. Rollout files are never parsed directly, because the sqlite projection depends on byte offsets.

### 5.5 Managed Codex daemon lifecycle

The Codex app-server daemon is long-lived and shared. Its README states that clients use the environment inherited when the daemon started and that per-client environment isolation is not provided. Two consequences shape the design.

**Identity.** Hooks running under the daemon may see another launch's environment, so `session-register.py` and every policy read derive from the hook payload's `session_id` and from the runtime configuration on disk. The mapping from `vendor_session_id` to `ihar_id` and profile lives in the control plane (§10.3), not in the daemon's environment.

**The daemon will not start without a managed standalone install.** `codex app-server daemon start` refuses unless `$CODEX_HOME/packages/standalone/current/codex` exists — the layout the official Codex installer produces — and says so: `managed standalone Codex install not found at …`. ihar installs a release tarball into its own store instead, so as written this section could never have started a daemon at all. Measured on 0.154.0: a **symlink** at that path pointing at the store binary is accepted, and `daemon start` then reports it as `managedCodexPath`. `ihar_render_standalone_link` creates it during the render, not in the published home, because a published runtime home is never written to again (§4.2).

**The daemon subcommands answer in JSON.** `daemon start`, `daemon version` and `daemon stop` each print one object on stdout carrying `status`, `backend`, `pid`, `socketPath`, `managedCodexPath`, `managedCodexVersion`, `cliVersion` and `appServerVersion`; `version` exits non-zero when nothing is running, which is an answer rather than a failure. Reconciliation reads the running version from there rather than inferring it from the binary on disk, because the daemon goes on running the binary it started from after that binary is replaced — which is the version-skew class this section exists to close.

**Reconciliation.** `ihar.codex.daemon` keeps `$IHAR_STATE/daemons/codex.json`:

```json
{"schema": 1, "pid": 12345, "socket": "…", "binary_sha256": "…",
 "codex_version": "0.154.0", "config_hash": "<8 hex>", "started_at": "…", "remote_control": false}
```

`ihar_codex_daemon_reconcile` at step 8 of the lifecycle: no record or no live process means nothing to do; a live daemon whose `binary_sha256` or `config_hash` differs from the launch is **stopped and restarted** when ihar started it, and **refuses the launch** (exit 3) when it did not, naming the mismatch. This closes the version-skew class reported upstream after a CLI update and prevents a `standard` daemon from serving a `protected` launch. `ihar update --codex` enumerates project states, stops managed daemons, replaces the binary, verifies the hash, and restarts only those that were running.

`ihar daemon status|stop|restart` exposes the same machinery.

## 6. Hooks (slice S3)

### 6.1 Manifest

```json
{"schema": 1,
 "entries": [
  {"id": "security-pretool", "event": "PreToolUse",
   "tools": ["shell", "file-read", "file-write", "mcp:*"],
   "script": "security-pretool.py", "args": [], "timeout": 10,
   "vendors": ["claude", "codex"], "profiles": ["*"], "required_in": ["protected", "isolated"]},
  {"id": "chain-gate-pre", "event": "PreToolUse", "tools": ["skill", "file-read", "file-write", "shell"],
   "script": "chain-gate.py", "args": [], "timeout": 10, "vendors": ["claude", "codex"], "profiles": ["*"]},
  {"id": "chain-gate-post", "event": "PostToolUse", "tools": ["file-write"],
   "script": "chain-gate.py", "args": ["--post"], "timeout": 10, "vendors": ["claude", "codex"], "profiles": ["*"]},
  {"id": "gwt-gate-pre", "event": "PreToolUse",
   "tools": ["mcp:iwiki*__wiki_update_page", "tool:wiki_update_page"],
   "script": "gwt-gate.py", "args": [], "timeout": 10, "vendors": ["claude", "codex"], "profiles": ["*"]},
  {"id": "gwt-gate-post", "event": "PostToolUse",
   "tools": ["mcp:iwiki*__wiki_status", "tool:wiki_status",
             "mcp:iwiki*__wiki_spec_context", "tool:wiki_spec_context",
             "mcp:iwiki*__wiki_update_page", "tool:wiki_update_page"],
   "script": "gwt-gate.py", "args": ["--post"], "timeout": 10, "vendors": ["claude", "codex"], "profiles": ["*"]},
  {"id": "session-register", "event": "SessionStart", "tools": ["any"],
   "script": "session-register.py", "args": [], "timeout": 5, "vendors": ["claude", "codex"], "profiles": ["*"]},
  {"id": "handoff-inject", "event": "SessionStart", "tools": ["any"],
   "script": "handoff-inject.py", "args": [], "timeout": 5, "vendors": ["codex"], "profiles": ["*"]},
  {"id": "session-status-start", "event": "SessionStart", "tools": ["any"],
   "script": "session-status.py", "args": ["--state", "running"], "timeout": 5,
   "vendors": ["claude", "codex"], "profiles": ["*"]},
  {"id": "session-status-permission", "event": "PermissionRequest", "tools": ["any"],
   "script": "session-status.py", "args": ["--state", "waiting-approval"], "timeout": 5,
   "vendors": ["claude", "codex"], "profiles": ["*"]},
  {"id": "session-status-stop", "event": "Stop", "tools": ["any"],
   "script": "session-status.py", "args": ["--state", "idle"], "timeout": 5,
   "vendors": ["claude", "codex"], "profiles": ["*"]},
  {"id": "session-status-end", "event": "SessionEnd", "tools": ["any"],
   "script": "session-status.py", "args": ["--state", "stopped"], "timeout": 5,
   "vendors": ["claude", "codex"], "profiles": ["*"]}
 ]}
```

`args` is separate from `script` because the rendered command quotes the script path and because the lockfile pins hooks by file path. `required_in` names the profiles whose enforcement depends on the entry; those are the hooks §6.5 verifies and §6.6 proves.

The four `session-status` entries carry no `required_in` on purpose: the console sidebar is a convenience layer, so a missing or failing status hook costs a badge and never a launch (§17). They attach to `SessionStart`, `PermissionRequest`, `Stop` and `SessionEnd` because those four are the coarse lifecycle events both vendors share (§3.3 of the HLD), and deliberately not to `PreToolUse`, where `security-pretool` and `chain-gate-pre` already spawn two processes per tool call and a third would be paid on every call to move one badge. The script returns no decision and no `updatedInput`, so the one-rewriter-per-event invariant above is untouched and the manifest linter has nothing to reject. `PermissionRequest` is the only event that distinguishes an agent waiting for a human from an agent thinking, which is the distinction R9 exists to show.

`chain-gate-pre` carries `file-read` and `shell` for the same reason the `skill` set exists at all: Codex exposes no Skill tool, so invoking a skill there shows up as a `Read` of its `SKILL.md` or a `Bash` command that names it. Measured on 0.154.0 rather than assumed, which is what §20 asked S3 to do: `app-server generate-json-schema` gives `HookEventName` an enum but leaves `toolName` a free string, so there is no tool enum to consult; the schema's `Skill*` definitions are the app-server's own listing and metadata API (`SkillsList`, `SkillMetadata`, `SkillScope`), not a tool a hook ever sees; and the binary contains no `Skill`, `use_skill`, `invoke_skill` or `run_skill` tool name at all. Revision 5 listed only `skill` and `file-write`, which rendered on Codex as `apply_patch|Write|Edit` — the gate then caught the spec-to-plan and plan-to-code transitions and was blind to every skill transition, including `finishing-a-development-branch`, which is the one the `execute` route ends on. The added cost is one more process on calls that already spawn a hook, because `security-pretool` matches `shell` and `file-read` already.

Revision 5 listed no `gwt-gate-post` entry, which contradicted §6.3's own table and made the gate incapable of working: its post role is what records each domain's effective specification mode, records a context read, and consumes that evidence once a mutation succeeds. Without the entry nothing is ever recorded, so every update is refused for want of a mode; and nothing is ever consumed, so one context read would license every later rewrite of the same scenario. Its tool set is deliberately wider than the pre entry's, because what it records arrives on `wiki_status` and `wiki_spec_context`, not on the update it later gates. The set is measured from icodex's live wiring (`.codex-isolated/hooks.json`), which is the only place the gate has ever run.

**One security hook per event.** Codex runs matching command hooks of one event concurrently, so two hooks that both return `updatedInput` would race and one rewrite would be lost. `security-pretool.py` therefore performs protected-path checking, secret detection, redaction and MCP input policy in one process and emits exactly one decision. Workflow gates stay separate because they never rewrite input. The invariant, asserted by a manifest linter: for any event and tool set, at most one entry may return `updatedInput`.

**Matchers are regular expressions, not globs.** `mcp:<pattern>` converts `*` to `.*`, so `mcp:iwiki*__wiki_update_page` renders as `mcp__iwiki.*__wiki_update_page` and matches `mcp__iwiki-local__wiki_update_page`; `mcp:*` renders as `mcp__.*`. `tool:<name>` renders verbatim, because icodex matches the bare name alongside the qualified one (`lib/iwiki/iwiki.sh:184`). Logical sets map as `shell` → `Bash`; `file-write` → `Write|Edit|MultiEdit` for Claude and `apply_patch|Write|Edit` for Codex; `file-read` → `Read`; `any` omits the matcher.

Rendered command: `python3 -I "$<HOME_VAR>/hooks/<script>" <args…> --vendor <vendor>`, with `HOME_VAR` being `CLAUDE_CONFIG_DIR` or `CODEX_HOME`. Claude-only entries (non-`command` handler types, Claude-only events) are appended to the Claude output only.

Disposition of the wrappers' existing scripts: `block-secrets.py` and `redact-secrets.py` merge into `security-pretool.py`; `chain-gate.py` and `gwt-gate.py` are reunified into one implementation each; `_codex_paths.py` is absorbed by `_shared/hookio.py`; the caveman and `iwiki-remote-scope` JavaScript hooks and `cache-report.py` stay Claude-only. icodex's `direct-topic.py` and `profile-transition.py` are not carried, because they serve the icodex profile-routing subsystem, which is outside the HLD's scope.

### 6.2 `hooks/_shared/hookio.py`

```python
@dataclass
class Event:
    vendor: str; event: str; tool: str; raw_tool: str
    input: dict; session_id: str; cwd: str; raw: dict

read_event(argv) -> Event
command_of(ev)   text_fields(ev)   paths_of(ev)   set_text(ev, pointer, value)
allow()                      # exit 0
deny(reason)                 # stderr + vendor-shaped JSON + exit 2
update_input(ev)             # hookSpecificOutput.updatedInput, exit 0
context(text)                # hookSpecificOutput.additionalContext, exit 0
```

`deny` emits `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": r}}` on both vendors and exits 2, the universal block. `update_input` emits `updatedInput`, which replaces iclaude's `toolInputOverride` and is accepted by both 2.1.274 and 0.154. There is no `ask`: a prompt a headless session cannot answer is a hang, not a control. `hookio` refuses keys outside the per-vendor allowlist, which matters because the Codex schema is `additionalProperties: false`.

Canonicalisation absorbed here: Codex `apply_patch` → `Edit`, `Shell` → `Bash`, the `tool_input` / `input` / `arguments` spelling, `command` against `cmd`, and patch headers `*** Add|Update|Delete File:` as paths.

`_shared/policy.py` reads the effective profile from `<runtime home>/ihar-policy.json`, a file the renderer writes next to the vendor configuration. The rendered `--vendor` argument selects `CLAUDE_CONFIG_DIR` for Claude and `CODEX_HOME` for Codex; environment-variable order is not identity, because both variables may be present in one process or microVM. Hooks read policy from disk rather than reading the effective profile from the environment, for the daemon reason of §5.5.

### 6.3 Script contracts

| Script | Event | Decision | Class |
|--------|-------|----------|-------|
| `security-pretool.py` | PreToolUse | in order: refuse a write into the store, the state root or a runtime home; `deny` on a sensitive path read or write (the union of both wrappers' pattern lists, minus safe suffixes); scan every text field and `update_input` with `REDACTED-<kind>` replacements; apply MCP input policy for `mcp__*` tools. Exactly one of `allow`, `deny` or `update_input` is emitted. An `Edit` anchor (`old_string`) is never rewritten | fail-closed |
| `chain-gate.py` | PreToolUse, PostToolUse | workflow gate over `docs/superpowers/`; state under the runtime home | fail-open |
| `gwt-gate.py` | PreToolUse, PostToolUse | scenario ordering gate for `wiki_update_page` | fail-open |
| `session-register.py` | SessionStart | appends a partial index record keyed by the payload `session_id` (§10.3) | fail-soft |
| `handoff-inject.py` | SessionStart | reads `handoff/pending/<token>.md` resolved through the control-plane mapping, emits `context`, deletes the file (§11.5) | fail-soft |

The security hook fails closed: any exception ends in `deny`. The workflow gates fail open: a crash there must not stop editing. Malformed frontmatter is the one exception inside `chain-gate.py`, and it is a decision rather than a crash: frontmatter nobody can read is not a passed check, and reading it as one walks an unvalidated artifact through the gate.

**The gates parse frontmatter with the standard library.** Both wrappers imported PyYAML lazily and fell open when the import failed. A hook here runs under the system interpreter by the rule of §6.2 — it must work when the venv is broken — so on an ordinary machine that import is absent and the gate would never gate anything at all. `chain-gate.py` therefore carries a parser for the subset `check-chain` writes: nested maps, lists of maps, scalars, flow sequences and block scalars. Anything outside the subset raises, and a raise is a blocked transition. The parser lives in the one file that uses it rather than in `_shared/`, because a second caller does not exist. One divergence from PyYAML is deliberate: a bare date stays a string, since the gate only ever compares such values for equality.

### 6.4 Codex hook trust, without a global bypass

Revision 2 rendered `bypass_hook_trust = true` permanently. The key is global: it disables the trust gate for every hook that can affect the thread, including a `.codex/hooks.json` committed in whatever repository the agent is working on. A mechanism meant to trust ihar's own hooks would have trusted an attacker's.

Revision 3 read the configuration keys `hooks.managed_dir`, `hooks.windows_managed_dir` and `managed_hooks_only` out of the binary's strings and chose them, leaving one open item: whether a project `config.toml` may set them. Slice S5 measured it against the pinned 0.154.0 app-server before writing any code, and the answer removes the option:

| what was tried | what `hooks/list` reported |
|----------------|----------------------------|
| `hooks.managed_dir` in a project `config.toml` | no entries at all |
| the same as a `-c` override | no entries at all |
| the same with the file named `hooks.json` | no entries at all |
| a plain `$CODEX_HOME/hooks.json` | listed, `trustStatus: "untrusted"`, `source: "user"` |
| `[hooks.state."<key>"] trusted_hash = "sha256:<64 hex>"` | listed, **`trustStatus: "trusted"`** |
| the same with a wrong or unprefixed value | listed, `trustStatus: "modified"` |
| `bypass_hook_trust = true` | listed, still `"untrusted"` |

Two conclusions. The managed directory is unreachable from anything a harness can write on a user's machine, so it is not the mechanism. And `bypass_hook_trust` does not confer trust at all — it suppresses the interactive prompt without changing the reported status — so the key the architecture review objected to was never the right mechanism for this purpose, quite apart from being too broad.

The design is therefore the fallback this section already named, with one mechanical addition:

1. The renderer writes `$CODEX_HOME/hooks.json` into the runtime home, as both wrappers do today.
2. After the home is published and inside the materialisation lock, `ihar.codex.hooks_trust --seal` asks `hooks/list` for the key and `currentHash` of every hook whose `sourcePath` is that home's `hooks.json`, and appends `[hooks.state."<key>"] trusted_hash = "<hash>"` for each, inside an `# ihar:hook-trust:` region.
3. Only hooks ihar rendered are trusted. A project or plugin hook keeps the vendor's ordinary trust flow, which is the whole objection to a blanket bypass.
4. `bypass_hook_trust` is written nowhere.

The seal runs after publication rather than in the staging directory because the key embeds the absolute path of the rendered `hooks.json`, which the atomic rename would change; and the drift check of §4.2 compares `config.toml` only up to the trust marker, because the block is derived from digests the vendor reported rather than rendered by ihar.

Editing a sealed hook flips its status to `modified`, so the launch-time check of §6.5 catches a hook an agent rewrote between two runs — the property the whole mechanism exists for.

### 6.5 Trust verification at launch

`adapter_codex_hooks_status` calls `hooks/list {"cwds": ["<project root>"]}` through the daemon or a stdio child and returns each `required_in` hook with its `trustStatus`, `isManaged`, `enabled`, `source` and `currentHash`. `ihar_enforce_start` requires, for every profile that lists the hook in `required_in`:

```text
enabled == true
trustStatus ∈ {managed, trusted}
currentHash == lockfile hash for that script
source ∈ {system, user, mdm}        not project, not plugin
```

Anything else aborts with exit 3 naming the hook and the observed state. Under `standard` the same call runs but a failure is a warning. Claude has no equivalent API (`hook_trust_api: false`), so its assurance rests on the sha256 pin plus the conformance record of §6.6.

### 6.6 Live conformance on pinned vendor versions

Rendered-output tests and stdin fixtures prove that ihar emits the right files and that a script decides correctly. They do not prove that the vendor loaded the hook, fired it, and honoured the decision. For a profile that declares `hooks: enforced`, that gap is the whole guarantee.

`ihar.conformance.run` first requires the binary's reported semantic version to equal the vendor pin in `.ihar-lockfile.json`; a mismatched binary cannot produce a record. Install/update run the staged binary and staged hook tree, but authentication is linked from the existing active store through `--auth-store`, and Claude's protected-root probes name the final active store through `--protected-store`. This topology proves the bytes being installed without pretending temporary credentials exist or proving denial only against the disposable stage.

Every required case drives a supported non-interactive vendor command through the rendered hook configuration. Direct execution of a hook script is never live evidence:

| Required for | Case | Assertion |
|--------------|------|-----------|
| Claude and Codex | `deny-blocks-the-tool` | an explicit `PreToolUse` deny fires and the target command does not execute |
| Claude and Codex | `rewrite-reaches-the-tool` | the hook rewrite reaches the command; the unrewritten fake secret does not |
| Claude and Codex | `session-start-context` | `SessionStart` fires and its `additionalContext` reaches the model turn |
| Claude and Codex | `mcp-matcher-fires` | the `mcp__ihar-conformance__prove` matcher fires and the stub MCP tool runs |
| Claude and Codex | `timeout-behaviour` | the vendor terminates the over-time hook within the bounded tolerance and records whether the tool ran |
| Claude | `sandbox-direct-write` | a direct shell write to every protected root is denied |
| Claude | `sandbox-child-write` | a child-process write to every protected root is denied |
| Claude | `sandbox-workspace-write` | the positive workspace write succeeds |
| Codex | `hook-is-loaded` | `hooks/list` reports the rendered hook file |
| Codex | `trust-is-recordable` | exact-digest sealing produces a trusted hook |
| Codex | `tampering-is-detected` | editing the sealed hook is detected |

The result is written to `$IHAR_STORE/verification/<vendor>-<version>.json` with the binary SHA-256, manifest digest, per-case outcomes and timestamp. The closed record schema rejects an empty case map, any missing vendor-required case, and any required case reported as `skipped`; a failed required case makes the conformance command fail. `ihar install` and `ihar update` run the full vendor-specific set. Only a bootstrap classified under the store lock as having neither a receipt path nor an installed vendor executable may activate after complete, schema-valid failed-case records: it removes those failed records from the stage, reports bounded vendor/case diagnostics, and directs the user to `ihar check --conformance` after native authentication. Pre-record errors, wrong pins, incomplete records and missing required cases still abort. Every existing-generation install or update requires passing conformance before activation; a failure discards the stage and preserves the previous generation, receipt and proof records. An explicit `ihar check --conformance` marks each vendor's recheck pending before revoking only that vendor's managed JSON proof records and running the live suite. Any revocation or live-run failure leaves the marker in place, so even a surviving older pass cannot be reused; a passing run writes new proof and clears the marker. Successful staged install/update replaces verification evidence without the marker. Step 3 of the lifecycle refuses an enforced-profile launch when recheck is pending or the record for the installed version is missing, stale relative to either digest, incomplete or failing:

```text
hook enforcement unproven for <vendor> <version>; run ihar check --conformance
```

## 7. MCP and its egress (slice S4)

### 7.1 Registry

```json
{"schema": 1,
 "servers": [
  {"name": "iwiki-remote", "transport": "http", "url": "${IHAR_IWIKI_REMOTE_URL}",
   "headers": {"Authorization": "Bearer ${IWIKI_REMOTE_TOKEN}"}, "env_names": ["IWIKI_REMOTE_TOKEN"],
   "scope": "user", "profiles": ["*"], "egress": ["wiki.internal:443"],
   "requires_env": ["IHAR_IWIKI_REMOTE_URL", "IWIKI_REMOTE_TOKEN"]},
  {"name": "iwiki-local", "transport": "stdio", "command": "iwiki-mcp", "args": [],
   "env_names": ["IWIKI_LLM_KEY", "IWIKI_DB_PASSWORD"], "env": {"IWIKI_PROJECT_DIR": "${IHAR_PROJECT_ROOT}"},
   "scope": "project", "profiles": ["standard", "protected"], "egress": ["db.internal:5432"],
   "requires_env": ["IWIKI_LLM_KEY"]}
 ]}
```

`env_names` forward by name only. `${IHAR_PROJECT_ROOT}`, `${IHAR_STATE}`, `${IHAR_STORE}`, and the configured `${IHAR_IWIKI_REMOTE_URL}` are expanded by the renderer; the remote bearer token remains forwarded by name. Any other `${…}` is left to the vendor, and since Codex does not expand, an unexpanded reference in a Codex render is exit 3. `egress` lists the hosts the server itself needs and feeds the network policy of §9.2.

### 7.2 Rendering

Claude: `{"mcpServers": {…}}` at `<rt>/claude/mcp/ihar.json`, passed as `--mcp-config`, with `--strict-mcp-config` when `profile.mcp.strict`. Codex: `[mcp_servers.<name>]` tables in the `mcp` region, `command`/`args`/`env_vars`/`[…env]` for stdio (icodex `_iwiki_region_body`, `lib/iwiki/iwiki.sh:29-50`), `url`/`bearer_token_env_var` for HTTP. Codex expresses only a bearer header, so an entry needing others renders for Claude alone and `ihar check` reports the gap as a notice.

### 7.3 MCP as an egress channel

A registered MCP server sends whatever the agent hands it, to wherever it points. Under enforced profiles three controls apply together:

1. **Allowlist.** Only registry entries whose `profiles` include the active profile are rendered, and `mcp.strict` prevents the vendor from loading any other definition.
2. **Input policy.** `security-pretool.py` masks every `mcp__*` tool input at the effective masking level before the call is made. An input carrying a content type the masking policy cannot handle is denied, mirroring §8.4.
3. **Network.** Under `isolated`, a server's declared `egress` entries are the only destinations opened for it; an undeclared destination is dropped by the guest policy (§9.2). Under `protected` this is not enforced and `ihar check` states that plainly.

## 8. Model egress gateway (slice S5a; S5b no-go)

### 8.1 Instance identity and lifecycle

A gateway's behaviour is decided by more than its mode: two explicit launches with different masking levels would otherwise share a process and one of them would silently get the other's policy. Instances are therefore keyed by their full configuration:

```text
gateway_key = sha256(mode + masking_level + engine + upstreams + route_policy_version)[:12]
state       = $IHAR_STATE_ROOT/gw/<gateway_key>/{lock,pid,port,consumers/,mode}
```

| Function | Semantics |
|----------|-----------|
| `ihar_gateway_acquire <key>` | under `ihar_with_lock --required`: sweep dead consumers; attach to a live, healthy instance; otherwise start the supervisor and wait up to 15 s for the port file, a TCP connection and `/api/ihar-probe`; then register `consumers/<pid>.pid` |
| `ihar_gateway_release <key>` | remove this consumer; the last consumer of that key stops its supervisor |
| `ihar_gateway_status` | read-only structured facts per key: explicit mode, nullable observed port/PID, live consumers, probe health, and available counters or an explicit unavailable state (§12.4) |

### 8.2 Two implementations, chosen by mode

The review is right that `http.server` is not a foundation for a security proxy; the Python documentation says it implements only basic security checks and is not recommended for production. But the two modes ask for different things, and one answer is wrong for both:

The shipped implementation is a plain-HTTP reverse proxy bound to loopback. There is no TLS to terminate, no ALPN to negotiate, no client that was not told to come here. `ihar.gateway.explicit` keeps a stdlib `ThreadingHTTPServer` hardened with the limits of §8.6, which keeps the protected path dependency-free.

### 8.3 Routing, default refuse

```text
model     POST /v1/messages, /v1/messages/count_tokens, /v1/messages/batches*  → Anthropic
          POST /v1/responses, /v1/chat/completions                             → OpenAI
          POST /backend-api/codex/responses                                    → ChatGPT
transit   auth, login and OAuth callbacks, token refresh, /v1/models, version and update
          checks, telemetry, any Upgrade: websocket request including the ChatGPT relay,
local     GET /api/ihar-probe (header x-ihar-gateway: 1), /api/health, /api/meta, /api/metrics
unknown   everything else
```

An unknown route is **refused** with 502 and a log line naming method, host and path whenever the effective masking level is not `off`; with masking off it is relayed as transit. This is what HLD §10 requires: a new vendor endpoint must fail loudly rather than become a silent hole. `/api/ihar-probe` is answered by the listener and never reaches the vendor.

### 8.4 Masking contract

Revision 2 said both that `system` is masked and that `system` content is preserved. The resolved contract:

1. **Every string in a model request is inspected.** There is no field that is skipped.
2. Strings under **structural keys** (`file_path`, `path`, `command`, `pattern`, `id`, `name`, `role`, `type`, `call_id`, and the rest of the icodex list at `server.py:28-31`) are scanned with the **secrets** ruleset only. They are not PII-masked, because mangling a path or a command breaks the tool call; but a credential embedded in one is still caught.
3. Every other string is masked at the effective level. The Anthropic top-level `system` field is masked, because it carries project instructions that may contain personal data; harness-authored `developer`-role content and the OpenAI `instructions` field are masked at the `secrets` ruleset, on the same reasoning as structural keys.
4. **Unknown content blocks are refused.** The shape module carries an allowlist of block types per family; a block type it does not know, a schema version it does not know, or a top-level key it does not know produces a 502 under enforced profiles.
5. **Non-text payloads are refused** under enforced profiles: image blocks, document blocks, base64 blobs above a threshold and file references. A text masking engine cannot certify an image, so the honest behaviour is refusal with a message naming the block type, not a pass. Under `standard` they are relayed, since that profile promises nothing.
6. A body that is not parseable is 400; a body with a non-identity `Content-Encoding` is 415. Neither is forwarded.

Engine (`ihar.mask.engine`): Presidio with spaCy when available, the iclaude regex engine as fallback, `IHAR_GATEWAY_ENGINE=regex` to force it, levels `off | secrets | standard`. The same module sanitises handoff packages (§11.2), so one implementation carries the claim. This also closes the icodex defect where `ICODEX_PII_ENGINE=nlp` is accepted while `server.py` never imports Presidio.

### 8.5 Transparent mode spike: no-go

S11 measured cgroup v2 and positive `iptables -m cgroup --path` support on the target kernel. nftables on the same host exposes only numeric cgroup ids. The redirect still requires root or `CAP_NET_ADMIN`: unprivileged nat-table access exits 4 with permission denied, while `route_localnet` is disabled. The approved design defined no root-owned helper, polkit policy or sudo contract. Adding one would create a new privileged security boundary rather than implement this design.

Gate G4 therefore failed. The user chose the plan's fail-closed outcome: `remote-protected` is dropped, `transparent` is removed from the profile schema, and no CA, mitmproxy addon, cgroup rule manager or dormant fallback ships. `protected` remains unchanged on the explicit gateway. Claude Remote Control with masking is not offered.

### 8.6 Limits and logging

Limits, enforced before parsing: maximum header count and size, maximum body bytes, maximum JSON nesting depth, maximum individual string length, read and connect timeouts. Exceeding any of them under an enforced profile is a refusal, not a truncation.

The logging contract is a fixed invariant with its own test. Never logged: `Authorization` and `x-api-key` values, any request or response body in either form, OAuth callback parameters, and query strings carrying token-like values. Always logged: request id, host and route class, byte counts, mask counters by kind, latency, and the refusal reason with its class. `ihar.gateway.log` is the only writer, and §16 asserts that a body containing a planted secret never appears in the log file.

### 8.7 Attachment per vendor

| Mode | Claude | Codex |
|------|--------|-------|
| `off` | nothing | nothing |
| `explicit` | `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>` | `model_provider = "ihar"` plus `[model_providers.ihar] base_url = "http://127.0.0.1:<port>/<prefix>" wire_api = "responses" requires_openai_auth = true` |

`ihar_codex_auth_prefix` is a narrow route selector, not an authentication-mode API. It reads but never writes `$IHAR_STORE/auth/codex/auth.json`: a readable regular file containing the literal `OPENAI_API_KEY` marker selects `v1`; absence or no marker selects `backend-api/codex`. It returns only that path segment.

## 9. Sandbox and network policy (slices S5a, S10)

### 9.1 Filesystem

| `sandbox` | Claude | Codex | Outer |
|-----------|--------|-------|-------|
| `vendor-default` | no `sandbox` key | no `mode` region; the vendor's own defaults apply and `ihar check` prints them | — |
| `read-only` | read-only policy | `sandbox_mode = "read-only"`, `approval_policy = "on-request"`, `default_permissions = "dev-safe"` | — |
| `vendor` | workspace write | `sandbox_mode = "workspace-write"`, `approval_policy = "on-request"`, `default_permissions = "dev-safe"`, plus the `.git/` grant (icodex `ensure_git_writable`) | — |
| `microvm` | as `vendor` in the guest | as `vendor` in the guest | Firecracker guest from iclaude `lib/sandbox/microvm.sh` |

`vendor-default` exists because HLD §8 calls the sandbox optional for `standard`, and rendering a region there would write `danger-full-access` and, following icodex's default triple, drop `default_permissions` — which icodex itself warns "disables managed permissions" (`lib/config/sandbox.sh:112-114`). Writing nothing is what "optional" means. A rendered region always carries a `default_permissions`.

Under enforced profiles the sandbox additionally denies the store, the state root and the runtime home for writes, and denies `auth/` entirely. For Claude the renderer emits those absolute paths through `sandbox.filesystem.denyWrite`, sets `allowUnsandboxedCommands: false`, and sets `failIfUnavailable: true`; the OS boundary therefore applies to Bash and all child processes. That closes the time-of-check window the sha256 pin alone leaves: verifying a hook at launch does not stop an agent from rewriting it before the next hook run. `security-pretool.py` refuses direct `Edit` and `Write` calls to the same paths as a second layer and does not attempt to parse arbitrary shell programs.

The icodex presets `ro | safe | full-ask | full-auto` map to `read-only | vendor | vendor-default | vendor-default` plus `--approval never`; `--approval` changes only `approval_policy`.

### 9.2 Network

`manifests/netpolicy/<profile>.json` declares the policy the profile enforces:

```json
{"schema": 1, "default": "deny",
 "allow": [{"kind": "gateway"}, {"kind": "mcp-declared"}, {"host": "registry.npmjs.org", "port": 443}]}
```

Only `isolated` sets `default: "deny"`, and it is enforced at the guest boundary, where a deny-by-default rule is both meaningful and cheap: the guest's only route out is the host, so the policy is a host-side filter on the tap interface plus the DNAT to the gateway. `protected` declares `default: "allow"` and the profile's guarantee text says so, because enforcing a per-process network policy on a host shared with the user's own tools is a promise ihar cannot keep. This is the difference between the two R4 scopes in §1.4, made concrete.

MicroVM changes over iclaude: the image carries both binaries, mounts `st/` for vendor state and the policy bundle read-only, keeps the workspace separately writable, exports both `CLAUDE_CONFIG_DIR` and `CODEX_HOME`, and DNATs model traffic to the gateway.

Before Firecracker starts, ihar writes a closed manifest over an immutable snapshot of the exact VM configuration plus launch-time identities and digests for kernel, prepared rootfs, policy, workspace and state images. The prepared rootfs carries lineage back to the lock-pinned base image. Observed evidence is published only after the pinned SSH identity answers and only when the live Firecracker executable and PID start identity consume the same unchanged configuration path; later checks revalidate that manifest, snapshot, pinned kernel/rootfs lineage, current immutable artifacts, TAP and firewall rules. A locator or configured profile is never enforcement proof by itself.

## 10. Session index (slice S7)

### 10.1 Canonical record

```json
{"schema": 1, "ihar_id": "0199f3a1-7c2e-7a41-9b0d-3f9a1cbd2e41",
 "vendor": "codex", "vendor_session_id": "…", "project": "ihar", "cwd": "…",
 "git_branch": "…", "title": "…", "model": "…", "profile": "protected",
 "started_at": "…", "updated_at": "…", "parent_ihar_id": null,
 "handoff_from": null, "handoff_to": null, "tags": [], "source": "launch|hook|vendor|sqlite"}
```

`ihar_id` is a UUIDv7: time-ordered like the previous format and without its 24-bit collision surface. A session discovered in a vendor store gets a deterministic UUIDv5 over `(vendor, vendor_session_id)` in a fixed namespace, so its id is stable across runs. All timestamps are ISO-8601 UTC strings; readers convert before the schema check. `source` is ihar's own provenance and never a vendor field of the same name. No content field exists, and `ihar.jsonio.check` rejects unknown keys.

### 10.2 Writer

`$IHAR_STATE/sessions.jsonl`, append-only, mode 600, appended under `ihar_with_lock --best-effort` with a 5-second timeout. A later record with the same `ihar_id` supersedes earlier ones field by field; null never overwrites a value; nothing is deleted.

### 10.3 Registration and the daemon problem

`session-register.py` appends a partial record: `{schema, ihar_id, vendor, vendor_session_id, profile, updated_at, source: "hook"}`. It cannot trust `IHAR_LAUNCH_ID` from its environment, because under a Codex daemon that variable may belong to an earlier launch (§5.5). It therefore resolves identity as follows:

1. Read `session_id` from the hook payload — always correct, since the daemon passes the thread's own id.
2. Read the profile and the runtime identity from `<runtime home>/ihar-policy.json`, the file next to the configuration the session is actually using.
3. Claim a launch record by matching `$IHAR_STATE/launches/<claim>.json`, a file written at step 9 of the lifecycle carrying `ihar_id`, vendor, profile and a monotonic counter; the first SessionStart with no `vendor_session_id` yet claims the oldest unclaimed launch for that vendor and runtime home, then deletes the claim.
4. With no claim available (a session started outside ihar, or a daemon serving an unknown client), mint a UUIDv5 as in §10.1 and record `source: "hook"` with no launch linkage.

The hook runs under `python3 -I` with only the stdlib, so it carries a small copy of the schema check in `_shared/`, tested against the same fixtures as the package version.

### 10.4 Reader and merge

Load the index and fold by `ihar_id`; call both adapters' `list_sessions`; join on `(vendor, vendor_session_id)`; a vendor session with no record gets the deterministic id and is written back; joined records take `title`, `updated_at`, `model` and `git_branch` from the vendor and keep `profile`, `handoff_*`, `parent_ihar_id` and `tags` from the index; sort by `updated_at` descending. **Any id listed in `$IHAR_STATE/ephemeral.jsonl` is skipped**, which keeps distiller forks (§11.3) out of the table.

`ihar sessions resume <id>` runs the full lifecycle with `adapter_<vendor>_resume` at step 11, so hooks, MCP, profile and gateway match a fresh launch.

## 11. Handoff (slice S8)

### 11.1 Package

`$IHAR_STATE/handoff/<ihar_id>.json` and `.md`, mode 600, plus `handoff/pending/<token>.md` for the target to consume.

```json
{"schema": 1, "source_vendor": "…", "source_session_id": "…", "source_ihar_id": "…",
 "target_vendor": "…", "created_at": "…", "project": "…", "cwd": "…",
 "git": {"branch": "…", "head": "…", "dirty": true, "shortstat": "…", "files_changed": 312},
 "files_touched": ["…"], "files_touched_truncated": false,
 "open_items": ["…"], "decisions": ["…"], "decisions_heuristic": ["…"],
 "recent_messages": [{"role": "user", "text": "…"}],
 "ledger": {"topic": "…", "task_page": "…", "slices_open": ["S2"]},
 "summary": "…", "masked": true, "masking_level": "standard", "bytes": 6120,
 "history": {"mode": "summary|transcript", "file": null, "messages": 0,
             "bytes": 0, "truncated": false}}
```

`history` is how much of the source conversation travelled and where the rest of it is. In `summary` mode — the default, and what revisions up to 12 described — `file` is null and the package is the whole carrier. In `transcript` mode the builder additionally renders the source session into `$IHAR_STATE/handoff/<ihar_id>-transcript.md`, masked at the effective level and mode 600, and `file` carries its absolute path. **The package still points rather than inlines**: the 8 kB bound of §11.2 is unchanged, the target agent is told the path and reads it with its own file tool if it needs it. This is the only mechanism by which more than a summary can cross vendors, because constraint 1 of the research page forbids seeding a vendor session with foreign history — the transcript arrives as content the target may read, never as state it resumes.

### 11.2 Builder

1. **Deterministic core**: `adapter_<source>_export_context`; `git rev-parse --abbrev-ref HEAD`, `git rev-parse HEAD`, `git status --porcelain`, `git diff --shortstat HEAD`, `git diff --name-only HEAD` plus untracked files; the task-ledger topic and page slug when `.iwiki.toml` and a `dev-<topic>` branch name one; explicit `- [ ]` items from the source transcript.
2. **Heuristic extraction is not deterministic and is labelled.** The prose lexicon that revision 2 used to find decisions (`decided`, `we will`, `chosen`, `agreed`, `instead of`) only works in English and silently returns almost nothing when `IHAR_CHAT_LANG=ru`. Its output goes to `decisions_heuristic`, marked advisory in the rendered Markdown; `decisions` carries only items the source structured explicitly. A language-independent summary is the distiller's job.
3. **Optional summary** from the distiller; a timeout omits the field with a warning.
4. **Sanitise** every string with `ihar.mask.engine` at the effective level. `masked: true` is set only after the pass. No engine and a level other than `off` is exit 3.
5. **Size**, target 8 kB, measured after each step. Truncation order: `recent_messages` oldest first, then `summary`, then `decisions_heuristic`, then `decisions` beyond 20, then `open_items` beyond 30, then `files_touched` beyond 50 with `files_touched_truncated: true` and `git.files_changed` carrying the real count. Only `git` (a single shortstat line), `ledger` and the identity fields are never truncated, so the bound is reachable on any repository.
6. **Transcript render**, in `transcript` mode only: `adapter_<source>_get_session` is normalised to `{role, text, at}` in order, rendered as Markdown with a header naming the source vendor, session and revision, masked by the same engine as step 4, and written atomically at mode 600. The budget is `IHAR_HANDOFF_TRANSCRIPT_BYTES` (default 2 MB), applied oldest-first with `history.truncated` and the real `history.messages` count recorded; a render or masking failure **degrades to `summary` mode with a named warning** rather than shipping an unmasked or partial file, and the switch continues, because handoff is a convenience layer while its sanitisation is not.
7. **Write** both files atomically and the pending file for the target.

**The transcript file is kept indefinitely, by decision.** It is an export under `$IHAR_STATE/handoff/`, outside the checkout, mode 600, masked — the same class of artifact as `handoff.json`, which has always carried `recent_messages`. The consequence is stated rather than discovered later: a project that switches often accumulates a masked archive of its own conversations that no retention rule removes, `ihar homes clean` does not touch it because it is not a runtime generation, and deleting it is a user action. `ihar check` reports the directory's file count and total bytes so the growth is visible rather than silent.

### 11.3 Distiller

`IHAR_DISTILLER=fork` calls `adapter_<source>_exec_once` against a fork, so the source transcript is never mutated and the request runs under the same runtime home, gateway and hooks. The adapter reports the created fork's session id on fd 3; the builder appends it to `$IHAR_STATE/ephemeral.jsonl` **before** the fork runs, so the reader of §10.4 never surfaces it even if the run crashes. The Codex fork is additionally archived; Claude has no archive operation, which is exactly why the ephemeral list exists. `local` builds a heading list with no model call; `off` omits the summary.

### 11.4 `ihar switch`

Resolve the source, build the package, append index records (`handoff_to` on the source, a target record with `handoff_from` and `parent_ihar_id`), then run the launch lifecycle for the target with `inject_context` feeding step 11. A model switch inside one vendor builds no package.

`--history summary|transcript` selects the mode of §11.1, defaulting to `summary` and to `IHAR_HANDOFF_HISTORY` when the project sets it. The console (§13.2) exposes the same choice on its handoff button, so the terminal and the window have one behaviour and not two. What the target does with a transcript is its own decision: the injected text names the file and says what it contains, and an agent that never reads it is a correct outcome, not a failure — which is why the deterministic core is never moved into the file.

### 11.5 Injection, one carrier and no shared file

Revision 2 wrote a single `handoff/latest.md`, which two concurrent switches would overwrite, letting one session consume the other's package. Each package instead gets a token, `handoff/pending/<token>.md`, where the token is the target's claim id from §10.3. The Codex `handoff-inject.py` resolves it through the control-plane mapping rather than an environment variable, for the daemon reason of §5.5, and deletes the file after reading it. A pending file older than 24 hours is swept by `ihar check`.

The payload has exactly one carrier. Revision 2 put the same text in both the initial prompt and `--append-system-prompt`, which doubles token cost and duplicates instructions at two different priorities. The split now is:

| Target | System prompt | Initial prompt |
|--------|---------------|----------------|
| Claude | a short fixed statement of the handoff protocol, when `profile.handoff.system_prompt` is set | the package |
| Codex | not available | the first 2 kB and a pointer; `handoff-inject.py` supplies the rest as `additionalContext` |

## 12. Security profiles (slice S5a)

### 12.1 Definition

```json
{"schema": 1, "name": "protected",
 "hooks": "enforced", "gateway": "explicit", "masking_level": "standard",
 "sandbox": "vendor", "netpolicy": "protected", "remote": ["codex"],
 "mcp": {"strict": true}, "acp": "refuse", "console": "allow",
 "env_passthrough": [], "handoff": {"system_prompt": false}}
```

`hooks` is `enforced` or `best-effort`. `enforced` means the profile's guarantees depend on hooks running, which is HLD §6.9's condition for refusing ACP, and it also switches on the trust verification of §6.5 and the conformance requirement of §6.6.

| Profile | hooks | gateway | masking floor | sandbox | network | remote | mcp.strict | acp | console |
|---------|-------|---------|---------------|---------|---------|--------|-----------|-----|---------|
| `standard` | best-effort | off | off | vendor-default | vendor default | claude, codex | false | allow | allow |
| `protected` | enforced | explicit | standard | vendor | allow, MCP allowlisted | codex | true | refuse | allow |
| `isolated` | enforced | explicit inside the guest | standard | microvm | deny by default | per the file | true | refuse | refuse |

`console` gates the tab, not the browser: `allow` means a launch may be driven from the broker of §13.2, and the tab kind follows `acp` — a profile with `acp: refuse` offers PTY tabs only, which is why `protected` allows the console and still has no chat tab. `isolated` refuses outright, since its vendor process runs inside the guest and no PTY crosses that boundary in this design.

### 12.2 Resolution

`--profile` > `IHAR_PROFILE` > `standard`; an unknown name is exit 2. The name is exported and recorded in the index and in `<runtime home>/ihar-policy.json`.

### 12.3 Masking is a floor, and it requires a gateway

The effective level is the strictest of the profile floor and any override, on `off < secrets < standard`. An override that would loosen the floor is exit 2.

Masking without a gateway is also exit 2:

```text
effective masking level is <x> but this profile has no model egress gateway;
handoff would be sanitised while model requests would not.
use --profile protected
```

Revision 2 allowed `ihar claude --mask-level standard` under `standard`, which sanitised handoff packages and left every model request untouched while the statusline reported masking as active. Silently promoting the gateway instead would change the security topology behind the user's back, so the error is explicit.

### 12.4 Enforcement

In order, each fail-closed: hook integrity and, for Codex, trust state through `hooks/list` (§6.5); conformance record for the pinned version (§6.6); gateway acquisition (§8.1); sandbox and network policy (§9); runtime home immutability (§4.2); daemon reconciliation (§5.5). `--web` for a vendor outside `remote` is exit 2; `acp` under `refuse` is exit 2; a console tab whose resolved project profile carries `console: refuse` is exit 2 and is reported in the tab rather than in the broker's own exit, because one refused project must not stop a window serving others.

`ihar check` collects one closed schema-1 object and both renderers consume that same validated object. It contains the profile and guarantee, masking floor/effective level/engine/dropped names, per-vendor receipt state, closed per-hook trust facts, conformance state, capabilities, asset diagnostics, MCP notes, the handoff export count and bytes, and known gaps. Per-vendor receipt state comes from the same `ihar_receipt_binary_status` helper used by launch and is exactly `verified`, `mismatched`, or `missing receipt`.

Gateway and network status are structured rather than prose claims. Each discovered explicit gateway instance carries `{key, mode, port, pid, consumers, healthy, metrics}`. `key` is the 12-hex instance identity; `port` and `pid` are nullable observed integers; `consumers` is the count of live consumer records; `healthy` is the live local protocol-probe result. `metrics` carries `state: available|unavailable` and `masked`, `refused`, `relayed`, `uptime_seconds`. Available metrics require every non-negative integer; unavailable metrics require every counter to be `null`, so check never invents zeroes or claims opaque counters are known. Collection is read-only and fail-soft per instance.

Network status is the closed object `{state, scope, default, configured, available, active, verified}`. `configured` means the resolved profile selects a microVM and network policy. `available` means current host prerequisites, pinned assets and passwordless privileged boundary pass read-only preflight. `active` requires live launch-owner and Firecracker PID/start identities, the expected Firecracker executable consuming the manifest-bound unchanged configuration, validated artifact lineage, and the named TAP. `verified` additionally requires the exact deny-by-default forwarding, input, DNAT and allowlist rules. `state: enforced` is derived only when all four booleans are true; otherwise it is `not enforced`. `scope` is `guest-boundary` whenever configured and `none` otherwise, while `default` reports the selected policy without claiming it is active. `standard` and `protected` therefore report all four false with `not enforced / none / allow`; an idle `isolated` profile reports configured true but remains `not enforced / guest-boundary / deny` until live evidence satisfies the other facts. Text and JSON expose the same fields.

## 13. Web surfaces, console and ACP (slices S9, S11, S12, S13)

### 13.1 Vendor web surfaces

**Claude web**: the profile must list `claude` in `remote` and use gateway `off`; then `--remote-control [name]`. No shipped profile combines Claude Remote Control with masking after the S5b no-go. **Codex web**: `codex app-server daemon start` under the runtime `CODEX_HOME`, `daemon enable-remote-control`, `remote-control pair` printing the code, then the TUI attached over the control socket, with the daemon recorded per §5.5. `codex features` reports `remote_control` as `removed` in 0.154.0 because the capability became these subcommands. **Codex LAN**: `codex app-server --listen ws://<addr>` with the websocket auth flags, not the daemon subcommand, which accepts only `-c`, `--enable` and `--disable`.

Slice S9/S12 measured these spellings from the pinned 0.154.0 help. Both `ihar web
<vendor>` and `<vendor> --web` enter the ordinary launch lifecycle. Profile gating
happens immediately after resolution, before store or gateway work. Claude adds the
native flag before its prompt and passthrough separator. Codex starts and records the
managed daemon when absent, enables Remote Control, prints the vendor pairing code,
marks the daemon record `remote_control: true`, and execs the TUI with `--remote
unix://<runtime>/app-server-control/app-server-control.sock`. Dry-run renders this
final argv but performs none of the daemon or pairing side effects.

### 13.2 Multi-session console (slices S12, S13)

The console implements HLD §6.10. Its governing decision is that **it launches the CLI rather than reimplementing the lifecycle**: a tab runs `ihar <vendor> …` under a pseudo-terminal, so profile resolution, store verification, conformance, gateway acquisition and release, sandbox, runtime materialisation and daemon reconciliation happen exactly once, in the code that already owns them (§3.3). Nothing about a gate is re-expressed here, and a gate that refuses shows its message in the tab.

```text
$IHAR_STATE_ROOT/console/
  lock                       broker lifecycle, ihar_with_lock --required
  daemon.json                broker record, schema 1, 600
  token                      32 random bytes, urlsafe, 600, rewritten at every start
  s/<sid>.json               per-session record, schema 1, 600
  s/<sid>.sock               per-session control socket, 600
  broker.err                 the broker's own stderr, so a start that fails can say why
```

There is no scrollback file and no transcript file, in this tree or anywhere else. A tab's output lives in the owning supervisor's memory as a bounded ring buffer (`IHAR_CONSOLE_MAX_SESSIONS` tabs, 256 KiB each) and is replayed to a reconnecting browser; when the ring wraps, the tab shows an explicit truncation marker rather than silently losing the top. `<sid>` is the first twelve hex characters of the `ihar_id`, because the socket path enters the same preflight budget as the Codex control socket (§2.2) and a full UUID does not fit it.

**Two processes, and the reason for the second.** The broker serves the browser; a per-session supervisor owns the pseudo-terminal. Without the supervisor a broker restart would send `SIGHUP` to every tab, which is the outcome the daemon decision exists to avoid. Each supervisor is `setsid`-detached, so it survives the broker, and the broker reattaches by reconnecting to `s/<sid>.sock`. The supervisor holds no policy: it opens the pty, spawns the CLI, keeps the ring buffer, forwards input and window size, and on exit records the code in its own record and removes only its socket. Revision 13 said it removed the record; the implementation keeps it, because a tab that vanishes the instant it exits takes its exit status with it and the sidebar has nothing to show. The record is removed when the user closes the tab.

**A detached daemon closes what it inherited.** `ihar console start` runs under a required lock, held on a file descriptor the broker would otherwise inherit and keep open for its whole life; every later `console stop` then waited ten seconds for a lock whose holder had already exited. The broker therefore closes descriptors 3 upward before it binds. This is measured behaviour, not a precaution: the timeout was observed before the close was added.

```json
{"schema": 1, "pid": 4711, "port": 8712, "token_sha256": "…",
 "release_digest": "…", "started_at": "…", "max_sessions": 8}
```

```json
{"schema": 1, "sid": "0199f3a17c2e", "ihar_id": "0199f3a1-7c2e-7a41-9b0d-3f9a1cbd2e41",
 "kind": "pty", "vendor": "codex", "state_id": "a1b2c3d4", "project_root": "…",
 "profile": "protected", "pid": 4820, "socket": "…", "started_at": "…", "exit_code": null}
```

Both records are metadata; `ihar.jsonio.check` rejects an unknown key, and neither schema has a field a message could be written into.

**Broker lifecycle mirrors §5.5, because the failure it prevents is the same one.** `ihar console start` takes the console lock, refuses a second broker for the same user, writes the token and the record, and prints `http://127.0.0.1:<port>/?t=<token>`; the broker exchanges that parameter once for an `HttpOnly; SameSite=Strict` cookie and redirects, so the token is not re-sent on every request. A live broker whose `release_digest` differs from the installed receipt is stopped and restarted rather than serving a window from code that is no longer installed. `ihar update` stops the broker before replacing binaries and restarts it only if it was running, the rule §14.3 already applies to the Codex daemon. Supervisors are not stopped by either path: they are detached, and their tabs reattach to the new broker.

**Access control, all three checks fail-closed.** The listener binds `127.0.0.1` only; a bind that is not loopback is exit 2 with the reason named, never a silent downgrade to loopback and never a network bind. The address is a broker flag rather than a project key on purpose: a configuration file that can ask for a network bind invites the refusal to be argued with, while the flag keeps the refusal testable without offering it as a setting. Every request and every WebSocket upgrade requires the cookie, compared to the token in constant time; a missing or wrong one is 401. The upgrade additionally requires `Origin` to equal the console's own origin, which closes the cross-site WebSocket path that a token cookie alone would leave open. Remote use is an SSH tunnel, which is the same answer §13.1 gives for `toad serve`.

**Refusals are HTTP statuses, and the mapping is fixed.** A missing or wrong cookie is 401; a foreign `Origin`, a profile whose `console` is `refuse`, and a profile file that does not validate are all 403, because each ends the same way — the tab does not start — and none of them is a malformed request; the session cap is 409; an unknown tab or route is 404; a body over 64 kB is 413. A refused tab never stops the window, which is why none of these reaches the broker's own exit code.

**Environment.** A console session never inherits the broker's ambient environment, in any profile. The supervisor builds the base environment of §3.4 — `HOME`, `PATH`, `TERM`, `LANG`, `SHELL`, `USER`, `TMPDIR`, `XDG_*` — adds `IHAR_CONSOLE=1`, and lets the CLI apply the profile's own rules from there. Inheriting instead would carry one shell's `AWS_*` and `GITHUB_TOKEN` into every project in the window, which is exactly what a cross-project surface must not do. The consequence is stated rather than hidden: a name a project lists in `env_passthrough` reaches a console tab only if the broker's own environment carried it at start, and the console reads secrets from nowhere else.

**A console tab names its own launch.** The broker mints the `ihar_id` before spawning and passes it as `IHAR_CONSOLE_LAUNCH_ID`, which the lifecycle adopts after the handoff and resume ids and before minting one of its own (§3.3). Without it the record and the session index would disagree on the identity of the same session, and the sidebar join of §10.4 would have nothing to join on.

**Sidebar.** One list, grouped by project, built from three sources and nothing else: the merge of §10.4 for every project state under `$IHAR_STATE_ROOT`, the session records above for what is live in this window, and the status records below for the badge. Discovery is the marker file of §4.1 — a directory without a valid `home.json` is skipped, not guessed at. `GET /api/sidebar` answers it, cached for five seconds because the list is polled and changes on human timescales; `?refresh=1` forces a rebuild.

The merge runs the **file and SQLite readers only**: the broker passes neither a Codex binary nor a daemon socket, so drawing a list can never start a vendor process. A session with no badge is reported as `unknown` rather than as running, and a badge outlives its session — the sidebar shows the last state the hook recorded, because a badge that disappeared would be indistinguishable from a session that never reported.

Rename writes through the adapter by running `ihar sessions name <id> <title>` in the project (`claude -n`, Codex `thread/name/set`, §19), so the native pickers show the same title and the console reimplements no adapter call; `POST /api/sessions/<state-id>/<ihar-id>/name` is the route. Resume opens a new tab through `ihar sessions resume <id>`.

**Status contract.** The `session-status` hooks of §6.1 write one file per vendor session under the project's own state:

```json
{"schema": 1, "vendor": "claude", "vendor_session_id": "…",
 "state": "running|waiting-approval|idle|stopped", "at": "…"}
```

Keyed by the payload's `session_id`, so it needs none of the launch-claim machinery of §10.3 and cannot attribute a status to the wrong session under a Codex daemon. The sidebar joins it to the index on `(vendor, vendor_session_id)`, the join §10.4 already performs. A stale file — process gone, no `stopped` written — is shown as unknown after the reader finds no live process, never as running.

**Thread projection (R10).** Selecting a session opens a read-only history pane beside the terminal, answered by `GET /api/thread/<state-id>/<ihar-id>`. The projection walks `handoff_from` back to the first session and `handoff_to` forward to the last, so any session in a chain shows the whole chain; reads each node with the transcript reader the handoff builder uses (§11.2 step 6); orders the messages; and inserts a marker between consecutive nodes carrying that handoff's `bytes`, `masking_level` and history mode from §11.1. A node whose vendor store no longer holds the session contributes a labelled entry in `gaps` and no messages at all. The marker is the point of the pane: it is where the next agent received a bounded package instead of the preceding messages, and a reader who cannot see it would mistake a summary for a memory. The projection is assembled per request, held in memory, and never written to disk — so it is not a transcript store, and a vendor session that has been rotated away leaves a labelled gap rather than a fabricated one. It is not masked, because it never leaves the machine; masking governs model requests (§8.4) and handoff packages (§11.2), and applying it to a local viewer would hide from the user what the agent already saw.

**Tab kinds.** `kind: "pty"` is the shipped one and carries every guarantee of the resolved profile. `kind: "acp"` (S13) runs `ihar acp <vendor>` and renders ACP updates as a chat; the broker offers it only when the project profile has `acp: allow`, and the UI labels it with the two gaps §13.3 names, because two tab kinds that look alike and guarantee differently is the confusion this labelling exists to prevent. A vendor change is never implicit in either kind: the handoff button runs `ihar switch --to <vendor>` (§11.4) and opens the resulting session as a new tab, linked in the sidebar.

**Check panel.** The console runs `ihar check` in the project and shows what it printed, cached for thirty seconds because the command starts processes of its own; `GET /api/check/<state-id>` is the route. The report already carries the console block of §12.4 — `{state, port, live_sessions, token_present, reach}` — so the window states the token's reach in the same words the terminal does. Read-only and fail-soft: a project whose check fails is shown as failing, not omitted.

**The window and its assets.** `GET /` serves `console/index.html`; `GET /static/<name>` serves exactly four files named in a closed map — the window's own script and stylesheet, and the pinned `xterm.js` and `xterm.css`. A name outside the map is 404 rather than a path join, so no request can walk out of the asset directory, and every asset needs the same cookie as the rest of the surface.

**The terminal is pinned, and a mismatch is a refusal.** `xterm.js` 5.5.0 is vendored under `console/vendor/`, and its digest is recorded in the release lockfile beside every other release input. The broker hashes the bytes before serving them: a build whose terminal is not the reviewed one answers 503 naming the digest rather than serving it. The window loads nothing else — no CDN, no network at runtime — because a local tool that needs the internet to draw a terminal is not a local tool.

**The handoff button reimplements nothing.** `POST /api/sessions/<state-id>/<ihar-id>/switch` opens a tab running `ihar switch --to <vendor> --history <mode>` with `IHAR_CONSOLE_LAUNCH_ID` naming the source session, so the package, its sanitisation and its profile gates are the ones of §11. An unknown vendor or history mode is 400 before any tab exists.

### 13.3 ACP launcher mode

**ACP**: `ihar acp <vendor>` execs the pinned adapter with the runtime environment. Every `hooks: enforced` profile refuses it at the profile gate, which is HLD §6.9's rule. Under `standard`, or another profile that explicitly allows ACP, a real ACP launch must then pass the same install-receipt check for the selected native Claude/Codex executable before the adapter starts; the adapter delegates to that binary, so ACP is not a receipt-verification carve-out. Adapter version/digest integrity remains a separate pinned-asset check. `ihar check` states that settings hooks may not fire (claude-agent-acp #144) and that codex-acp overrides sandbox and approval policy (#310, #477). ACP sessions are learned through the vendor listing path, since `session-register.py` may not run.

## 14. Install, update, verify

### 14.1 Lockfile

```json
{"schema": 1, "node": {"version": "…"},
 "claude": {"version": "2.1.274"},
 "codex": {"version": "rust-v0.154.0", "asset": "…", "sha256": "…"},
 "uv": {"version": "…"}, "python": {"requirementsSha256": "…"},
 "hooks": {"hooks/security-pretool.py": "…", "hooks/_shared/hookio.py": "…"},
 "managedHooks": {"managed-hooks/codex/security-pretool.json": "…"},
 "acp": {"claude-agent-acp": "0.79.0", "codex-acp": "6ec22f3"},
 "microvm": {"firecracker": "…", "kernel": "…", "rootfs": "…"}}
```

The tracked lockfile is immutable release input. It merges iclaude's version fields with icodex's release version, asset and published archive digest. Normal install and launch operations never rewrite it.

Machine-local evidence lives in `$IHAR_STORE/install-receipt.json`: installation time, the release-lock digest, installed versions, and SHA-256 digests of the produced Claude and Codex executables. The receipt is validated and atomically replaced only after a successful install transaction. `codex.sha256` remains in the release lockfile because it is the published archive digest checked before extraction.

### 14.2 Verification at launch

Release-lock drift warns that install evidence is stale. `ihar_receipt_binary_status <vendor> <selected-binary>` validates `$IHAR_STORE/install-receipt.json`, its release-lock digest and the selected executable bytes, then returns exactly `verified`, `mismatched`, or `missing receipt`. Missing, malformed and unreadable receipt evidence all report `missing receipt`; a missing component, changed release lock or changed executable reports `mismatched`. Either non-verified state warns and continues under `standard`, and exits 3 before vendor execution under `protected` and `isolated`. Every ACP-allowed real launch runs the same selected-native-executable check before its adapter; the shipped `protected` and `isolated` profiles refuse ACP earlier at the profile gate. Dry-run alone skips this receipt comparison because it executes neither the native binary nor an adapter that delegates to it; hook and store integrity checks remain in force. ACP adapter version and digest integrity remain under the existing adapter verification and do not add fields to the install receipt. A hook or managed-hook hash mismatch is exit 3 in every profile. For enforced profiles, a pending recheck or a missing, stale or failing conformance record is exit 3.

### 14.3 Commands

`ihar install [--acp] [--microvm] [--migrate-store]` validates tracked assets and mutable-source topology before building a generation, installs the Node tree and `claude`, the Codex tarball with icodex's tamper guard (`lib/binary/install.sh:184-259`), `uv` and the venv, shims, hooks, managed hooks and manifests into staged store/NVM trees, runs full live conformance, writes the new lock digest and receipt inside the stage, then activates the explicit installer-owned paths as one rollback-capable generation. A first bootstrap may activate after complete failed-case conformance records only; it discards failed staged records, emits bounded vendor/case diagnostics, and requires explicit post-auth `ihar check --conformance` before an enforced launch can pass its gate. A pre-record error, bad pin, incomplete record or missing case aborts even on bootstrap. Every existing-generation install or update requires passing conformance before activation, and a failure discards its stage while preserving the prior generation, receipt and conformance records. Mutable auth/plugin owners remain outside activation and existing bytes are preserved. There is no `--from-lockfile`: the release lockfile is the only source of installed versions. Install and update share this transaction. A matching component version stamp may skip downloading or reinstalling that vendor binary, but the command still recopies declared assets into the stage, reruns conformance, rebuilds the command-wide lock digest and receipt, and activates the staged generation. An unchanged lockfile therefore does not make the command a blanket no-op, and the receipt is not a per-component skip oracle.

With `--migrate-store`, eligible legacy content is copied into that same store stage before installation continues; it is not published early. Required legacy-source locks remain held through conformance, receipt creation and activation. A failure in any later step removes the stage and leaves the prior active generation and receipt paired; activation rollback attempts every previously moved path and retains/reports the backup if any restoration is incomplete. The legacy source remains byte-identical and is never deleted. `ihar update [--claude] [--codex] [--all]` stops managed daemons (§5.5), replaces binaries through the same generation transaction, re-proves conformance, publishes a receipt, and restarts only daemons that were running.

`ihar check [--diff] [--conformance]` collects one structured result rendered as text or, with the global `--json`, validated JSON. `--diff` compares temporary desired renders for both vendors with active runtime homes and has no state-changing side effect. `--conformance` is the explicit live evidence path. A command that does not declare JSON output rejects `--json` with exit 2. `ihar homes clean [<id>]` considers only expired runtime homes for the current or exact named state, upgrades materialised state and proves candidate quiescence before deletion, and never removes `st/`. Store writes take `ihar_with_lock --required` on `$IHAR_STORE/.ihar-store.lock`.

## 15. Data contracts

| Contract | Section | Carrier |
|----------|---------|---------|
| Adapter operations | §5.1 | `lib/adapters/*.sh` |
| `capabilities()` | §5.2 | adapter stdout |
| Hook manifest entry | §6.1 | `manifests/hooks.json` |
| Hook event and output | §6.2 | `hooks/_shared/hookio.py` |
| Effective policy for hooks | §6.2 | `<runtime home>/ihar-policy.json` |
| MCP registry entry | §7.1 | `manifests/mcp/registry.json` |
| Network policy | §9.2 | `manifests/netpolicy/*.json` |
| Asset inventory | §4.2 | `manifests/assets.json` |
| Mutable runtime-link inventory | §2.3, §4.2 | `manifests/mutable-links.json` |
| Vendor state inventory | §2.4 | `manifests/state.json` |
| Session index record | §10.1 | `$IHAR_STATE/sessions.jsonl` |
| Launch claim | §10.3 | `$IHAR_STATE/launches/*.json` |
| Handoff package | §11.1 | `$IHAR_STATE/handoff/*` |
| Handoff transcript export | §11.1, §11.2 | `$IHAR_STATE/handoff/<ihar_id>-transcript.md` |
| Console daemon record | §13.2 | `$IHAR_STATE_ROOT/console/daemon.json` |
| Console session record | §13.2 | `$IHAR_STATE_ROOT/console/s/<sid>.json` |
| Session status record | §13.2 | `$IHAR_STATE/status/<vendor>-<session>.json` |
| Profile definition | §12.1 | `manifests/profiles/*.json` |
| Daemon record | §5.5 | `$IHAR_STATE/daemons/codex.json` |
| Conformance record | §6.6 | `$IHAR_STORE/verification/*.json` |
| Home marker | §4.1 | `$IHAR_STATE/home.json` |
| Release lockfile | §14.1 | `.ihar-lockfile.json` |
| Install receipt | §14.1 | `$IHAR_STORE/install-receipt.json` |
| Check result | §12.4 | `ihar check --json` |
| Test inventory | §16 | `manifests/tests.json` |
| Project configuration | §2.6 | `.ihar_config` |

Every JSON contract carries `schema` and is validated on read and write by `ihar.jsonio.check`; an unknown key or wrong type is an error. `.ihar_config` is validated by its key table.

## 16. Test plan

Bash tests source the module under test with stubbed logging helpers and use `assert_eq`, `assert_exit` and `assert_contains` from `tests/helpers.sh` (lifted from icodex). Vendor binaries are replaced by fakes recording argv and environment. Python tests import modules by path and run standalone or under pytest.

| Slice | File | Cases |
|-------|------|-------|
| S0 | `tests/test_contracts.sh` | every profile file validates; the guarantee text of §1.4 exists per profile; the manifest linter rejects two `updatedInput` hooks on one event; netpolicy files validate |
| S0 | `tests/test_jsonio.py`, `tests/test_ids.py`, `tests/test_config.sh` | closed JSON contracts and atomic writes; UUID identities; parsed project configuration and output-mode grammar |
| S1 | `tests/test_state.sh` | id derivation; marker schema 3 and upgrades from 1 and 2; `st/` and `r/` separation; **socket path preflight aborts when over the limit**; runtime home immutability and generations keyed by state semantics plus actual-store asset topology; required asset preflight before state mutation; complete tracked-asset/mutable/state link creation and fail-closed reuse; cleanup upgrade/quiescence before deletion; migration by hash |
| S1 | `tests/test_runtime_state_upgrade.py` | nofollow ancestry; SQLite-expanded ownership; unique materialised owner; canonical conflicts; candidate-aware Linux `/proc` and Darwin `ps`/`lsof` quiescence across selectors/cwd/files; link-only cleanup candidates; Linux `RENAME_EXCHANGE` and Darwin `RENAME_SWAP`; unsupported-platform failure; source/stage/publication/relink fingerprints; recovery retention, rollback and idempotence |
| S1 | `tests/test_locks.sh` | `--required` exits 3 without `flock` or on timeout; `--best-effort` warns and continues; every security call site uses `--required` |
| S2 | `tests/test_adapters.sh` | dry-run argv and environment per vendor; **passthrough per vendor**, `--` for Claude and none for Codex; unknown flag exit 2; capabilities validate |
| S2 | `tests/test_lifecycle.sh` | step order: profile before store verify, gateway before render, render before materialise, daemon reconcile before launch; the gateway port reaches the Codex provider region; enforced receipt failure occurs before the vendor start marker |
| S3 | `tests/test_hooks.sh` | rendered outputs match golden files per profile; **matcher regex translation** and a real match against `mcp__iwiki-local__wiki_update_page`; `args` rendered outside the quoted path; `python3 -I` in the command; one decision per security hook on fixtures for both vendors; fail-closed against fail-open classes; `hookio` rejects disallowed keys; the store-write refusal has no exclusion for store hook paths |
| S3 | `tests/test_hook_trust.sh` | `hooks/list` responses drive the decision: `untrusted`, `modified`, `source: project` and a hash mismatch each abort with exit 3 under `protected`; the same responses warn under `standard`; sealing makes only ihar's own hooks trusted and a project hook is never in the trust block; `bypass_hook_trust` appears in no render |
| S3 | `tests/test_conformance.py` | required case sets are exact per vendor; fake native vendors drive deny, rewrite, SessionStart, MCP matcher and timeout through vendor command paths; Claude sandbox and Codex load/trust/tamper cases cannot be missing or skipped; release pins and active-auth/final-protected-store topology are enforced |
| S4 | `tests/test_mcp.sh` | renders match golden files at the runtime path; `requires_env` skip; `${IHAR_PROJECT_ROOT}` expansion; an unexpanded reference in a Codex render is exit 3; the header limitation is a notice; MCP input masking; a non-allowlisted server is absent from the render |
| S5a | `tests/test_gateway_explicit.sh`, `tests/test_gateway_routes.py` | masked bodies on every model route; **an unknown route is refused when masking is on and relayed when off**; **an unknown content block and an image block are refused under enforced profiles**; structural keys keep their values but a secret inside one is caught; unparseable 400; compressed 415; limits enforced; streaming relay; websocket transit; probe answered locally; **instance key separates two masking levels**; refcount acquire and release; an unhealthy gateway aborts with exit 3 |
| S5a | `tests/test_gateway_routes.py` | a planted secret in a request body never appears in the log; the allowed field list is exactly §8.6 |
| S5a | `tests/test_profiles.sh` | resolution precedence; **masking tighten-only**; **masking without a gateway is exit 2**; closed text/JSON status parity including truthful host-versus-guest network enforcement; the guarantee text printed matches the profile |
| S5a | `tests/test_profiles.sh`, `tests/test_hooks.sh` | `vendor-default` writes nothing; `vendor` writes the full triple plus the `.git` grant; `read-only` writes `read-only`; `default_permissions` never omitted; `--approval` changes only the approval policy; enforced profiles deny store and state writes through direct tools, Bash and child processes |
| S5b | `tests/test_contracts.sh`, `tests/test_profiles.sh` plus the recorded measurement | transparent mode is absent from the schema and `remote-protected` is absent from manifests after the privileged-boundary no-go |
| S7 | `tests/test_sessions.sh`, `tests/test_sessions_readers.py` | jsonl reader (title precedence, mangling, version guard, cache); app-server client over socket and stdio; sqlite fallback; **epoch seconds to ISO-8601**, and `Thread.source` and `modelProvider` never reaching the record; merge and supersede; deterministic ids for vendor-only sessions; **ephemeral ids excluded**; UUIDv7 ordering; partial hook records validate; **a hook with a stale `IHAR_LAUNCH_ID` still registers against the right session** |
| S8 | `tests/test_handoff.sh`, `tests/test_handoff_build.py` | under 8 kB **on a repository with 500 changed files** with the truncation flags set; deterministic fields with the distiller off; heuristic decisions kept separate and absent for a Russian transcript; `masked: true` only after the engine ran; exit 3 without an engine; **two concurrent switches consume their own pending files**; forks recorded as ephemeral before running; one carrier per target |
| S9 | manual protocol | Claude remote-control argv per gateway mode; the Codex daemon under the runtime home visible to `codex agents`; pairing code; LAN form uses `app-server --listen` |
| S10 | `tests/test_microvm.sh` | both homes visible in the guest; policy bundle read-only; deny-by-default network with the gateway reachable and an arbitrary host not; pre-spawn configuration snapshot and artifact/rootfs lineage bind live Firecracker evidence; configured/available/active/verified facts require observed identities, TAP and exact firewall rules; Codex boots and answers `--version` |
| S11 | `tests/test_acp.sh` | environment reaches the adapter; enforced profiles exit 2 with the issue list; every ACP-allowed real launch verifies the delegated native binary receipt before adapter start; `standard` proceeds and `ihar check` prints the gap |
| daemon | `tests/test_daemon.sh` | a daemon on an older binary is restarted; a config-hash change restarts an ihar-started daemon and refuses against a foreign one; `ihar update` stops and restarts only what was running |
| install | `tests/test_install.sh`, `tests/test_lockfile.sh` | transactional store activation and rollback; command-wide migrate-plus-install atomicity with source locks, activation-time source identity/fingerprint/consumer revalidation, and retained recovery on incomplete rollback; mutable-owner preservation; bootstrap-only activation after complete failed-case conformance records, while existing generations require passing conformance before receipt activation; receipt-backed executable verification with standard warning and enforced exit 3 |
| web | `tests/test_web.sh` | native Claude and Codex web argv, profile gates, daemon attachment and LAN spelling |
| S12 | `tests/test_console.sh` | a non-loopback bind is exit 2; a request or upgrade without the cookie is 401 and a foreign `Origin` is refused; the token file is 600 and rewritten at start; a tab spawns the CLI and inherits the base environment only, with an ambient `GITHUB_TOKEN` proven absent; a `console: refuse` project fails that tab and not the broker; killing the broker leaves the supervisor and its child alive and a new broker reattaches |
| S12 | `tests/test_console.py` | record schemas reject unknown keys; the ring buffer wraps with a truncation marker and no file is created anywhere under the state root during a session; the sidebar joins index, session and status records and reports a process-less status as unknown rather than running; the projection assembles a two-vendor chain in timestamp order with a handoff marker carrying the package bytes; a rotated vendor session yields a labelled gap |
| S13 | `tests/test_console_acp.sh` | an ACP tab is offered only under a profile with `acp: allow`; the tab kind and its missing hook and sandbox guarantees are labelled and appear in `ihar check` |
| S14 | `tests/test_handoff_history.py` | `summary` is the default and leaves `history.file` null; `transcript` renders in order, masks with the same engine, writes 600, and records the real message count when truncated; a planted secret is absent from the rendered file; a masking failure degrades to `summary` with a warning instead of writing an unmasked file; the package stays under 8 kB in both modes |
| workflow | `tests/test_workflow_gates.sh` | validated chain transitions, stale-hash rejection and bounded gate evidence |
| concurrency | `tests/test_concurrency.sh` | real-`flock` acknowledgement precedes every blocked-entry assertion; a marker paused inside publication proves a second profile cannot enter, then distinct homes publish and remain unchanged; parallel `ihar_cmd_install` calls serialize through the production store lock; different masking levels create different gateway instances; after one shared consumer releases, a live protocol probe succeeds for the other |

`manifests/tests.json` is the closed schema-1 inventory of the 29 test files that exist today, including `tests/test_runtime_state_upgrade.py` and `tests/test_handoff_history.py`; the three console files above are named by this plan and join the inventory in the slice that creates them, since the manifest describes what is discovered and not what is intended. Paths are unique, repository-relative `tests/test_*.sh` or `tests/test_*.py` names. Before executing anything, `tests/run.sh` validates the manifest and fails with exit 3 for malformed, duplicate, unsafe, missing, unlisted-discovered, or listed-but-undiscovered paths. It then runs the inventory-equivalent discovered set and is the command each slice's verification names.

## 17. Failure handling matrix

| Component | Failure | Class | Exit |
|-----------|---------|-------|------|
| config | unknown `IHAR_*` key | usage | 2 |
| profile | unknown name | usage | 2 |
| profile | override loosens the masking floor | usage | 2 |
| profile | masking level above `off` with no gateway | usage | 2 |
| state | socket path over the limit | usage | 2 |
| store | hook or managed-hook sha256 mismatch | fail-closed | 3 |
| store | executable receipt state is `mismatched` or `missing receipt`, `standard` / enforced | fail-soft / fail-closed | 0 / 3 |
| store | conformance binary differs from the release pin; record is missing, stale, incomplete, skipped or failing under an enforced profile | fail-closed | 3 |
| store | mutable-link manifest or canonical source topology is invalid | fail-closed | 3 |
| hooks | Codex `hooks/list` reports untrusted, modified, project-sourced or hash-mismatched required hook | fail-closed | 3 |
| lock | `--required` unavailable or timed out | fail-closed | 3 |
| lock | `--best-effort` unavailable | fail-soft | 0 |
| runtime | existing rendered file or tracked/mutable/state link is missing, wrong or materialised contrary to its contract | fail-closed | 3 |
| runtime migration | ancestry is symlinked; ownership is ambiguous; canonical state conflicts; a candidate consumer is active/opaque; a fingerprint changes; atomic exchange or rollback cannot complete | fail-closed, preserve source and recovery evidence | 3 |
| runtime cleanup | an expired candidate cannot be upgraded or proven quiescent on the current platform | fail-closed, preserve candidate | 3 |
| store migration | legacy source identity, fingerprint or open-consumer evidence changes before activation | fail-closed, preserve prior active generation and source | 3 |
| daemon | live daemon with a different binary or config hash, not ihar-started | fail-closed | 3 |
| render | manifest or registry schema error | fail-closed | 3 |
| render | Codex MCP entry with an unexpanded `${…}` | fail-closed | 3 |
| render | Codex MCP entry needing non-bearer headers | fail-soft | 0 |
| gateway | unhealthy within 15 s | fail-closed | 3 |
| gateway | unknown route, masking on | fail-closed per request | 502 |
| gateway | unknown content block or non-text payload, enforced profile | fail-closed per request | 502 |
| gateway | body unparseable / compressed / over limits | fail-closed per request | 400 / 415 / 413 |
| sandbox | microVM boot, prelaunch manifest/artifact lineage, observed launch identity or network policy verification fails | fail-closed | 3 |
| index | append fails | fail-soft | 0 |
| handoff | distiller timeout | fail-soft | 0 |
| handoff | masking engine unavailable, level above `off` | fail-closed | 3 |
| sessions | no vendor source readable | runtime | 1 |
| profile | `--web` for a vendor not in `remote`; `acp` under `refuse` | usage | 2 |
| console | bind is not loopback | usage | 2 |
| console | tab requested for a project whose profile is `console: refuse`, or whose profile file does not validate | fail-closed per request | 403 |
| console | token file missing, unreadable, or wrong mode | fail-closed | 3 |
| console | request or upgrade without a valid cookie | fail-closed per request | 401 |
| console | upgrade carrying a foreign `Origin` | fail-closed per request | 403 |
| console | second broker for the same user | fail-closed | 3 |
| console | live broker on a different release digest | fail-closed, restart the broker | 3 |
| console | `max_sessions` reached | fail-closed per request | 409 |
| console | supervisor socket unreachable for a recorded session | fail-soft, tab shown as detached | 0 |
| console | no status record for a session | fail-soft, badge shown as unknown | 0 |
| console | a project state whose index or vendor store cannot be read | fail-soft, that project reports its error and the window keeps its other projects | 0 |
| console | adapter read fails while projecting a thread | fail-soft, labelled gap in the pane | 0 |
| console | served terminal asset does not match its reviewed digest | fail-closed per request | 503 |
| console | console assets absent from the checkout or store | fail-closed per request | 503 |
| console | static name outside the served map | fail-closed per request | 404 |
| handoff | transcript render or its masking fails | fail-soft, degrade to `summary` with a warning | 0 |

## 18. Delivery plan

The review is right that the original slice order puts feature work before the contracts it depends on. Revised below; the per-task breakdown, gates, parallelisation and risk register live in the wiki plan `ihar/reference/plans/unified-harness-implementation`, tracked under the topic `unified-harness-implementation`.

| Slice | Deliverable | Verification |
|-------|-------------|--------------|
| S0 | Security contracts: R4 scope per profile, threat model, trusted-store boundary, network policy shape, runtime concurrency model, hook trust strategy | `tests/test_contracts.sh`; the guarantee text is what `ihar check` prints |
| S1 | Three roots, project state, immutable runtime homes, state/actual-store-topology-keyed generations, fail-closed cleanup, Linux/Darwin transactional runtime-state upgrade, socket preflight and two-mode locks | `tests/test_state.sh`, `tests/test_runtime_state_upgrade.py`, `tests/test_locks.sh` |
| S2 | Adapter contract, both adapters for launch, resume, fork and capabilities; lifecycle ordering | `tests/test_adapters.sh`, `tests/test_lifecycle.sh` |
| S3 | Hook manifest, renderer, `hookio`, merged security hook, Codex managed-hook trust, live conformance suite | `tests/test_hooks.sh`, `tests/test_hook_trust.sh`, `tests/test_conformance.py` |
| S4 | MCP registry, renderer, input policy | `tests/test_mcp.sh` |
| S5a | Profiles `standard` and `protected`; explicit gateway on the hardened stdlib server; masking contract; limits and logging; sandbox rendering | `tests/test_gateway_explicit.sh`, `tests/test_gateway_routes.py`, `tests/test_profiles.sh`, `tests/test_hooks.sh` |
| S5b | transparent gateway spike; no-go because the approved design has no privileged redirect boundary; drop `remote-protected` | `tests/test_contracts.sh`, `tests/test_profiles.sh`, recorded host measurement |
| S6 | Codex daemon lifecycle management | `tests/test_daemon.sh` |
| S7 | Session index, both readers, `ihar sessions` | `tests/test_sessions.sh`, `tests/test_sessions_readers.py` |
| S8 | Handoff: export, package, distiller, sanitisation, per-launch injection | `tests/test_handoff.sh`, `tests/test_handoff_build.py` |
| S9 | Web flags over native remote surfaces | `tests/test_web.sh`; manual protocol in `docs/manual/web-surfaces.md` |
| S10 | `isolated`: microVM with both binaries, read-only policy bundle, deny-by-default network and observed prelaunch-to-live evidence | `tests/test_microvm.sh` |
| S11 | ACP launcher mode, experimental | `tests/test_acp.sh` |
| S12 | Console broker and supervisors, PTY tabs, cross-project sidebar, status hooks, thread projection, check panel, rename, handoff button. Delivered in three ledger slices: the boundary first, then the data layer, then the front end | `tests/test_console.sh`, `tests/test_console.py` |
| S13 | ACP chat tab inside the console, experimental | `tests/test_console_acp.sh` |
| S14 | Handoff history modes: `transcript` export, budget, masking, degradation | `tests/test_handoff_history.py` |
| — | concurrency suite, run from S1 onward and extended by each slice | `tests/test_concurrency.sh` |

S12 depends on S7 for the index reader and on S8 for the handoff button; S13 depends on S11; S14 depends on S8 alone and can land before the console, in which case the button inherits it.

`protected` does not depend on the failed transparent spike: S5a delivers it on the explicit gateway.

## 19. Corrections to the HLD

- **Codex titles** use `thread/name/set {threadId, name}` (`ThreadSetNameParams`), not `thread/metadata/update`, which carries only `threadId` and `gitInfo`.
- **`--` is not a universal passthrough separator.** `codex -- mcp list` fails; `claude -- mcp list` works. HLD §6.1's rule holds as a user-facing convention only.
- **`bypass_hook_trust` must not be used.** HLD §6.4 proposes it as the way to trust store-pinned hooks; it is global and would extend trust to any repository's `.codex/hooks.json`. Measured in S5: the key does not even confer trust, leaving the status `untrusted`, so it is both too broad and ineffective. Per-hook `trusted_hash` verified through `hooks/list` is the mechanism (§6.4).
- **A single per-project home cannot hold per-launch profiles.** HLD §6.3's home must be split into project state and profile-scoped runtime homes (§2.4).
- **The store must not live in the checkout.** Under a workspace-write sandbox the agent can rewrite its own hooks, which no launch-time hash check can prevent (§2.1).
- **The Codex daemon does not isolate per-client environment**, so HLD §6.6's assumption that a SessionStart hook can read launch-specific environment does not hold (§5.5).
- **HLD §8's `standard` row** ("vendor sandbox optional") must render no sandbox region at all; rendering one writes a configuration weaker than icodex's shipped default (§9.1).
- **R4 needs a scope.** The gateway closes one of three egress channels; the other two are MCP and arbitrary tool network use (§1.4).
- `claude_agent_sdk` is not installed here, so the jsonl reader is the primary path; the SDK is an optimisation.
- icodex's `redact-secrets.py` blocks rather than rewriting, and its proxy ignores `ICODEX_PII_ENGINE=nlp`; both are fixed by the unified hook and engine.
- `codex features` reports `remote_control` as `removed` while the subcommands exist; the capability graduated from a flag.

## 20. Open implementation decisions

Revision 12 records only choices supported by the approved artifacts and reviewed implementation. Vendor timeout behavior is an executable mandatory case in §6.6 rather than a prose assumption; future pinned-version changes must earn new evidence before activation. Any question not supported by that evidence remains open rather than being closed by this reconciliation.

Revision 13 opened three. The terminal asset pin is now answered and closed: `xterm.js` 5.5.0 is vendored at `console/vendor/xterm.js`, sha256 `1f991ac3b4b283ebf96e60ae23a00a52765dd3a2e46fa6fdda9f1aab032f7495`, with its stylesheet at `ba8e6985669488981ccf40c0cefe3aba80722cb6c92de7ad628b0bd717faf2b6`; both digests were taken from the installed files and are recorded in the release lockfile, which the broker verifies before serving. Two remain, each owned by the slice that must measure it rather than assume it:

- **Masking throughput on a transcript (S14).** The 2 MB default budget assumes the masking engine finishes a large render in a time a user will wait for. Presidio's rate on this class of input is unmeasured; S14 measures it and either keeps the default, lowers it, or streams the render, and records the number here.
- **ACP tab promotion (S13).** claude-agent-acp #144 and codex-acp #310/#477 decide whether an ACP tab can ever be offered under an enforced profile. Until a measurement says they are closed, the tab exists only where `acp: allow` already stands.

## 21. Disposition of the architecture review

`docs/lld/ihar_lld_architecture_review.md`, 9 P0, 11 P1 and 5 P2 findings. Six load-bearing claims were re-verified against the binaries before acting, and two produced a better answer than the review proposed.

| Finding | Disposition |
|---------|-------------|
| P0.1 global hook trust bypass | accepted. Revision 3 proposed the managed-hook directory; S5 measured it and found it unreachable from a project configuration, so §6.4 uses per-hook `trusted_hash` verified through `hooks/list`. `bypass_hook_trust` is gone, and it turned out not to confer trust in the first place |
| P0.2 transparent interception scope | measured in S11. Positive cgroup-path matching exists, but installing the rule needs an undefined privileged boundary; G4 failed and the profile was dropped (§8.5) |
| P0.3 gateway keyed by mode | accepted. Instance key over the full configuration (§8.1) |
| P0.4 masking without a gateway | accepted. Exit 2 with an explicit message, no silent promotion (§12.3) |
| P0.5 R4 overclaimed | accepted. Variant B for enforced profiles: every string inspected, structural keys scanned for secrets, unknown blocks and non-text payloads refused (§8.4), with the scope stated per profile (§1.4) |
| P0.6 mutable shared home | accepted. Project state split from immutable profile-scoped runtime homes (§2.4, §4.2) |
| P0.7 daemon environment | accepted. Payload-derived identity, policy from disk, launch claims, daemon reconciliation (§5.5, §10.3) |
| P0.8 `ThreadingHTTPServer` | accepted for explicit mode, the only shipped host gateway. The proposed mitmproxy transport was discarded with `remote-protected` after G4 failed (§8.2, §8.5) |
| P0.9 live conformance | accepted. Suite, stored record, enforced-profile refusal (§6.6) |
| P1.1 concurrent security hooks | accepted. One `security-pretool.py`, enforced by a manifest linter (§6.1) |
| P1.2 lock modes | accepted (§4.3) |
| P1.3 store writable by tools | accepted and extended. The store moves out of the checkout entirely, since a workspace-write sandbox covers a checkout-local store (§2.1, §9.1) |
| P1.4 MCP egress | accepted (§7.3) |
| P1.5 shell egress against R4 | accepted. Per-profile scope; deny-by-default only where it is enforceable, at the guest boundary (§1.4, §9.2) |
| P1.6 `latest.md` race | accepted. Per-launch token files resolved through the control plane (§11.5) |
| P1.7 distiller forks in the index | accepted. Ephemeral list written before the fork runs (§11.3) |
| P1.8 English-only decision lexicon | accepted. Heuristic output separated and labelled advisory (§11.2) |
| P1.9 duplicated handoff carrier | accepted. One carrier; the system prompt holds only protocol text (§11.5) |
| P1.10 daemon in update lifecycle | accepted (§5.5, §14.3) |
| P1.11 socket path length | accepted and confirmed by measurement: the revision 2 path was 117 bytes against a limit near 108. Short state root plus a preflight (§2.1, §2.2) |
| P2.1 isolated Python | accepted. `python3 -I` (§1.1) |
| P2.2 environment allowlist | accepted for enforced profiles (§3.4) |
| P2.3 logging contract | accepted with a test (§8.6) |
| P2.4 body limits | accepted (§8.6) |
| P2.5 session id entropy | accepted. UUIDv7 for launches, deterministic UUIDv5 for discovered sessions (§10.1) |

Two review recommendations were not taken as written. Its §6 diagram places `Project State` feeding the runtime home, which is the right direction but leaves vendor state ambiguous; §2.4 instead links vendor state directories into each runtime home, so state persists across profile switches without being copied. And its `standard` row in §7 leaves tool network at "vendor default", which §1.4 states as "no guarantee" so that `ihar check` does not imply a control that is absent.
