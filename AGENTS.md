# AGENTS.md

Working notes for AI coding agents in baskingspot/infra.

## What this is

The org's shared EC2 benchmark infrastructure. It started as a copy of `fastmem-zig`'s `infra/`. The default fleet is `baskingspot-bench`. The Python harness is not in this repo. Read `~/code/baskingspot/IDEAS.md`, sections "Directions from Matt, 2026-10-16" and "infra decisions", before you change its shape.

## Environment

The flake is the tool contract, from `baskingspot/nix`. `nix develop` provides OpenTofu. The justfile is the command interface: `just test`, `just lint`, `just ci`.

## Rules

- Never apply a stack, and never run an AWS command, unless Matt asked for that exact action. A stack creates IAM users and a Lambda in a real account.
- Never commit state, a private key, an AWS account ID, or an SSO profile name. `.gitignore` covers state and `*.pem`. The account ID is the required variable `account_id`, read from `TF_VAR_account_id`, and the profile names come from the environment. A person sets them in `.envrc.local`. `.envrc.local.example` shows the names. Test fixtures use a fake account, `123456789012`.
- The policy keeps cost controls out of the harness's reach: the instance allowlist lives in the IAM stack, not in `bench.toml`, because the agent can edit `bench.toml`. Keep it that way.
- Change a module only with its tests: `tofu test` in `modules/*/tests/` and the reaper's unit tests.
- Format OpenTofu with `tofu fmt`. Recipes carry `[doc]` and `[group]`. Commit messages are one line, `area: summary`, and every commit is signed.
