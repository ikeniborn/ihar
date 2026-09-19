# ihar

One control and security plane for native coding agents.

`ihar` launches the vendors' own `claude` and `codex` binaries — it does not wrap, patch
or replace them. What it adds is the part the vendors leave to you: one place that decides
what an agent may reach, proves the decision is actually in force before the agent starts,
and refuses to launch when it cannot.

## Why

Two agents, two configuration formats, two hook systems, two sandbox models. Keeping a
security rule true in both by hand is how it quietly stops being true in one. `ihar`
renders both configurations from a single profile, verifies the vendor accepted them, and
makes an unproven guarantee a failure rather than a footnote.

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
git clone <this repository> ihar
cd ihar
./ihar.sh install
```

That builds the store, links `ihar` into `~/.local/bin`, creates the Python environment,
downloads the components the lockfile pins — verifying each against its recorded digest —
and runs the hook conformance suite the enforced profiles require.

The specialised Firecracker guest comes from a compatible, locally built asset directory.
Its `firecracker`, `vmlinux`, `rootfs.ext4`, `client_key`, `client_key.pub` and
`host_key.pub` files are all validated before one pinned version is activated atomically:

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

`ihar web claude|codex` and the equivalent launch `--web` flag use each vendor's
native remote bridge. Claude Remote Control is available only in profiles that list
Claude under `remote`; Codex starts its managed app-server daemon, prints a pairing
code, and attaches the TUI to that daemon. For an authenticated LAN listener, pass
Codex's own `app-server --listen` and `--ws-auth` arguments after `--`.

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

## Update

```bash
ihar update
```

Install and update are the same operation. Each component compares the version the
lockfile pins with the one recorded beside it, so bumping the lockfile is what upgrades and
an unchanged lockfile makes the run a no-op. A vendor upgrade re-runs the conformance suite,
because the record is keyed by the binary's digest — a new binary has not earned the old
pass.

## Requirements

Linux or macOS, Bash 5, Python 3.11 or newer, `flock`, and `curl` or `wget`.

## Documentation

- `docs/hld/unified-harness.md` — what the system is for and what it guarantees
- `docs/lld/unified-harness.md` — how it is built
- `CLAUDE.md` — the development and testing rules for this repository
