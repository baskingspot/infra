# baskingspot/infra: OpenTofu modules and stacks for the org's EC2 benchmark
# fleet. README.md says what lives here. AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Run the module tests: the bench-base and bench-iam OpenTofu tests, the reaper's unit tests, and `tofu validate` on each stack with a fake account ID")]
[group("test")]
test:
    tofu -chdir=modules/bench-base init -backend=false -input=false
    tofu -chdir=modules/bench-base test
    tofu -chdir=modules/bench-iam init -backend=false -input=false
    tofu -chdir=modules/bench-iam test
    uv run python3 -m unittest discover -s modules/bench-iam/reaper -v
    for stack in iam base; do tofu -chdir=stacks/$stack init -backend=false -input=false > /dev/null && TF_VAR_account_id=123456789012 tofu -chdir=stacks/$stack validate; done

[doc("Check OpenTofu (tofu fmt, tflint), Python (ruff, ty), shell (shfmt, shellcheck), Nix, Markdown, the workflows, and this justfile")]
[group("lint")]
lint:
    tofu fmt -check -recursive
    tflint --recursive
    ruff check modules/bench-iam/reaper
    ruff format --check modules/bench-iam/reaper
    ty check --ignore unused-ignore-comment modules/bench-iam/reaper
    shfmt -d stacks/iam/write-credentials.sh
    shellcheck stacks/iam/write-credentials.sh
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md docs
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    tofu fmt -recursive
    ruff format modules/bench-iam/reaper
    shfmt -w stacks/iam/write-credentials.sh
    nix fmt
    oxfmt README.md AGENTS.md docs
    just --fmt

[doc("Everything CI runs")]
[group("ci")]
ci: test lint
