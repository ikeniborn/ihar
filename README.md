# ihar

[Read in Russian](docs/README.ru.md)

`ihar` is a local control layer for using Claude Code and Codex CLI under one project
policy. It is for developers and teams that want to move between agents without
maintaining two separate sets of security rules, MCP connections and session
bookmarks.

`ihar` launches the vendors' own `claude` and `codex` binaries — it does not wrap, patch
or replace them. The vendors keep their own accounts, authentication and transcripts;
`ihar` supplies the shared setup around them. There is no separate ihar account or
hosted agent service.

## Why use it

Two agents normally mean two configuration formats, hook systems and sandbox models.
`ihar` gives a project one entry point for both, a common session index, and a bounded,
sanitised handoff when work moves from one agent to the other. Shared profiles render
the relevant security settings for each vendor. An enforced profile must prove its
guarantees before launch or stop; the `standard` profile intentionally offers no such
security guarantee.

The practical result is less duplicate setup and less risk of policy drift, while
keeping the native agent experience. `ihar` is not a new model, an agent runtime, a
transcript store or a replacement for vendor subscriptions.

## What a profile guarantees

A profile is a set of guarantees, and `ihar check` prints the text of the one in force.

| profile | in force |
|---|---|
| `standard` | Hooks advise. No network control. The vendor's own defaults, plus a single configuration. |
| `protected` | Hooks are enforced. Model traffic goes through a local gateway that masks secrets and refuses what it cannot mask. MCP servers are limited to a registry allowlist. |
| `isolated` | As `protected`, inside a microVM. |

A profile that enforces something and cannot prove it aborts the launch. There is no mode
where a guarantee degrades silently.

## Install

Everything installs under your own user. Installation never uses `sudo`. An `isolated`
launch needs passwordless `sudo` for its short-lived TAP and per-launch firewall chains;
the rules and interface are removed when the launch ends.

```bash
git clone https://github.com/ikeniborn/ihar.git ihar
cd ihar
./ihar.sh install
```

That builds the store, links `ihar` into `~/.local/bin`, creates the Python environment,
installs pinned component versions, verifies the Codex archive against its recorded
digest, and attempts the full live hook-conformance suite. The Node/Claude installation
is version-pinned but has no archive digest in the lockfile.

On a first bootstrap, missing native vendor authentication can leave one or more vendors
unproven after otherwise valid installation. The installer activates that bootstrap, names
the affected vendor and failed required case names without printing vendor output or
credentials, and tells you to run `ihar check --conformance` after signing in through the
vendor's own flow. `standard` can still launch with its native authentication behavior;
an enforced profile refuses before vendor execution until a complete matching conformance
record exists. An install or update of an existing generation is different: failed or
incomplete live conformance aborts activation and keeps the prior generation, receipt and
proof records.

An explicit recheck revokes the prior managed proof for each checked vendor. If it fails,
the enforced profile stays closed until that vendor passes a later recheck.

Codex uses one shared credential at `$IHAR_STORE/auth/codex/auth.json` across projects
and profiles. Sign in with the existing `ihar codex -- login` entry point: only the
authentication command runs in a private staging home, while ordinary launches keep
the verified runtime link. Re-authentication when a shared credential already exists
requires direct human approval; preserving its old bytes cannot undo a vendor-side
account or token change. Only one ihar-managed Codex credential writer may run at a
time, including a managed daemon or isolated guest. A busy or unverifiable owner is a
refusal, not a fallback to an unprotected writer.

Run `ihar check --diff` to see the selected runtime generation and bounded drift
categories. The generation includes effective MCP selection, so changing available
servers or a non-secret endpoint selects a new home without rewriting the old one.
Claude's top-level string `theme` is vendor-owned; managed settings and unknown fields
still fail closed. If a Codex runtime already contains a real `auth.json` in place of
the required link, ihar preserves it and asks for a separate user-approved recovery
proposal. Do not delete, move, or paste that credential as a troubleshooting step.

The specialised Firecracker guest comes from a compatible, locally built asset directory.
Its `firecracker`, `vmlinux` and `rootfs.ext4` files are checked against lockfile
digests. The three SSH key files are checked for their expected format and pairing;
they have no lockfile digests. The version key derives from the three pinned image
digests. A staged version is published, then its current pointer and command links
are updated with rollback protection:

```bash
IHAR_MICROVM_SOURCE_DIR=/path/to/assets ./ihar.sh install --microvm
```

If `~/.local/bin` is not on your `PATH`, the installer says so; add it:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Use

```bash
ihar claude
ihar codex
ihar --profile protected codex
ihar check
ihar --dry-run --profile protected codex
ihar sessions list
ihar sessions resume <ihar-id>
ihar switch --to codex
ihar web claude
ihar --profile protected codex --web
```

Everything after `--` reaches the agent untouched:

```bash
ihar codex -- mcp list
```

`ihar --help` lists every command and flag.

`ihar sessions list` merges metadata from both vendor stores into one project index.
The index owns no transcript content. Use its stable `ihar-id` with `sessions resume`,
or update the local display title with `sessions name <ihar-id> <title>`.

`ihar switch --to claude|codex` builds a masked, bounded handoff package from the
current session, links both canonical session records, and launches the other vendor.
Claude carries the package in its initial prompt; Codex consumes the remainder once
through its SessionStart hook.

`--history summary|transcript` decides how much of the conversation travels.
`summary` is the default and ships the package alone. `transcript` additionally
writes the source session to a masked file beside the package and points the next
agent at it, so it can read the history if the package is not enough:

```bash
ihar switch --to codex --history transcript
```

Neither vendor accepts a foreign session, so the transcript arrives as a file the
next agent may read, never as a session it resumes. Those exports are kept until you
delete them; `ihar check` reports how many there are and how much space they use.

## Web access today

Run `ihar web` on the computer that owns the project and vendor login. For now,
`ihar` is a local launcher/client, not a standalone website or a hosted ihar service.
The command starts the vendor's own remote surface; use the vendor's pairing or
browser flow to access the same native session.

```bash
ihar web claude
ihar web codex
```

`ihar claude --web` and `ihar codex --web` are equivalent. Claude Remote Control
works with `standard` only; `protected` refuses it because its model gateway is
incompatible with that vendor feature. Codex works with `standard` and `protected`:
`ihar` starts its managed app-server daemon, prints a pairing code, and attaches
the terminal client to it. The `isolated` profile offers neither web surface.

These bridges are vendor-owned and each carries one session. For the vendor-specific
flow and the optional authenticated Codex LAN listener, see
[Native web surfaces](docs/manual/web-surfaces.md).

## Multi-session console

`ihar console start` runs a local broker that launches ihar sessions and serves their
terminals in one place, across every project on the machine:

```bash
ihar console start
ihar console status
ihar console stop
```

It prints a `http://127.0.0.1:<port>/?t=<token>` URL. The listener is loopback only —
a bind that is not loopback is refused rather than downgraded — so reaching it from
another machine means an SSH tunnel. The token is exchanged once for an `HttpOnly`
cookie; every request needs it and every WebSocket needs this origin as well.

Each tab runs the ordinary CLI under a pseudo-terminal, so a tab is a normal launch:
the profile, its hooks, its gateway and its sandbox all apply unchanged, and a project
whose profile sets `console: refuse` fails in that tab without disturbing the others.
`standard` and `protected` allow the console; `isolated` refuses it, because its
session runs inside the guest.

Terminal output is never written to disk: it lives in a bounded in-memory buffer per
tab and is replayed when a browser reattaches. A tab outlives the broker, so restarting
the console — or updating ihar — does not kill the agents running in it.

The broker also answers what the window will show: one list of every project on the
machine with each session's vendor, title, profile and live state, and a read-only
thread that follows a `switch` across vendors and marks where the handoff cut the
context. A session whose vendor store no longer holds it appears as a labelled gap
rather than invented text, because ihar keeps no copy. States come from a hook on the
four lifecycle events both agents share — running, waiting for approval, idle, stopped
— so the list can say which agent is waiting for you.

Open the printed URL and the window shows all of it: a sidebar of every project and
its sessions, a tab per running agent with the vendor's own terminal in it, a history
pane that reads a chain across a `switch`, a panel with that project's `ihar check`,
and buttons to rename a session or hand it to the other agent. Browser notifications,
if you allow them, tell you when a session starts waiting for you.

A tab comes in two kinds. The default runs the agent's own terminal and carries the
profile unchanged. The second is an experimental chat over ACP: it is offered only where
the profile allows ACP, so `protected` and `isolated` refuse it, and the tab states what
it does not carry — hooks that may not fire under the Claude adapter, a sandbox and
approval policy the Codex adapter replaces, and the console's own refusal to give the
agent a filesystem or terminal through the browser. Those are the same three lines
`ihar check` prints. A permission the agent asks for is shown and waits for you; nothing
answers it on your behalf.

Whether that chat tab can ever stop being experimental is a measurement rather than an
opinion, and one command takes it:

```bash
ihar check --acp-promotion
```

It reads the condition from a manifest, reports each part as passed, failed or unmeasured,
and refuses to say "promotable" while anything is unmeasured. It changes no profile. As of
today it answers *not promotable*: the three upstream issues it names are still open.

Everything the page loads is served by the broker from a pinned copy — the terminal is
`xterm.js` 5.5.0, vendored with its digest in the release lockfile, and a build whose
bytes do not match is refused rather than served. Nothing is fetched from the network,
so the console works with the machine offline.

One caveat worth stating plainly: a console token starts launches in every project
state on this machine, which is wider than a single launch. `ihar check` prints that
reach, and so does the window.

## Configure

Per-project settings live in a `.ihar_config` file at the project root. Copy the generated
example and edit it:

```bash
cp .ihar_config.example .ihar_config
```

The file is parsed, never sourced: only `IHAR_*` assignments are accepted, an unknown key
is an error, and a value is data rather than something to execute. Precedence is defaults,
then this file, then command-line flags — with one exception: a profile's masking level is
a floor, and neither the file nor a flag may lower it.

All entries in the generated example are commented out. Values such as `${…}`, `unset`
and `the profile's floor` describe defaults; replace them with concrete allowed values
before uncommenting a line. The example covers every accepted project configuration key;
installation-only environment variables such as `IHAR_MICROVM_SOURCE_DIR` are separate.

## Update

```bash
ihar update
```

Install and update use the same transaction, and the lockfile remains the immutable source
of pinned versions. A matching version stamp may skip downloading or reinstalling that
vendor binary, but every run still validates topology, stages and copies declared assets,
re-runs conformance, rebuilds the receipt, and activates the staged generation. Bumping a
pin upgrades the component; an unchanged lockfile does not make the command a no-op. A new
vendor binary must earn new conformance evidence because the record is keyed by its digest.
Only a first bootstrap may activate without proof as described above; an existing
generation always rolls back on failed or incomplete conformance.

## Requirements

Linux or macOS, Bash 5, Python 3.11 or newer, `flock`, and `curl` or `wget`.

## Documentation

- `docs/hld/unified-harness.md` — what the system is for and what it guarantees
- `docs/lld/unified-harness.md` — how it is built
- `docs/manual/web-surfaces.md` — vendor-native web access and its limits
- `CLAUDE.md` — the development and testing rules for this repository
