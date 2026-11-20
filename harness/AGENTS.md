# Agent notes: harness

`ec2bench` is the Python harness for the fleet that `stacks/` creates.
`README.md` is the operator contract. `../docs/runbook.md` covers the AWS side.

The package started as `fastmem`'s `bench/ec2bench/` and holds no
benchmark-specific code. A project keeps its adapter next to its workload and
adds this package as a git dependency on a tested full commit of this repository.

## The API adapters use

Breaking any of these names needs a new minor version and a change in every
consumer:

- `Config.load`, `root`, `results_dir`, `cache_dir`, `ttl`, `select`.
- `Fleet(config)`: `instances`, `selected`, `launch`, `terminate`, `extend`,
  `reap`, `outputs`, `templates`, `one`, `wait_running`, `wait_terminated`, `converge`,
  `push_key`, `profile`; the module functions `tags`, `expiry`,
  `reap_candidates`. `outputs()` is resolved from AWS and the configuration;
  it reads no OpenTofu state, even though the name suggests it does.
- `Box`, `RemoteError`: `run`, `upload`, `upload_contents`, `upload_checkout`,
  `download`, `ready`, `shell`, `poweroff`, `connect`.
- `cli.box_for`, `cli.ensure_up`, `cli.console`. The adapters import these;
  they are not private even though they live in the command module.
  `box_for(fleet, instance)` takes an optional third argument, `outputs`, that
  it ignores, so adapters written for v0.1 still call it.

The development API removed `Config.ssh_key`, `Fleet.key_path`, and
`outputs()["key_file"]`, and changed the `Box` constructor: SSH goes through SSM with an EC2 Instance
Connect key, and no key file or public IP exists.

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
and drops the basename. Its optional `exclude` iterable passes rsync filter
patterns, `delete=True` mirrors deletions, and `timeout` bounds rsync in seconds.
Its defaults preserve the old, unfiltered behavior and 300-second timeout.
`Box.upload_checkout` transfers the paths from `git ls-files`, non-ignored
untracked files, and `.git`. Cache filters never apply to tracked files, and the
remote results directory survives deletion. It rejects a linked worktree before
any sync command. Without Git or a work tree, it warns on stderr and falls back
to `upload_contents`. Both upload shapes exist because adapters use both.

`bench down` calls `Fleet.wait_terminated` after `Fleet.terminate`. An adapter
that powers off or terminates a box must wait for its instance ID before a
relaunch of the same target.

`isolate` returns `Generator[int]`, not `Iterator[int]`: ty rejects the
`Iterator` overload of `contextmanager`. Keep it that way.

## Rules

- The harness launches from launch templates only. Do not add a path that
  creates an `aws_instance`.
- A new tag key needs a policy change in `modules/bench-iam/policy.tf`, and
  `Project` and `ExpiresAt` stay immutable on the role side.
- SSH goes through `ec2bench.ssm` as the ProxyCommand. Do not add a path that
  needs a public IP, an open port, or a key file. The ProxyCommand writes the
  SSH stream to stdout. Nothing in it must print there.
- A `Box` opens one control master per box with `ControlPersist=yes`. Later
  commands make no AWS call. Keep that: it is what lets a long run outlive
  the SSO session.
- `ExpiresAt` is written as `%Y-%m-%dT%H:%M:%SZ`. The reaper and the TTL guard
  both parse that form; a different form ends the instance early.
- `up` reaps before it launches. Keep that order.
- `down` waits until EC2 reports every selected instance as terminated.
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
