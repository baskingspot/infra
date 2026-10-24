"""Fleet fixtures: a project configuration and an AWS profile that works offline."""

import os
from pathlib import Path

import pytest
from ec2bench.config import Config


@pytest.fixture(autouse=True)
def aws_profile(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """The devshell exports AWS_PROFILE; give the tests a profile that works."""
    profiles = ("unused", "baskingspot-bench")
    credentials = tmp_path / "credentials"
    credentials.write_text(
        "\n".join(
            f"[{profile}]\naws_access_key_id = testing\naws_secret_access_key = testing"
            for profile in profiles
        )
        + "\n"
    )
    config = tmp_path / "config"
    config.write_text(
        "\n".join(f"[profile {profile}]\nregion = us-west-2" for profile in profiles) + "\n"
    )
    monkeypatch.setenv("AWS_SHARED_CREDENTIALS_FILE", str(credentials))
    monkeypatch.setenv("AWS_CONFIG_FILE", str(config))
    monkeypatch.setenv("AWS_PROFILE", os.environ.get("AWS_PROFILE", "unused"))


@pytest.fixture
def config(tmp_path: Path) -> Config:
    (tmp_path / "bench.toml").write_text("""
[project]
name = "test-bench"
region = "us-west-2"
profile = "unused"
adapter = "test_adapter"
remote_dir = "/root/bench"
image_version = "1"
extra_key = "ignored"
[fleet]
default_ttl = "4h"
[targets.intel]
instance_type = "c7i.xlarge"
arch = "x86_64"
zig_cpu = "sapphirerapids"
[targets.arm]
instance_type = "c8g.xlarge"
arch = "arm64"
zig_cpu = "neoverse_v2"
""")
    return Config.load(tmp_path)
