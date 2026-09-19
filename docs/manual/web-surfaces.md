# Native web surfaces

`ihar` does not host a second agent backend. Terminal and browser access share the
vendor's runtime home, authentication, transcript and remote protocol.

## Claude Remote Control

Use either spelling:

```bash
ihar web claude
ihar claude --web
```

`--name <title>` is passed both as the native session title and as the optional
Remote Control name. The selected profile must list `claude` under `remote`; among
shipped profiles that means `standard`. `protected` refuses the request with exit 2
because Claude rejects Remote Control behind its explicit model gateway.

Expected native fragment:

```text
claude ... --remote-control [name] ...
```

## Codex hosted Remote Control

Use either spelling:

```bash
ihar web codex
ihar --profile protected codex --web
```

The launch performs this vendor-native sequence under the rendered `CODEX_HOME`:

```text
codex app-server daemon start
codex app-server daemon enable-remote-control
codex remote-control pair
codex --remote unix://<runtime>/app-server-control/app-server-control.sock
```

The pairing command prints the short-lived code. The daemon record under project
state marks `remote_control: true`. A later launch reconciles binary and config hash
before reusing the daemon. `codex agents` under the same `CODEX_HOME` is the native
session browser and must show sessions served by that daemon.

## Codex LAN listener

LAN access stays explicit vendor passthrough so every authentication input remains
visible:

```bash
ihar codex -- app-server --listen ws://127.0.0.1:4500 --ws-auth capability-token --ws-token-file /absolute/path/to/token
```

Non-loopback listeners require one of Codex's websocket authentication modes. ihar
does not generate, store or print those credentials.

## Verification record

Measured against Codex CLI 0.154.0: top-level `--remote` accepts `ws://`, `wss://`
and `unix://`; `app-server --listen` owns websocket authentication flags; daemon
`enable-remote-control` and `remote-control pair` are separate commands. The focused
test exercises profile refusal, dry-run argv, LAN passthrough, daemon start, enable,
pair, record update and TUI attachment with an isolated vendor fake.
