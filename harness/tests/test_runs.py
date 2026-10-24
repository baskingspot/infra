import time
from pathlib import Path

from ec2bench.runs import watch


def test_watch_returns_when_the_summary_appears(tmp_path: Path) -> None:
    (tmp_path / "summary.json").touch()
    assert watch(str(tmp_path), 10) == 0


def test_watch_stops_at_the_deadline(tmp_path: Path) -> None:
    start = time.monotonic()
    assert watch(str(tmp_path), 1) == 1
    assert time.monotonic() - start < 10
