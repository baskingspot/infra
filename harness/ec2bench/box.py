"""SSH transport with bounded commands and multiplexed connections.

No box accepts inbound traffic. ssh reaches a box through an SSM session
(ec2bench.ssm is the ProxyCommand), and authenticates with a key that EC2
Instance Connect pushes for 60 seconds. The first command opens a control
master, and the later commands, rsync included, reuse it without another
AWS call. So a run that outlives the AWS session keeps its connection until
the box goes away.
"""

import contextlib
import hashlib
import shlex
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Iterable
from pathlib import Path


class RemoteError(subprocess.SubprocessError):
    """A transport error with remote diagnostics."""


def checked(args: list[str], *, timeout: float) -> str:
    try:
        return subprocess.run(
            args, check=True, capture_output=True, text=True, timeout=timeout
        ).stdout
    except subprocess.CalledProcessError as error:
        raise RemoteError(f"{error}: {error.stderr[-2000:] if error.stderr else ''}") from error
    except subprocess.TimeoutExpired as error:
        raise RemoteError(f"{error}: {error.stderr[-2000:] if error.stderr else ''}") from error


_key_lock = threading.Lock()


def client_key(directory: Path) -> Path:
    """The private key that EC2 Instance Connect pushes, created on first use.

    The key authorizes nothing alone: a box accepts it for 60 seconds after a
    push, and a push needs the IAM permission and an SSM session to arrive.
    """
    key = directory / "id_ed25519"
    with _key_lock:
        if not key.exists():
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            partial = directory / f"id_ed25519.{threading.get_ident()}.tmp"
            partial.unlink(missing_ok=True)
            partial.with_suffix(".tmp.pub").unlink(missing_ok=True)
            checked(
                [
                    "ssh-keygen",
                    "-q",
                    "-t",
                    "ed25519",
                    "-N",
                    "",
                    "-C",
                    "ec2bench",
                    "-f",
                    str(partial),
                ],
                timeout=30,
            )
            partial.with_suffix(".tmp.pub").replace(key.with_suffix(".pub"))
            partial.replace(key)
    return key


class Box:
    def __init__(
        self,
        instance_id: str,
        cache: Path,
        *,
        region: str,
        profile: str,
        push: Callable[[str, str], None],
        user: str = "root",
    ) -> None:
        """A box reached by instance ID.

        push(user, public_key) sends the key with EC2 Instance Connect. The
        box accepts it for 60 seconds, long enough to open the control master.
        """
        self.instance_id = instance_id
        self.user = user
        self.push = push
        cache.mkdir(parents=True, exist_ok=True)
        self.key = client_key(cache)
        # Unix socket paths have a short limit. Hash the repository-specific directory.
        digest = hashlib.sha256(str(cache.resolve()).encode()).hexdigest()[:12]
        socket = f"/tmp/ec2bench-{digest}-%C"  # noqa: S108 — SSH includes user/host in %C
        proxy = shlex.join([sys.executable, "-m", "ec2bench.ssm", "%h", "%p", region, profile])
        self.options = [
            "-i",
            str(self.key),
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            f"ProxyCommand={proxy}",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=30",
            "-o",
            "ServerAliveInterval=15",
            "-o",
            "ServerAliveCountMax=3",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            f"HostKeyAlias={instance_id}",
            "-o",
            "ControlMaster=auto",
            # The master lives until the box goes away: ServerAlive ends it
            # 45 seconds after the box stops answering. A new master needs
            # AWS credentials, and the master needs none.
            "-o",
            "ControlPersist=yes",
            "-o",
            f"ControlPath={socket}",
            "-o",
            f"UserKnownHostsFile={cache / 'known_hosts'}",
        ]

    def connect(self) -> None:
        """Push the key unless a control master is already open."""
        check = subprocess.run(
            ["ssh", *self.options, "-O", "check", self.destination],
            check=False,
            capture_output=True,
            timeout=10,
        )
        if check.returncode != 0:
            try:
                self.push(self.user, self.key.with_suffix(".pub").read_text())
            except Exception as error:
                # A box that is still booting refuses the key. ready() retries
                # transport errors, so report this as one.
                raise RemoteError(f"EC2 Instance Connect: {error}") from error

    @property
    def destination(self) -> str:
        return f"{self.user}@{self.instance_id}"

    def run(
        self, command: str, *, timeout: float = 120, stream: Callable[[str], None] | None = None
    ) -> str:
        self.connect()
        args = ["ssh", *self.options, self.destination, command]
        if stream is None:
            return checked(args, timeout=timeout)
        output: list[str] = []
        with subprocess.Popen(
            args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        ) as process:
            timed_out = threading.Event()

            def kill() -> None:
                timed_out.set()
                process.kill()

            timer = threading.Timer(timeout, kill)
            timer.start()
            try:
                if process.stdout is not None:
                    for line in process.stdout:
                        output.append(line)
                        stream(line.rstrip())
                process.wait()
            finally:
                timer.cancel()
            if timed_out.is_set():
                raise subprocess.TimeoutExpired(args, timeout)
            if process.returncode:
                raise RemoteError(f"SSH exit {process.returncode}: {''.join(output)[-2000:]}")
        return "".join(output)

    def ready(self, image_version: str, *, timeout: float = 900) -> None:
        deadline = time.monotonic() + timeout
        last_error = "image marker absent"
        while time.monotonic() < deadline:
            try:
                # An SSM session and the SSH handshake take a few seconds.
                actual = self.run("cat /etc/bench-image", timeout=60).strip()
                if actual == image_version:
                    return
                last_error = f"image version {actual!r}, expected {image_version!r}"
            except subprocess.SubprocessError as error:
                last_error = str(error)
            time.sleep(5)
        raise TimeoutError(f"{self.instance_id}: SSH/image deadline: {last_error}")

    def upload(self, source: Path, destination: str) -> None:
        """Copy `source` into `destination` as `<destination>/<source.name>`."""
        self._upload(str(source), destination)

    def upload_contents(
        self,
        source: Path,
        destination: str,
        *,
        exclude: Iterable[str] = (),
        delete: bool = False,
    ) -> None:
        """Copy the contents of the directory `source` into `destination`.

        The destination names the directory directly: no post-upload rename
        depends on the local directory's basename. `exclude` passes rsync
        filter patterns. `delete` removes destination files absent from source.
        """
        options = [f"--exclude={pattern}" for pattern in exclude]
        if delete:
            options.append("--delete")
        self._upload(str(source) + "/", destination, options)

    def _upload(self, source: str, destination: str, options: list[str] | None = None) -> None:
        self.run(f"mkdir -p {shlex.quote(destination)}")
        self._rsync(source, f"{self.destination}:{destination}/", options)

    def download(self, source: str, destination: Path) -> None:
        destination.mkdir(parents=True, exist_ok=True)
        self._rsync(f"{self.destination}:{source}/", str(destination) + "/")

    def _rsync(self, source: str, destination: str, options: list[str] | None = None) -> None:
        self.connect()
        checked(
            [
                "rsync",
                "-az",
                "--protect-args",
                *(options or []),
                "-e",
                shlex.join(["ssh", *self.options]),
                source,
                destination,
            ],
            timeout=300,
        )

    def shell(self, command: tuple[str, ...]) -> int:
        # ssh semantics: the words join with spaces and the remote shell parses
        # them, so `bench ssh t -- 'a | b'` and `bench ssh t -- ls -l` both work.
        self.connect()
        tty = ["-t"] if not command or sys.stdin.isatty() else []
        remote = [" ".join(command)] if command else []
        argv = ["ssh", *self.options, *tty, self.destination, *remote]
        return subprocess.run(argv, check=False).returncode

    def poweroff(self) -> None:
        """Power the box off, which terminates it, with no AWS call.

        The launch template sets the shutdown behavior to terminate. This
        works over an open control master after the AWS session has expired.
        The connection can drop before ssh reports the exit status, so a
        transport error here is not a failure.
        """
        with contextlib.suppress(RemoteError):
            self.run("systemctl --no-block poweroff", timeout=30)
