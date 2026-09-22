#!/usr/bin/env bash
# Usage text. Commands a later slice delivers are listed as such rather than omitted,
# so a user reading this knows what is coming and what is merely missing.

ihar_usage() {
  cat <<'TEXT'
ihar — one control and security plane for native coding agents.

usage: ihar [global flags] <command> [command flags] [-- agent args]

commands
  claude | codex        launch the agent in this project
  check [--diff] [--conformance]
                        print status, compare desired renders, or refresh evidence
  install               install every pinned component under this user, no sudo
  update                re-install what the lockfile now pins, then re-prove the hooks
  homes list | clean | migrate
                        project state directories and legacy import
  daemon status | stop | restart
                        the managed Codex app-server daemon
  sessions list | resume <id> | name <id> <title>
                        canonical sessions across both vendors
  console <action>      start, status, stop or restart the multi-session console
  switch --to <vendor>  carry this session into the other vendor
                        --history summary|transcript selects how much travels
  web <vendor>          start the vendor's native remote surface
  acp <vendor>          start the experimental pinned ACP adapter

global flags
  --profile <name>      standard, protected, isolated
  --dry-run             print the resolved command and environment, launch nothing
  --json                machine-readable output where a command offers it
  --assume-yes          do not ask before removing anything
  -h, --help            this text

launch flags
  --resume <id>         continue a session
  --fork                with --resume, branch instead of continuing
  --name <title>        set the session title
  --model <m>           model for this session
  --effort <e>          reasoning effort for this session
  --approval <policy>   never, on-request, on-failure, untrusted
  --mask-level <l>      off, secrets, standard; may only tighten the profile's floor
  --web                 start the agent's own remote surface

install flags
  --acp                 install lockfile-pinned experimental ACP adapters
  --microvm             import pinned Firecracker assets from IHAR_MICROVM_SOURCE_DIR
  --migrate-store       copy eligible legacy store content before installation

everything after -- goes to the agent verbatim:
  ihar codex -- mcp list

TEXT
}
