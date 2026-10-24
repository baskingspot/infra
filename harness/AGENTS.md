# Agent notes: harness

`ec2bench` is the Python harness for the fleet that `stacks/` creates.
`README.md` is the operator contract. `../docs/runbook.md` covers the AWS side.

The package started as `fastmem`'s `bench/ec2bench/` and holds no
benchmark-specific code. A project keeps its adapter next to its workload and
adds this package as a git dependency on a tag of this repository.

## The API adapters use

Breaking any of these names needs a new minor version and a change in every
consumer:

- `Config.load`, `root`, `results_dir`, `cache_dir`, `ssh_key`, `ttl`,
  `select`.
- `Fleet(config)`: `instances`, `selected`, `launch`, `terminate`, `extend`,
  `reap`, `outputs`, `templates`, `one`, `key_path`, `wait_running`,
  `converge`; the module functions `tags`, `expiry`, `reap_candidates`.
  `outputs()` is resolved from AWS and the configuration; it reads no OpenTofu
  state, even though the name suggests it does.
- `Box`, `RemoteError`: `run`, `upload`, `upload_contents`, `download`,
  `ready`, `shell`.
- `cli.box_for`, `cli.ensure_up`, `cli.console`. The adapters import these;
  they are not private even though they live in the command module.
- `parallel`, `Outcome`, `progress`, `check_cancelled`, `runs.watch`,
  `runs.create_run`, `runs.write_manifest`, `runs.git`, `runs.validate_label`,
  `facts.collect`, `facts.topology`, `isolation.isolate`, `run_isolated`,
  `stop_isolated`, `select_cpu`.
- `register(group)` on the module named by `project.adapter`.
- `cli.main` is the whole entry point. The package ships no console script:
  each project declares its own, usually `bench = "ec2bench.cli:main"`.
  `python -m ec2bench` runs the CLI without an entry point. Do not add a
  `bench` script back to `harness/pyproject.toml`; the command name belongs
  to the project.

`Box.upload` copies a file or directory and keeps its basename.
`Box.upload_contents` copies the contents of a directory into the destination
and drops the basename. Both exist because the two adapters use the two shapes.

`isolate` returns `Generator[int]`, not `Iterator[int]`: ty rejects the
`Iterator` overload of `contextmanager`. Keep it that way.

## Rules

- The harness launches from launch templates only. Do not add a path that
  creates an `aws_instance`.
- A new tag key needs a policy change in `modules/bench-iam/policy.tf`, and
  `Project` and `ExpiresAt` stay immutable on the user side.
- `ExpiresAt` is written as `%Y-%m-%dT%H:%M:%SZ`. The reaper and the TTL guard
  both parse that form; a different form ends the instance early.
- `up` reaps before it launches. Keep that order.
- A failure to reach SSH or the image marker terminates the instance. Do not
  leave a box behind for a retry to find.
- The tests use `moto`. Do not add a test that calls AWS.

## Tests

The root `pyproject.toml` is a uv workspace; this package is a member and
the dev tools (pytest, moto, ruff, ty) are in the root dev group. One venv
serves the whole repository. `just test` runs `uv run pytest` at the root,
which covers these suites and the reaper's. The four generic suites cover
configuration, the fleet lifecycle against `moto`, CPU selection and
restoration, and per-task error isolation. Adapter tests belong to the
adapter's repository.
