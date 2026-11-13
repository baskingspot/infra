"""SSH ProxyCommand: an SSM session to the SSH port of a box.

ssh runs `python -m ec2bench.ssm <instance-id> <port> <region> <profile>`.
The module starts an AWS-StartSSHSession session with the same credentials
as the rest of the harness, then execs session-manager-plugin, which carries
the SSH bytes over the session. This is what `aws ssm start-session` does,
without the AWS CLI. The box needs no inbound rule: its SSM agent connects
out to AWS.
"""

import json
import os
import shutil
import sys

import boto3

PLUGIN = "session-manager-plugin"
DOCUMENT = "AWS-StartSSHSession"


def plugin() -> str:
    """The plugin path, or the reason it is missing."""
    path = shutil.which(PLUGIN)
    if path is None:
        raise FileNotFoundError(
            f"{PLUGIN} is not on PATH. Add ssm-session-manager-plugin from nixpkgs to the devshell."
        )
    return path


def main(argv: list[str] | None = None) -> None:
    instance_id, port, region, profile = argv or sys.argv[1:]
    session = boto3.Session(profile_name=profile or None, region_name=region)
    client = session.client("ssm")
    parameters = {
        "Target": instance_id,
        "DocumentName": DOCUMENT,
        "Parameters": {"portNumber": [port]},
    }
    response = client.start_session(**parameters)
    # The argument order of `aws ssm start-session`: response, region, the
    # operation, profile, request parameters, endpoint.
    os.execv(  # noqa: S606 — replace this process with the plugin; ssh owns its stdio
        executable := plugin(),
        [
            executable,
            json.dumps(response),
            region,
            "StartSession",
            profile,
            json.dumps(parameters),
            client.meta.endpoint_url,
        ],
    )


if __name__ == "__main__":
    main()
