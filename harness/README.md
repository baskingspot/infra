# ec2bench

`ec2bench` manages a tag-scoped fleet of EC2 boxes for one benchmark project. It
launches instances from the launch templates in `stacks/base`, waits for SSH and
the image marker, and keeps every instance inside a deadline. The project's
adapter supplies the benchmark commands.

The package holds no benchmark-specific code. The Terraform that creates the IAM
user, the reaper, the launch templates, and the box image lives in this
repository. `../docs/runbook.md` covers the AWS side.

## Install

In a project that runs benchmarks:

```sh
uv add "ec2bench @ git+https://github.com/baskingspot/infra@v0.1.0#subdirectory=harness"
```

Or pin the tag in `pyproject.toml`:

```toml
[project]
dependencies = ["ec2bench"]

[project.scripts]
bench = "ec2bench.cli:main"

[tool.uv.sources]
ec2bench = { git = "https://github.com/baskingspot/infra", rev = "v0.1.0", subdirectory = "harness" }
```

The project owns the command name. The library exports `main` and the adapter
hook; the `bench` line above is the project's choice. `python -m ec2bench` runs
the same CLI without an entry point. The adapter stays in the benchmark project,
in the same `uv` project as the dependency.

## Configuration

`bench.toml` at the repository root configures the project:

```toml
[project]
name = "baskingspot-bench"
region = "us-west-2"
profile = "baskingspot-bench"
adapter = "example_bench"
image_version = "1"
ssh_user = "root"
results_dir = "bench-results"
cache_dir = ".bench-cache"

[fleet]
default_ttl = "4h"
max_ttl = "12h"
default_owner = "agent"

[targets.c7i]
instance_type = "c7i.xlarge"
arch = "x86_64"
```

`project.name` and `project.region` must equal `project` and `region` in
`stacks/base`. `project.image_version` must equal `image_version` there.

The harness needs no checkout of the infrastructure repository and no OpenTofu
state. It finds the launch template for each architecture by name,
`<project.name>-<arch>`, and checks the `Project` tag. It reads the SSH key from
`~/.ssh/<project.name>.pem`, which the base stack writes. Set `ssh_key` to use
another path.

The architecture is `x86_64` or `arm64`. Unknown keys belong to the adapter.
`AWS_PROFILE` overrides `project.profile`. `up` and `extend` reject a TTL above
`fleet.max_ttl`.

## Commands

| Command                | Effect                                                                     |
| ---------------------- | -------------------------------------------------------------------------- |
| `bench up <target>...` | Reap, launch missing targets, wait for SSH and the image marker            |
| `bench ls`             | Show the project's instances, their state, and the time left before expiry |
| `bench ssh <target>`   | Open a shell, or run one command (`bench ssh c7i -- uname -a`)             |
| `bench extend`         | Set `ExpiresAt` to now plus a TTL                                          |
| `bench reap`           | Terminate expired instances and instances without a valid `ExpiresAt`      |
| `bench down <target>`  | Terminate the named targets                                                |
| `bench down --all`     | Terminate every instance tagged with the project                           |
| `bench facts`          | Collect and cache host facts by instance ID                                |
| `bench watch <dir>`    | Exit when `<dir>/summary.json` exists                                      |

`bench --help` lists the adapter's commands too.

## Adapter interface

The module named by `project.adapter` exports `register(group)`. It attaches
Click commands to the group, and each command receives `Config` through
`click.pass_obj`.

```python
import click
from ec2bench.config import Config


def register(group: click.Group) -> None:
    @group.command()
    @click.pass_obj
    def run(config: Config) -> None:
        click.echo(config.root)
```

`Fleet` owns the instance lifecycle. `Box` runs commands and moves files over
SSH. `parallel` returns one outcome per task, so one failed target does not
cancel the others.

```python
from ec2bench.box import Box
from ec2bench.fleet import Fleet

fleet = Fleet(config)
outputs = fleet.outputs()
instance = fleet.one("c7i")
box = Box(
    instance["InstanceId"],
    instance["PublicIpAddress"],
    fleet.key_path(outputs),
    config.cache_dir / "ssh",
)
box.run("uname -a")
```

`facts.collect(box, config.results_dir)` caches the CPU, topology, kernel, and
image facts under `results_dir/.facts/`. If a probe fails, its value is null and
`errors` records why.

`isolation.isolate` reserves the last physical core and pins the housekeeping
slice to the others. It restores the original cpuset properties when the context
exits, and raises if the restore fails. `isolation.run_isolated` runs a command
in `bench.slice` through a transient systemd unit, outside the SSH slice.

```python
from ec2bench.isolation import isolate, run_isolated, stop_isolated

with isolate(box, facts["topology"]) as cpu:
    try:
        run_isolated(
            box,
            cpu,
            ["/opt/benchmark"],
            unit=f"{run_id}-r0",
            output=f"/tmp/{run_id}.out",
            error=f"/tmp/{run_id}.stderr",
        )
    finally:
        stop_isolated(box, run_id)
```

The adapter must stop its units before the isolation context exits, and must use
a unit name that is safe for a shell. `run_isolated` forwards remote stderr on
failure. The SSH user must be able to run `systemctl` and write `/run/`; the
library adds no `sudo`.

`runs.create_run` writes a manifest with the git HEAD, the diff, and the
instance IDs. Adapters keep local artifacts in `config.cache_dir` and
`config.results_dir`.

## Safety

Every launch tags the instance, its volume, and its network interface with
`Project` and `ManagedBy=ec2bench`. The instance also gets `Name`, `Target`,
`ExpiresAt`, and `Owner`. `ExpiresAt` is RFC 3339 UTC with a `Z` suffix.

Two mechanisms stop a box. The TTL guard runs on the box, and the reaper runs
outside it. The reaper ends an instance at the earlier of `ExpiresAt` and 24
hours after launch, and it ends an instance whose tag is missing or malformed.
The reaper is the guarantee; the guard is the fast path.

`up` reaps before it launches. A failed readiness wait terminates that instance.
A failed target does not stop the other targets.

An atomic directory on the box, `/run/ec2bench-isolation.lock`, prevents two
harness processes from isolating the same CPU. An active `ec2bench-run-*` unit
also fails the claim. A hard controller failure can leave the lock behind; the
next run then refuses that box. To recover, check that no other harness owns the
box, stop the abandoned units, restore the cpuset properties or reboot, then
remove the lock.

## Limits

Concurrent `up` commands for one target are unsupported, because EC2 tags are
not an atomic claim. After a launch the harness keeps the earliest instance and
terminates the duplicates it discovers. `ls` flags a duplicate target.

The harness launches from launch templates only; it does not adopt
`aws_instance` resources. One instance per target. There is no placement-group
selection, no second client box, no SSH over a private address, no CPU isolation
without systemd, and no privilege escalation.
