# infra

This repository holds the durable AWS resources, the box image, and the
harness of the benchmark fleet. The harness launches and terminates the
instances through the EC2 API. The contract between the two is the `project`
and `region` values, `image_version`, and the stack outputs.

## Layout

| Path                    | Content                                                                                                         | Who applies it                        |
| ----------------------- | --------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| `stacks/iam/`           | Root stack: the bench role, the box role, their policies, and the reaper                                        | A human                               |
| `stacks/base/`          | Root stack: the egress-only security group and the launch templates                                             | A human                               |
| `stacks/base/image.nix` | An example project NixOS module that the box configuration imports                                              | `stacks/base/` puts it in `user_data` |
| `modules/bench-iam/`    | Module: `policy.tf` (the bench role policies), `box.tf` (the box role), `reaper.tf` and `reaper/` (the reaper)  | `stacks/iam/` uses it                 |
| `modules/bench-base/`   | Module: launch templates, and `image.nix.tftpl` (the box configuration: the TTL guard and EC2 Instance Connect) | `stacks/base/` uses it                |
| `harness/`              | The Python package `ec2bench`: the fleet commands, SSH through SSM, and the adapter contract                    | A consumer pins a tag of it           |

## Configuration

Each root stack sets `project`, `region`, and `account_id` in `locals`. The
values are `baskingspot-bench`, `us-west-2`, and the account ID in `TF_VAR_account_id`. `project` and
`region` must be equal to `project.name` and `project.region` in
the harness configuration. The AWS provider refuses
every other account.

The instance allowlist is `instance_families` in `stacks/iam/main.tf`. It does not
come from the harness configuration. The agent can edit that file, and a cost control
must not follow a file that the agent edits.

## Prerequisites

- Run each command from the repository root.
- Run each tool from the devshell. Enter it with `nix develop`, or put
  `nix develop -c` before each command.
- The devshell of a project that runs the harness must provide
  `ssm-session-manager-plugin` from nixpkgs. SSH to a box goes through it.

## The SSH path

No box accepts inbound traffic. The security group has no inbound rule, and
no key pair exists. A box keeps a public IP for outbound traffic only.

The harness reaches a box in three steps:

1. `ec2-instance-connect:SendSSHPublicKey` puts a public key in the instance
   metadata. The box accepts the key for 60 seconds.
2. `ssm:StartSession` with the `AWS-StartSSHSession` document opens a
   session. The SSM agent on the box connects out to AWS and forwards the
   session to `localhost:22`.
3. `ssh` authenticates with the key. sshd gets the key from the EC2
   Instance Connect scripts, which check the AWS signature first.

The first connection opens an SSH control master. Later commands and `rsync`
use the master and make no AWS call. A new master needs a valid AWS session.

## The lifetime guarantee

Two mechanisms stop a box. The reaper is the guarantee. The TTL guard is the
fast path.

| Mechanism | Where it runs                        | Who controls it                    |
| --------- | ------------------------------------ | ---------------------------------- |
| Reaper    | A Lambda function, outside the boxes | The `stacks/iam/` stack (a human)  |
| TTL guard | Each box, from the launch template   | The `stacks/base/` stack (a human) |

The bench role cannot write the launch templates. But the TTL guard has
these gaps:

- The guard arrives in the `user_data`. If the first boot fails, the box
  runs without the guard.
- The bench role can write any `ExpiresAt` value. The guard caps the
  lifetime at 24 hours after boot, but a reboot restarts that count.
- A box that hangs cannot power itself off.

The reaper does not depend on the box, on the bench role, or on an AWS
session of a person.

EventBridge runs the reaper every 5 minutes. The reaper terminates each
instance with the project `Project` tag if one of these conditions is true:

- The instance is `stopped` or `stopping`.
- The instance has no `ExpiresAt` tag, or the tag is not an RFC 3339 UTC
  time such as `2026-09-24T04:00:00Z`.
- The current time is after `ExpiresAt`.
- The current time is after `LaunchTime` plus `reaper_max_lifetime_hours`.
  The default is 24 hours.

Thus an instance stops at `min(ExpiresAt, LaunchTime + 24h)`, plus at most
one reaper interval. The harness limits a TTL to `fleet.max_ttl`, 12 hours
by default. Only `bench extend` can move `ExpiresAt` past the 24-hour limit,
and the limit still applies. If an instance has termination protection, the
reaper removes it and then terminates the instance.

The reaper also deletes orphans. An orphan is a volume or a network
interface that stays after its instance, because `DeleteOnTermination` is
`false`.

- The reaper deletes a project volume that is `available` and older than
  10 minutes.
- The reaper tags a project network interface that is `available` with
  `OrphanSeenAt`. It deletes the interface 10 minutes after that tag. EC2
  does not record the creation time of a network interface.

The IAM policy keeps each resource visible to the reaper:

- The tag keys must have the exact case. IAM compares the key of
  `aws:RequestTag/Project` without case. Without an `aws:TagKeys` condition,
  a `PROJECT` tag passes the policy, and exact filters do not find it.
- The bench role cannot delete tags.
- The bench role cannot stop or start an instance. A stopped box does not
  run its TTL guard, and a start resets `LaunchTime`.

The reaper finds the `Project` key in any case. It reads `ExpiresAt` only
with the exact case, because the TTL guard does the same.

## Bootstrap the account

Do this procedure one time. It needs a human with the `BENCH_BOOTSTRAP_PROFILE`
SSO profile.

1. Log in to the bootstrap profile:

   ```sh
   aws sso login --profile $BENCH_BOOTSTRAP_PROFILE
   ```

2. Make sure that no old security group has the name `baskingspot-bench-box`
   in the default VPC:

   ```sh
   AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE aws ec2 describe-security-groups --region us-west-2 \
     --filters Name=group-name,Values=baskingspot-bench-box --query 'SecurityGroups[].[GroupId,VpcId]'
   ```

3. If the command shows a group in the default VPC, and no instance uses
   it, delete it:

   ```sh
   AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE aws ec2 delete-security-group --region us-west-2 --group-id <id>
   ```

4. Apply the IAM stack. It creates the bench role, the box role, the
   policies, and the reaper.

   ```sh
   AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE tofu -chdir=stacks/iam init
   AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE tofu -chdir=stacks/iam apply
   ```

5. Add the role profile to `~/.aws/config`. The role is assumed from the
   SSO session, so no key is stored:

   ```sh
   aws configure set role_arn "$(tofu -chdir=stacks/iam output -raw role_arn)" \
     --profile baskingspot-bench
   aws configure set source_profile "$BENCH_BOOTSTRAP_PROFILE" \
     --profile baskingspot-bench
   aws configure set region us-west-2 --profile baskingspot-bench
   ```

6. Log in to the source profile. The SSO session lasts as long as the
   organization allows, and the role credentials refresh themselves:

   ```sh
   aws sso login --profile $BENCH_BOOTSTRAP_PROFILE
   ```

7. Make sure that the profile works:

   ```sh
   AWS_PROFILE=baskingspot-bench aws sts get-caller-identity
   ```

   The `Arn` field must be
   `arn:aws:sts::$TF_VAR_account_id:assumed-role/baskingspot-bench/...`.

8. Do the procedure "Apply the base stack".

9. Do the procedure "Make sure that the reaper runs".

10. Optional: check the policies with IAM Access Analyzer. Findings of type
    `ERROR` or `SECURITY_WARNING` need a fix.

    ```sh
    for output in policy_arn session_policy_arn; do
      arn=$(tofu -chdir=stacks/iam output -raw $output)
      version=$(AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE aws iam get-policy --policy-arn "$arn" \
        --query Policy.DefaultVersionId --output text)
      AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE aws iam get-policy-version --policy-arn "$arn" \
        --version-id "$version" --query PolicyVersion.Document >/tmp/bench-policy.json
      AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE aws accessanalyzer validate-policy --region us-west-2 \
        --policy-type IDENTITY_POLICY --policy-document file:///tmp/bench-policy.json
    done
    AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE aws iam get-role-policy --role-name baskingspot-bench-reaper \
      --policy-name baskingspot-bench-reaper --query PolicyDocument >/tmp/reaper-policy.json
    AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE aws accessanalyzer validate-policy --region us-west-2 \
      --policy-type IDENTITY_POLICY --policy-document file:///tmp/reaper-policy.json
    AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE aws iam get-role-policy --role-name baskingspot-bench-box \
      --policy-name session-manager --query PolicyDocument >/tmp/box-policy.json
    AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE aws accessanalyzer validate-policy --region us-west-2 \
      --policy-type IDENTITY_POLICY --policy-document file:///tmp/box-policy.json
    ```

## Change the IAM stack

A change to `stacks/iam/` or to `modules/bench-iam/` needs a human.

1. If the change needs a new launch template, apply the base stack first.
   For example, the policy requires the `Project` tag on new network
   interfaces, and the launch template supplies it.

2. Examine the plan:

   ```sh
   AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE tofu -chdir=stacks/iam plan
   ```

3. Apply the stack:

   ```sh
   AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE tofu -chdir=stacks/iam apply
   ```

4. Do the procedure "Make sure that the policy refuses bad tags".

5. Do the procedure "Make sure that the reaper runs".

## Make sure that the policy refuses bad tags

The commands use `--dry-run`. EC2 checks the permissions and launches
nothing. `DryRunOperation` means "allowed". `UnauthorizedOperation` means
"refused".

1. Get the arm64 launch template:

   ```sh
   lt=$(tofu -chdir=stacks/base output -json launch_template_ids | jq -r .arm64)
   ```

2. Send a request with canonical tags. The result must be
   `DryRunOperation`:

   ```sh
   AWS_PROFILE=baskingspot-bench aws ec2 run-instances --region us-west-2 --dry-run \
     --instance-type c8g.large --launch-template "LaunchTemplateId=$lt,Version=\$Latest" \
     --tag-specifications \
     'ResourceType=instance,Tags=[{Key=Project,Value=baskingspot-bench},{Key=ExpiresAt,Value=2030-01-01T00:00:00Z}]'
   ```

3. Send the same request with the key `PROJECT`. The result must be
   `UnauthorizedOperation`:

   ```sh
   AWS_PROFILE=baskingspot-bench aws ec2 run-instances --region us-west-2 --dry-run \
     --instance-type c8g.large --launch-template "LaunchTemplateId=$lt,Version=\$Latest" \
     --tag-specifications \
     'ResourceType=instance,Tags=[{Key=PROJECT,Value=baskingspot-bench},{Key=ExpiresAt,Value=2030-01-01T00:00:00Z}]'
   ```

## Make sure that SSH works

1. Launch one box from a project checkout:

   ```sh
   uv run bench up <target> --ttl 1h
   ```

2. Run a command on the box. The output must be the kernel name and version:

   ```sh
   uv run bench ssh <target> -- uname -sr
   ```

3. Make sure that a plain shell session fails. The result must be
   `AccessDeniedException`:

   ```sh
   AWS_PROFILE=baskingspot-bench aws ssm start-session --region us-west-2 --target <instance-id>
   ```

4. Terminate the box:

   ```sh
   uv run bench down <target>
   ```

## Make sure that the reaper runs

1. Wait 5 minutes after the apply.

2. Read the log:

   ```sh
   AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE aws logs tail /aws/lambda/baskingspot-bench-reaper \
     --region us-west-2 --since 15m
   ```

3. Make sure that each run wrote one line with `"summary"` in it, and that
   `"errors"` is empty.

To start a run immediately, invoke the function:

```sh
AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE aws lambda invoke --region us-west-2 \
  --function-name baskingspot-bench-reaper /dev/stdout
```

## Operate the reaper

The reaper writes one JSON line for each action and one `summary` line for
each run. Each action line has the resource ID, the reason, and the result.

If an action fails, the run ends with an error after all other actions. The
`Errors` metric of the function counts these runs. No alarm watches it.

To see the decisions of the reaper without a change to AWS, use a dry run:

1. In `stacks/iam/main.tf`, add `reaper_dry_run = true` to `module "bench"`.
2. Apply the IAM stack.
3. Read the log. In a dry run, EC2 checks each call and changes nothing.
   A result of `ok` means that the role has the permission.
4. Remove `reaper_dry_run` and apply the IAM stack again.

To change the maximum lifetime, set `reaper_max_lifetime_hours` in
`module "bench"` in `stacks/iam/main.tf`. Keep it above `fleet.max_ttl`. Then apply
the IAM stack.

## Apply the base stack

A human applies this stack with the bootstrap profile. The bench role can
launch from the launch templates, but it cannot change them.

1. Apply the stack:

   ```sh
   AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE tofu -chdir=stacks/base init
   AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE tofu -chdir=stacks/base apply
   ```

2. Make sure that the outputs exist:

   ```sh
   tofu -chdir=stacks/base output -json
   ```

A consumer harness reads no state. It finds the launch templates by name
(`<project>-<arch>`) and `Project` tag. It needs no key file: it pushes a key
with EC2 Instance Connect for each new connection.

The outputs are:

| Output                | Value                                                           |
| --------------------- | --------------------------------------------------------------- |
| `launch_template_ids` | Map from architecture (`x86_64`, `arm64`) to launch template ID |
| `security_group_id`   | ID of the egress-only security group                            |
| `user_data`           | The rendered NixOS configuration of the boxes                   |

## Change the box image

The box configuration has two parts:

- `modules/bench-base/image.nix.tftpl` holds the fleet contract: the TTL
  guard, the SSM agent, EC2 Instance Connect, nix-ld, the benchmark sysctls,
  and `/etc/bench-image`.
- `stacks/base/image.nix` holds the example project packages. The template imports it.

1. Edit one of the two files.

2. Render the configuration:

   ```sh
   echo 'base64encode(module.bench.user_data)' | tofu -chdir=stacks/base console \
     | tr -d '"' | base64 -d >/tmp/box.nix
   ```

3. Make sure that the file evaluates against the channel of the AMI.
   Do this for `x86_64-linux` and for `aarch64-linux`:

   ```sh
   nix eval --impure --raw \
     -I nixpkgs=https://releases.nixos.org/nixos/25.11/nixos-25.11.12484.b6018f87da91/nixexprs.tar.xz \
     --expr '(import <nixpkgs/nixos> { configuration = /tmp/box.nix; system = "x86_64-linux"; }).config.system.build.toplevel.drvPath'
   ```

4. If the change matters to the harness, increase `image_version` in
   `stacks/base/main.tf`. Set `image_version` in `bench.toml` to the same value.

5. Apply the base stack. The apply adds a new version to each launch
   template.

6. Terminate the boxes. Old boxes keep the old configuration. Run this from
   a project checkout, not from this repository.

   ```sh
   uv run bench down --all
   ```

## Change an AMI

1. Find the new NixOS AMIs. The publisher account is `427812963091`:

   ```sh
   AWS_PROFILE=baskingspot-bench aws ec2 describe-images --region us-west-2 --owners 427812963091 \
     --filters 'Name=name,Values=nixos/25.11*' \
     --query 'sort_by(Images,&CreationDate)[-4:].[ImageId,Name,Architecture]' --output table
   ```

2. Set the IDs in `amis` in `stacks/base/main.tf`.

3. If the NixOS release changes, change these values to the new release:
   - `system.stateVersion` in `modules/bench-base/image.nix.tftpl`
   - the channel URL in the evaluation step of "Change the box image"
   - the comment above `amis` in `stacks/base/main.tf`

4. Do the procedure "Change the box image" from step 2.

## Change the instance allowlist

1. Edit `instance_families` in `stacks/iam/main.tf`.
2. Do the procedure "Change the IAM stack".

## Refresh the session

The bench role has no key to rotate. Its credentials last one hour and refresh
while the SSO session is valid. A new SSH connection needs a valid session.
An open control master makes no AWS call. When a command fails with an
expired token:

```sh
aws sso login --profile $BENCH_BOOTSTRAP_PROFILE
```

## Tear down

1. Terminate all boxes, from a project checkout:

   ```sh
   uv run bench down --all
   ```

2. Destroy the base stack:

   ```sh
   AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE tofu -chdir=stacks/base destroy
   ```

3. Destroy the IAM stack. This step also removes the reaper, so do it last.

   ```sh
   AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE tofu -chdir=stacks/iam destroy
   ```

4. Remove the `[profile baskingspot-bench]` block from `~/.aws/config`.

## Test the modules offline

The tofu tests use mock providers. They need no AWS credentials, and they
create no files. The reaper tests need no AWS SDK.

```sh
tofu -chdir=modules/bench-iam init -backend=false
tofu -chdir=modules/bench-iam test
tofu -chdir=modules/bench-base init -backend=false
tofu -chdir=modules/bench-base test
uv run pytest modules/bench-iam/reaper -v
```

The `bench-iam` tests fail if a policy of the bench role is longer than
6,144 characters, the limit of a managed policy. If that occurs, move
statements to a third managed policy on the role.

## The TTL guard

The TTL guard is the fast path. The reaper is the guarantee. Refer to "The
lifetime guarantee".

Every box runs `bench-ttl-guard.timer` one time each minute. The service
gets an IMDSv2 token and reads the `ExpiresAt` instance tag from
`http://169.254.169.254/latest/meta-data/tags/instance/ExpiresAt`.

- If the box is older than `max_lifetime_hours` since boot, the guard runs
  `poweroff` and reads no tag. The default is 24 hours.

- If the tag is an RFC 3339 UTC time, the guard uses it.
- If the tag is absent or has a different format, the guard uses boot time
  plus 12 hours.
- If IMDS does not answer, the guard uses the last value that it read. If it
  has no value, it uses boot time plus 12 hours.
- If the current time is after the limit, the guard runs `poweroff`. The
  launch template sets shutdown behavior to `terminate`, so EC2 deletes the
  instance and its volume.

To examine the guard on a box, use these commands:

```sh
systemctl list-timers bench-ttl-guard.timer
journalctl -u bench-ttl-guard.service
```

## The IAM policies

`modules/bench-iam/policy.tf` has one comment for each statement. The
`Project` tag is the security boundary. The bench role has two managed
policies.

The EC2 policy allows these things:

- Describe and get all EC2 resources in `us-west-2`.
- Launch On-Demand instances from a project launch template. The request
  must tag the instance, the volume, and the network interface with
  `Project`, and the instance with `ExpiresAt`. A tag from the launch
  template also counts.
- Use only the instance types in the allowlist, and only default tenancy.
- Use the AMI and the security group of the launch template. The AMI must
  come from the NixOS publisher. A request that names a key pair fails.
- Create gp3 volumes of 100 GiB or smaller, with at most 3000 IOPS and
  125 MiB/s. These are the gp3 baseline values, which cost nothing extra.
- Tag new instances, volumes, and network interfaces, and tag existing
  project instances. The keys are `Project`, `ManagedBy`, `Name`, `Target`,
  `ExpiresAt`, and `Owner` only. The `Project` value cannot change.
- Terminate project instances. It cannot stop or start them.

The EC2 policy cannot change a launch template, a security group, or a key
pair. It cannot delete tags. It denies all actions outside `us-west-2`,
except the global actions `sts:GetCallerIdentity` and `iam:PassRole`.

The session policy allows these things:

- `iam:PassRole` for the box role, to EC2 only.
- `ec2-instance-connect:SendSSHPublicKey` for `root` on project instances.
- `ssm:StartSession` on project instances, with the `AWS-StartSSHSession`
  document only. A plain shell session fails.

The bench role cannot change the reaper, the box role, or its own policies.

## The box role

Every box has the instance profile `<project>-box`. Its role allows the
minimal Session Manager actions and nothing else:

- `ssm:UpdateInstanceInformation`
- `ssmmessages:CreateControlChannel` and `ssmmessages:CreateDataChannel`
- `ssmmessages:OpenControlChannel` and `ssmmessages:OpenDataChannel`

The role has no EC2 action, so a box cannot terminate or change another
instance. A box ends itself with `poweroff`, which needs no permission.

## The reaper role

The reaper has its own IAM role. Its policy allows these actions only:

- `ec2:DescribeInstances`, `ec2:DescribeVolumes`, and
  `ec2:DescribeNetworkInterfaces` on all resources.
- `ec2:TerminateInstances` and `ec2:ModifyInstanceAttribute` on project
  instances.
- `ec2:DeleteVolume` and `ec2:DeleteNetworkInterface` on project volumes and
  network interfaces.
- `ec2:CreateTags` on project network interfaces, with the `OrphanSeenAt`
  key only.
- `logs:CreateLogStream` and `logs:PutLogEvents` on the reaper log group.

The log group keeps logs for 30 days (`reaper_log_retention_days`).

## Fault isolation

- If an EC2 call fails with `UnauthorizedOperation` and an encoded message,
  decode the message with the bootstrap profile:

  ```sh
  AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE aws sts decode-authorization-message \
    --encoded-message <message> --query DecodedMessage --output text | jq .
  ```

- If a box does not become ready, read its console output. Then terminate
  the box.

  ```sh
  AWS_PROFILE=baskingspot-bench aws ec2 get-console-output --region us-west-2 \
    --instance-id <id> --latest --output text
  ```

- If a box stopped before its `ExpiresAt`, search the reaper log for its
  instance ID. The action line gives the reason.

- If the base apply fails with `InvalidGroup.Duplicate`, do steps 2 and 3 of
  "Bootstrap the account".

- If SSH to a box fails, make sure that the SSM agent registered. The
  `PingStatus` must be `Online`. The agent needs a few minutes after boot.

  ```sh
  AWS_PROFILE=$BENCH_BOOTSTRAP_PROFILE aws ssm describe-instance-information --region us-west-2 \
    --filters Key=InstanceIds,Values=<id> --query 'InstanceInformationList[].PingStatus'
  ```

## Use it for a project

1. Pick the fleet. The default is one org fleet named `baskingspot-bench`. A project that needs its own fleet sets another `project` value in both stacks.
2. Set `TF_VAR_account_id` and `BENCH_BOOTSTRAP_PROFILE` in `.envrc.local`.
3. If the project uses other instance families, edit `instance_families` in `stacks/iam/main.tf`.
4. Replace `stacks/base/image.nix` with the NixOS module of the project.
5. Do the procedures "Bootstrap the account" and "Apply the base stack".
6. Add the harness to the project's `uv` project and pin a tag of this
   repository. `harness/README.md` has the install form and the adapter
   contract. Add `ssm-session-manager-plugin` to the devshell of the project.
7. Write `bench.toml` with the same `project` and `region`, and the
   `image_version` of the base stack. The harness needs no path to this
   repository.
