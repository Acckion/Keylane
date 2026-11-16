"""Connect the actual Swift broker to the reviewed Node fixture by two anonymous pipes."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

from supervise import WorkerStopped, run_worker, stop_group
from verify import policy

HERE = Path(__file__).resolve().parent


def verify_wire(node, broker, root, mode):
    session = str(uuid.uuid4()).upper()
    profile = root / "wire.sb"
    profile.write_text(policy(node, root, root / "no-write"))
    expects_timeout = mode in ("stall", "backpressure")
    # The fixture stdout is protocol only. Diagnostics travel on a separate pipe.
    with subprocess.Popen(
        [broker, session, "2"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, start_new_session=True,
    ) as host:
        try:
            try:
                run_worker(
                    ["/usr/bin/sandbox-exec", "-f", profile, node, root / "wire.cjs", session, "2", mode],
                    root, {"PATH": "/usr/bin:/bin", "HOME": str(root), "OPENSSL_CONF": "/dev/null"},
                    stdin=host.stdout, stdout=host.stdin, timeout=0.8 if expects_timeout else 5,
                )
            except WorkerStopped as error:
                if not expects_timeout or str(error) != "timeout":
                    raise
            else:
                if expects_timeout:
                    raise RuntimeError(f"{mode}: worker unexpectedly completed before timeout")
            host.stdin.close()
            host.stdout.close()
            expected = 0 if mode == "roundtrip" else 2
            status = host.wait(timeout=3)
            if status != expected:
                raise RuntimeError(f"broker {mode}: exit {status}, expected {expected}: {host.stderr.read(4096)!r}")
        finally:
            if host.returncode is None:
                stop_group(host.pid)
                host.wait()
    print(f"wire {mode}: pass", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_wire.py /absolute/path/to/node /absolute/path/to/broker")
    node, broker = (Path(path).resolve(strict=True) for path in sys.argv[1:])
    with tempfile.TemporaryDirectory(prefix="keylane-wire-", dir="/private/tmp") as directory:
        root = Path(directory)
        shutil.copyfile(HERE / "wire.cjs", root / "wire.cjs")
        for mode in ("roundtrip", "partial", "stall", "backpressure"):
            verify_wire(node, broker, root, mode)
