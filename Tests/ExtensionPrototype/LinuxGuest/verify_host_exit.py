"""Observe two live VM services during a hard host exit and survivor cancellation."""
from contextlib import contextmanager
from pathlib import Path
import signal
import subprocess
import sys
import time

SERVICE = "/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"


def vm_pids():
    snapshot = subprocess.check_output(["/bin/ps", "-axo", "pid=,comm="], text=True)
    return {int(line.split()[0]) for line in snapshot.splitlines() if line.rstrip().endswith(SERVICE)}


def wait_for(predicate, failure, timeout=5):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            raise RuntimeError(failure)
        time.sleep(0.025)


@contextmanager
def host_process(scratch, sentinel, image, phase, log_name):
    log_path = scratch / (log_name + ".log")
    out_path = scratch / (log_name + ".out")
    with log_path.open("wb") as log, out_path.open("wb") as output, subprocess.Popen(
        [scratch / "host", scratch / "Image", scratch / image, sentinel, phase, "unused"],
        stdout=output, stderr=log,
    ) as host:
        try:
            yield host, log_path, out_path
        finally:
            if host.poll() is None:
                host.kill()
                host.wait(timeout=3)


def verify(scratch, sentinel):
    before = vm_pids()
    with host_process(scratch, sentinel, "probe.cpio", "hold", "host-exit") as (target, log, _):
        wait_for(lambda: b"intentionally waiting" in log.read_bytes(), "target guest did not start")
        target_service = vm_pids() - before
        if len(target_service) != 1:
            raise RuntimeError("expected one new target VM service")
        with host_process(scratch, sentinel, "probe.cpio", "hold", "host-survivor") as (survivor, log, out):
            wait_for(lambda: b"intentionally waiting" in log.read_bytes(), "survivor guest did not start")
            survivor_service = vm_pids() - before - target_service
            if len(survivor_service) != 1 or not target_service <= vm_pids():
                raise RuntimeError("expected two independent VM services")
            target.kill()
            if target.wait(timeout=3) != -signal.SIGKILL:
                raise RuntimeError("target did not receive SIGKILL")
            wait_for(lambda: not target_service & vm_pids(), "target VM service survived host exit")
            if survivor.poll() is not None or not survivor_service <= vm_pids():
                raise RuntimeError("unrelated VM did not survive target exit")
            survivor.terminate()
            if survivor.wait(timeout=4) != 1 or b"state=0" not in out.read_bytes():
                raise RuntimeError("survivor did not stop on explicit cancellation")
            wait_for(lambda: not survivor_service & vm_pids(), "cancelled VM service survived")
    print("concurrency: killed VM reclaimed, peer survived and stopped on cancellation")


def verify_no_view_cancel(scratch, sentinel):
    with host_process(scratch, sentinel, "noview.cpio", "noview-cancel", "noview-cancel") as (host, log, out):
        wait_for(lambda: b"Node waiting for host cancellation" in log.read_bytes(), "Node did not finish handshake")
        host.terminate()
        if host.wait(timeout=4) != 1 or b"state=0" not in out.read_bytes():
            raise RuntimeError("no-view VM did not stop on cancellation")
        if b"guest cancellation requested" not in log.read_bytes():
            raise RuntimeError("no-view VM stopped without handling cancellation")
    print("no-view: cancelled after Node handshake and stopped")


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4) or (len(sys.argv) == 4 and sys.argv[3] != "no-view"):
        raise SystemExit("usage: verify_host_exit.py scratch-directory host-sentinel [no-view]")
    paths = (Path(arg).resolve(strict=True) for arg in sys.argv[1:3])
    (verify_no_view_cancel if len(sys.argv) == 4 else verify)(*paths)
