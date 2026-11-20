"""The SSH path: an SSM ProxyCommand and an EC2 Instance Connect key, no public IP."""

import json
import shlex
import sys
from collections.abc import Iterable
from pathlib import Path
from typing import Any

import pytest
from ec2bench import ssm
from ec2bench.box import Box, RemoteError, checked, client_key
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

    excluded = [
        "/.git",
        "/.envrc.local",
        "/.terraform",
        "/zig-out",
        "/.zig-cache",
        "/.direnv",
    ]
    box.upload_contents(source, "/root/tls", exclude=excluded, delete=True)

    rsync = commands[-1]
    assert rsync[0] == "rsync"
    assert "--chown=root:root" in rsync
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
    assert "--chown=root:root" in rsync
    assert "--delete" not in rsync
    assert not any(arg.startswith("--exclude=") for arg in rsync)
    assert rsync[-2:] == [f"{source}/", f"{box.destination}:/root/tls/"]


def test_rsync_timeout_reaches_every_transfer_command(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    timeouts: list[float] = []

    def capture(args: list[str], *, timeout: float) -> str:
        if args[0] == "rsync":
            timeouts.append(timeout)
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

    box.upload(source, "/root", timeout=17)
    box.upload_contents(source, "/root/tls", timeout=23)
    box.download("/root/tls/bench-results", tmp_path / "results", timeout=29)

    assert timeouts == [17, 23, 29]


def test_upload_checkout_uses_git_and_preserves_results(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = tmp_path / "checkout"
    source.mkdir()
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg"))
    checked(["git", "init", "--quiet", str(source)], timeout=30)

    fixture = source / "tests/fixtures/certificates/root.pem"
    fixture.parent.mkdir(parents=True)
    fixture.write_text("tracked certificate fixture\n")
    tracked_output = source / "tests/fixtures/zig-out/golden.bin"
    tracked_output.parent.mkdir(parents=True)
    tracked_output.write_text("tracked golden output\n")
    checked(
        [
            "git",
            "-C",
            str(source),
            "add",
            "tests/fixtures/certificates/root.pem",
            "tests/fixtures/zig-out/golden.bin",
        ],
        timeout=30,
    )

    cache = source / "tests/fixtures/zig-out/cache.bin"
    cache.write_text("untracked build output\n")
    (source / ".gitignore").write_text("/.envrc.local\n")
    (source / ".envrc.local").write_text("local-only configuration\n")
    untracked = source / "notes.txt"
    untracked.write_text("untracked source input\n")

    remote = tmp_path / "remote"
    results = remote / "bench-results/run.json"
    results.parent.mkdir(parents=True)
    results.write_text("keep this result\n")
    stale = remote / "stale.txt"
    stale.write_text("remove this file\n")
    nested_stale = remote / "tests/fixtures/stale.txt"
    nested_stale.parent.mkdir(parents=True)
    nested_stale.write_text("remove this nested file\n")

    rsync_timeouts: list[float] = []

    def transfer_locally(args: list[str], *, timeout: float) -> str:
        if args[0] != "rsync":
            return ""
        rsync_timeouts.append(timeout)
        local_args = args.copy()
        local_args.remove("--chown=root:root")
        local_args[-1] = f"{remote}/"
        return checked(local_args, timeout=timeout)

    box = Box(
        "i-0123456789abcdef0",
        tmp_path / "ssh",
        region="us-west-2",
        profile="bench",
        push=lambda _user, _key: None,
    )
    monkeypatch.setattr(box, "connect", lambda: None)
    monkeypatch.setattr("ec2bench.box.checked", transfer_locally)

    box.upload_checkout(source, str(remote), timeout=31)

    assert fixture.read_bytes() == (remote / "tests/fixtures/certificates/root.pem").read_bytes()
    assert (remote / "tests/fixtures/zig-out/golden.bin").read_text() == ("tracked golden output\n")
    assert not (remote / "tests/fixtures/zig-out/cache.bin").exists()
    assert (remote / "notes.txt").read_text() == "untracked source input\n"
    assert not (remote / ".envrc.local").exists()
    assert (remote / ".git/index").exists()
    assert results.read_text() == "keep this result\n"
    assert not stale.exists()
    assert not nested_stale.exists()

    fixture.unlink()
    box.upload_checkout(source, str(remote), timeout=31)

    assert not (remote / "tests/fixtures/certificates/root.pem").exists()
    assert results.read_text() == "keep this result\n"
    assert rsync_timeouts == [31, 31]


def test_upload_checkout_rejects_a_linked_worktree(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    primary = tmp_path / "primary"
    primary.mkdir()
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg"))
    checked(["git", "init", "--quiet", str(primary)], timeout=30)
    checked(
        [
            "git",
            "-C",
            str(primary),
            "-c",
            "user.name=Test User",
            "-c",
            "user.email=test@example.com",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "--allow-empty",
            "--quiet",
            "-m",
            "initial",
        ],
        timeout=30,
    )
    source = tmp_path / "linked"
    checked(
        ["git", "-C", str(primary), "worktree", "add", "--quiet", "-b", "linked", str(source)],
        timeout=30,
    )
    assert (source / ".git").is_file()

    box = Box(
        "i-0123456789abcdef0",
        tmp_path / "ssh",
        region="us-west-2",
        profile="bench",
        push=lambda _user, _key: None,
    )
    uploads: list[str] = []
    monkeypatch.setattr(box, "_upload", lambda *_args, **_kwargs: uploads.append("upload"))

    with pytest.raises(ValueError, match=r"linked worktree.*standalone checkout"):
        box.upload_checkout(source, "/root/tls")
    assert not uploads


def test_upload_checkout_falls_back_to_plain_sync(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    source = tmp_path / "not-a-repo"
    source.mkdir()
    calls: list[dict[str, Any]] = []

    box = Box(
        "i-0123456789abcdef0",
        tmp_path / "ssh",
        region="us-west-2",
        profile="bench",
        push=lambda _user, _key: None,
    )

    def upload_contents(
        source_arg: Path,
        destination: str,
        *,
        exclude: Iterable[str] = (),
        delete: bool = False,
        timeout: float = 300,
    ) -> None:
        assert source_arg == source
        calls.append(
            {
                "destination": destination,
                "exclude": list(exclude),
                "delete": delete,
                "timeout": timeout,
            }
        )

    monkeypatch.setattr(box, "upload_contents", upload_contents)
    box.upload_checkout(source, "/root/tls", results_dir="artifacts", timeout=37)

    assert len(calls) == 1
    assert calls[0]["destination"] == "/root/tls"
    assert calls[0]["delete"] is True
    assert calls[0]["timeout"] == 37
    captured = capsys.readouterr()
    assert "source is not a Git repository" in captured.err
    assert "full-tree sync" in captured.err
    assert set(calls[0]["exclude"]) == {
        ".bench-cache/",
        ".direnv/",
        ".envrc.local",
        ".terraform/",
        ".venv/",
        ".zig-cache/",
        "/artifacts/",
        "__pycache__/",
        "node_modules/",
        "zig-out/",
    }
