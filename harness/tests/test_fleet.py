from datetime import UTC, datetime, timedelta
from typing import Any
from unittest.mock import patch

import boto3
import pytest
from click.testing import CliRunner
from ec2bench import cli as cli_module
from ec2bench.cli import ensure_up
from ec2bench.config import Config
from ec2bench.fleet import Fleet, expiry, reap_candidates, tags
from moto import mock_aws


def instance(identifier: str, expires: str | None) -> dict[str, Any]:
    return {
        "InstanceId": identifier,
        "Tags": [] if expires is None else [{"Key": "ExpiresAt", "Value": expires}],
    }


def test_reap_selection() -> None:
    now = datetime(2026, 9, 23, tzinfo=UTC)
    instances = [
        instance("old", "2026-09-22T00:00:00Z"),
        instance("missing", None),
        instance("bad", "yesterday"),
        instance("naive", "2026-09-25T00:00:00"),
        instance("equal", "2026-09-23T00:00:00Z"),
        instance("future", "2026-09-24T00:00:00Z"),
    ]
    assert reap_candidates(instances, now) == ["old", "missing", "bad", "naive", "equal"]
    assert expiry("2026-09-23T02:00:00+02:00") == now


@mock_aws
def test_fleet(config: Config) -> None:
    client = boto3.client(
        "ec2", region_name="us-west-2", aws_access_key_id="testing", aws_secret_access_key="testing"
    )
    template(client, "test-bench-x86_64", "test-bench")
    template(client, "test-bench-arm64", "test-bench")
    fleet = Fleet(config, client)
    assert fleet.instances() == []
    with patch.object(client, "run_instances", wraps=client.run_instances) as request:
        launched = fleet.launch("intel", "4h", "2xlarge")
    specs = {
        spec["ResourceType"]: spec["Tags"] for spec in request.call_args.kwargs["TagSpecifications"]
    }
    assert set(specs) == {"instance", "volume", "network-interface"}
    for resource, resource_tags in specs.items():
        values = {tag["Key"]: tag["Value"] for tag in resource_tags}
        assert values["Project"] == "test-bench"
        assert values["ManagedBy"] == "ec2bench"
        if resource == "instance":
            assert set(values) == {"Project", "ManagedBy", "Name", "Target", "ExpiresAt", "Owner"}
            assert values["ExpiresAt"].endswith("Z")
    for operation in (
        lambda: fleet.launch("intel", "30d", None),
        lambda: fleet.extend(["intel"], "30d"),
    ):
        with pytest.raises(ValueError, match=r"exceeds fleet\.max_ttl"):
            operation()
    assert launched["InstanceType"] == "c7i.2xlarge"
    assert tags(launched)["Project"] == "test-bench"
    assert tags(launched)["ManagedBy"] == "ec2bench"
    assert tags(launched)["Owner"] == "agent"
    expires = expiry(tags(launched)["ExpiresAt"])
    assert expires is not None
    assert expires > datetime.now(UTC) + timedelta(hours=3)
    assert fleet.launch("intel", "4h", None)["InstanceId"] == launched["InstanceId"]
    assert len(fleet.instances()) == 1
    client.run_instances(ImageId="ami-12345678", MinCount=1, MaxCount=1, InstanceType="c7i.xlarge")
    assert len(fleet.instances()) == 1
    fleet.extend(["intel"], "2h")
    extended = expiry(tags(fleet.one("intel"))["ExpiresAt"])
    assert extended is not None
    assert timedelta(hours=1) < extended - datetime.now(UTC) <= timedelta(hours=2)
    client.delete_tags(Resources=[launched["InstanceId"]], Tags=[{"Key": "ExpiresAt"}])
    assert fleet.reap() == [launched["InstanceId"]]
    assert fleet.instances() == []


@mock_aws
def test_duplicate_convergence(config: Config) -> None:
    client = boto3.client(
        "ec2", region_name="us-west-2", aws_access_key_id="testing", aws_secret_access_key="testing"
    )
    response = client.run_instances(
        ImageId="ami-12345678",
        InstanceType="c7i.xlarge",
        MinCount=2,
        MaxCount=2,
        TagSpecifications=[
            {
                "ResourceType": "instance",
                "Tags": [
                    {"Key": "Project", "Value": "test-bench"},
                    {"Key": "Target", "Value": "intel"},
                ],
            }
        ],
    )
    instances = response["Instances"]
    fleet = Fleet(config, client)
    expected = min(instances, key=lambda item: (item["LaunchTime"], item["InstanceId"]))
    assert (
        fleet.converge("intel", list(reversed(instances)))["InstanceId"] == expected["InstanceId"]
    )
    assert [item["InstanceId"] for item in fleet.instances()] == [expected["InstanceId"]]


def template(client: Any, name: str, project: str) -> str:
    return client.create_launch_template(
        LaunchTemplateName=name,
        LaunchTemplateData={"ImageId": "ami-12345678"},
        TagSpecifications=[
            {
                "ResourceType": "launch-template",
                "Tags": [{"Key": "Project", "Value": project}],
            }
        ],
    )["LaunchTemplate"]["LaunchTemplateId"]


@mock_aws
def test_template_discovery(config: Config) -> None:
    client = boto3.client(
        "ec2", region_name="us-west-2", aws_access_key_id="testing", aws_secret_access_key="testing"
    )
    expected = {
        "x86_64": template(client, "test-bench-x86_64", "test-bench"),
        "arm64": template(client, "test-bench-arm64", "test-bench"),
    }
    template(client, "other-bench-x86_64", "other-bench")
    fleet = Fleet(config, client)
    assert fleet.templates() == expected
    assert fleet.outputs() == {"launch_template_ids": expected}


@mock_aws
def test_missing_template(config: Config) -> None:
    client = boto3.client(
        "ec2", region_name="us-west-2", aws_access_key_id="testing", aws_secret_access_key="testing"
    )
    template(client, "test-bench-x86_64", "test-bench")
    fleet = Fleet(config, client)
    assert set(fleet.templates()) == {"x86_64"}
    with pytest.raises(ValueError, match=r"No launch template 'test-bench-arm64'"):
        fleet.template("arm64")


@mock_aws
def test_ensure_up_requires_the_plugin(config: Config, monkeypatch: pytest.MonkeyPatch) -> None:
    client = boto3.client(
        "ec2", region_name="us-west-2", aws_access_key_id="testing", aws_secret_access_key="testing"
    )
    monkeypatch.setenv("PATH", "/nonexistent")
    with pytest.raises(FileNotFoundError, match="session-manager-plugin"):
        ensure_up(Fleet(config, client), ["arm64"], "1h")


def test_wait_terminated_uses_the_ec2_waiter(config: Config) -> None:
    waits: list[dict[str, Any]] = []

    class Waiter:
        def wait(self, **kwargs: Any) -> None:
            waits.append(kwargs)

    class Client:
        def get_waiter(self, name: str) -> Waiter:
            assert name == "instance_terminated"
            return Waiter()

    fleet = Fleet(config, Client())
    fleet.wait_terminated([])
    assert waits == []

    fleet.wait_terminated(["i-one", "i-two"])
    assert waits == [
        {
            "InstanceIds": ["i-one", "i-two"],
            "WaiterConfig": {"Delay": 5, "MaxAttempts": 120},
        }
    ]


def test_down_waits_for_termination(config: Config, monkeypatch: pytest.MonkeyPatch) -> None:
    events: list[tuple[str, list[str]]] = []

    class FakeFleet:
        def selected(self, names: list[str]) -> list[dict[str, Any]]:
            assert names == ["intel"]
            return [{"InstanceId": "i-0123456789abcdef0"}]

        def terminate(self, ids: list[str]) -> None:
            events.append(("terminate", ids))

        def wait_terminated(self, ids: list[str]) -> None:
            events.append(("wait", ids))

    monkeypatch.setattr(cli_module, "Fleet", lambda _config: FakeFleet())
    monkeypatch.chdir(config.root)
    result = CliRunner().invoke(cli_module.cli, ["down", "intel"])

    assert result.exit_code == 0, result.output
    assert events == [
        ("terminate", ["i-0123456789abcdef0"]),
        ("wait", ["i-0123456789abcdef0"]),
    ]
