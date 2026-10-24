<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="infra" height="48">
  </picture>
</h1>

OpenTofu modules and stacks for the baskingspot EC2 benchmark fleet.

The default fleet is `baskingspot-bench`, in `us-west-2`. Nothing in this repo is applied by CI or by an agent. A person with the right AWS profile applies a stack, using `docs/runbook.md`. The code started as `fastmem-zig`'s `infra/`.

## Layout

| Path                  | Content                                                                                                                                                                                          |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `modules/bench-iam/`  | The IAM user and its policy, and the reaper: a Lambda that terminates any project instance past its `ExpiresAt` tag or its maximum lifetime, and deletes orphaned volumes and network interfaces |
| `modules/bench-base/` | The security group, the key pair, one launch template per architecture, and the NixOS box configuration with a TTL guard                                                                         |
| `stacks/iam/`         | The root stack that applies `bench-iam`. A human applies it                                                                                                                                      |
| `stacks/base/`        | The root stack that applies `bench-base`. The bench profile applies it                                                                                                                           |
| `harness/`            | The Python package `ec2bench`: the fleet commands, the safety rules, and the adapter contract. A consumer pins a tag of it                                                                       |
| `docs/runbook.md`     | The runbook: the lifetime guarantee, the account bootstrap, and every procedure                                                                                                                  |

A harness (`ec2bench`, a Python package) launches and ends instances from the launch templates. It finds a template by name (`<project>-<arch>`) and `Project` tag, and reads the SSH key from `~/.ssh/<project>.pem`, so a consumer needs no checkout of this repository. It lives in `harness/` and installs from a git tag. A project keeps only its adapter and adds this package as a dependency. `harness/README.md` has the configuration and the adapter contract.

## Work on it

`nix develop` provides OpenTofu, `uv`, and the rest of the tools, and `direnv allow` loads them. The Python tools come from the root uv workspace: run `uv sync` once, then `just` works. Copy `.envrc.local.example` to `.envrc.local` and set your account ID and profile names. Nothing here embeds them. `just` lists the recipes, and `just ci` runs the module tests and the lint.

## License

MIT. See `LICENSE`.

The logo files in `docs/static/` are baskingspot marks and are not covered by the MIT license. See `docs/static/LICENSE`.

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
