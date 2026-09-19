#!/usr/bin/env bash
# Usage text. Commands a later slice delivers are listed as such rather than omitted,
# so a user reading this knows what is coming and what is merely missing.

ihar_usage() {
  cat <<'TEXT'
ihar — one control and security plane for native coding agents.

usage: ihar [global flags] <command> [command flags] [-- agent args]

commands
  claude | codex        launch the agent in this project
  check                 print the effective profile and what is enforced
  install               install every pinned component under this user, no sudo
  update                re-install what the lockfile now pins, then re-prove the hooks
  homes list | clean    project state directories
  daemon status | stop | restart
                        the managed Codex app-server daemon
  sessions list | resume <id> | name <id> <title>
                        canonical sessions across both vendors
  switch --to <vendor>  carry this session into the other vendor

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

everything after -- goes to the agent verbatim:
  ihar codex -- mcp list

not yet delivered
  web, acp
TEXT
}
