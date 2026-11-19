"""The SSH path: an SSM ProxyCommand and an EC2 Instance Connect key, no public IP."""

import json
import shlex
import sys
from pathlib import Path
from typing import Any

import pytest
from ec2bench import ssm
from ec2bench.box import Box, RemoteError, client_key
from ec2bench.cli import box_for
from ec2bench.config import Config
from ec2bench.fleet import Fleet


def option(box: Box, name: str) -> str:
    values = [value for value in box.options if value.startswith(f"{name}=")]
    assert len(values) == 1, name
    return values[0].removeprefix(f"{name}=")


def test_box_reaches_the_instance_id_through_ssm(tmp_path: Path) -> None:
    box = Box(
        "i-0123456789abcdef0",
        tmp_path,
        region="us-west-2",
        profile="bench",
        push=lambda _user, _key: None,
    )
    assert box.destination == "root@i-0123456789abcdef0"
    assert shlex.split(option(box, "ProxyCommand")) == [
        sys.executable,
        "-m",
        "ec2bench.ssm",
        "%h",
        "%p",
        "us-west-2",
        "bench",
    ]
    assert option(box, "HostKeyAlias") == "i-0123456789abcdef0"
    assert option(box, "ControlPersist") == "yes"
    assert box.options[box.options.index("-i") + 1] == str(tmp_path / "id_ed25519")


def test_client_key_is_created_once(tmp_path: Path) -> None:
    key = client_key(tmp_path / "ssh")
    public = key.with_suffix(".pub").read_text()
    assert public.startswith("ssh-ed25519 ")
    assert (key.stat().st_mode & 0o777) == 0o600
    assert client_key(tmp_path / "ssh") == key
    assert key.with_suffix(".pub").read_text() == public
    assert sorted(path.name for path in (tmp_path / "ssh").iterdir()) == [
        "id_ed25519",
        "id_ed25519.pub",
    ]


def test_connect_pushes_the_key_without_a_master(tmp_path: Path) -> None:
    pushed: list[tuple[str, str]] = []
    box = Box(
        "i-0123456789abcdef0",
        tmp_path,
        region="us-west-2",
        profile="bench",
        push=lambda user, key: pushed.append((user, key)),
    )
    box.connect()
    assert pushed == [("root", (tmp_path / "id_ed25519.pub").read_text())]


def test_a_refused_push_is_a_transport_error(tmp_path: Path) -> None:
    def refuse(_user: str, _key: str) -> None:
        raise RuntimeError("instance is not running")

    box = Box("i-0123456789abcdef0", tmp_path, region="us-west-2", profile="bench", push=refuse)
    with pytest.raises(RemoteError, match="EC2 Instance Connect: instance is not running"):
        box.connect()


def test_box_for_needs_no_public_ip(config: Config, monkeypatch: pytest.MonkeyPatch) -> None:
    sent: list[dict[str, str]] = []

    class InstanceConnect:
        def send_ssh_public_key(self, **kwargs: str) -> None:
            sent.append(kwargs)

    monkeypatch.setenv("AWS_PROFILE", "baskingspot-bench")
    fleet = Fleet(config, client=object())
    fleet._instance_connect = InstanceConnect()
    box = box_for(fleet, {"InstanceId": "i-0123456789abcdef0"})
    assert shlex.split(option(box, "ProxyCommand"))[-2:] == ["us-west-2", "baskingspot-bench"]
    box.push("root", "ssh-ed25519 AAAA test")
    assert sent == [
        {
            "InstanceId": "i-0123456789abcdef0",
            "InstanceOSUser": "root",
            "SSHPublicKey": "ssh-ed25519 AAAA test",
        }
    ]


def test_proxy_execs_the_plugin_with_the_session(monkeypatch: pytest.MonkeyPatch) -> None:
    requests: list[dict[str, Any]] = []
    executed: list[tuple[str, list[str]]] = []

    class Client:
        class meta:
            endpoint_url = "https://ssm.us-west-2.amazonaws.com"

        def start_session(self, **kwargs: Any) -> dict[str, Any]:
            requests.append(kwargs)
            return {"SessionId": "s-1", "TokenValue": "token", "StreamUrl": "wss://example"}

    class Session:
        def __init__(self, *, profile_name: str | None, region_name: str) -> None:
            assert (profile_name, region_name) == ("bench", "us-west-2")

        def client(self, name: str) -> Client:
            assert name == "ssm"
            return Client()

    monkeypatch.setattr(ssm.boto3, "Session", Session)
    monkeypatch.setattr(ssm, "plugin", lambda: "/bin/session-manager-plugin")
    monkeypatch.setattr(ssm.os, "execv", lambda path, argv: executed.append((path, argv)))
    ssm.main(["i-0123456789abcdef0", "22", "us-west-2", "bench"])

    parameters = {
        "Target": "i-0123456789abcdef0",
        "DocumentName": "AWS-StartSSHSession",
        "Parameters": {"portNumber": ["22"]},
    }
    assert requests == [parameters]
    path, argv = executed[0]
    assert path == "/bin/session-manager-plugin"
    assert argv[0] == path
    assert json.loads(argv[1])["SessionId"] == "s-1"
    assert argv[2:5] == ["us-west-2", "StartSession", "bench"]
    assert json.loads(argv[5]) == parameters
    assert argv[6] == "https://ssm.us-west-2.amazonaws.com"


def test_missing_plugin_names_the_package(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PATH", "/nonexistent")
    with pytest.raises(FileNotFoundError, match="ssm-session-manager-plugin"):
        ssm.plugin()


def test_upload_contents_filters_and_deletes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    commands: list[list[str]] = []

    def capture(args: list[str], *, timeout: float) -> str:
        assert timeout > 0
        commands.append(args)
        return ""

    source = tmp_path / "checkout"
    source.mkdir()
    box = Box(
        "i-0123456789abcdef0",
        tmp_path / "ssh",
        region="us-west-2",
        profile="bench",
        push=lambda _user, _key: None,
    )
    monkeypatch.setattr(box, "connect", lambda: None)
    monkeypatch.setattr("ec2bench.box.checked", capture)

    excluded = [".git", ".zig-cache", "zig-out", ".direnv", ".envrc.local"]
    box.upload_contents(source, "/root/tls", exclude=excluded, delete=True)

    rsync = commands[-1]
    assert rsync[0] == "rsync"
    assert "--delete" in rsync
    assert [arg for arg in rsync if arg.startswith("--exclude=")] == [
        f"--exclude={pattern}" for pattern in excluded
    ]
    assert rsync[-2:] == [f"{source}/", f"{box.destination}:/root/tls/"]


def test_upload_contents_stays_unfiltered_by_default(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    commands: list[list[str]] = []

    def capture(args: list[str], *, timeout: float) -> str:
        assert timeout > 0
        commands.append(args)
        return ""

    source = tmp_path / "checkout"
    source.mkdir()
    box = Box(
        "i-0123456789abcdef0",
        tmp_path / "ssh",
        region="us-west-2",
        profile="bench",
        push=lambda _user, _key: None,
    )
    monkeypatch.setattr(box, "connect", lambda: None)
    monkeypatch.setattr("ec2bench.box.checked", capture)

    box.upload_contents(source, "/root/tls")

    rsync = commands[-1]
    assert rsync[0] == "rsync"
    assert "--delete" not in rsync
    assert not any(arg.startswith("--exclude=") for arg in rsync)
    assert rsync[-2:] == [f"{source}/", f"{box.destination}:/root/tls/"]
