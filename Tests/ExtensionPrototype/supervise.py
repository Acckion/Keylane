"""Bounded test supervisor. It only executes the checked-in local fixtures."""
import os
import selectors
import signal
import subprocess
import time

OUTPUT_LIMIT = 32 * 1024


class WorkerStopped(Exception):
    pass


def stop_group(pid):
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        # macOS can return EPERM when the group contains only unreaped zombies.
        processes = subprocess.check_output(["/bin/ps", "-axo", "pgid=,stat="], text=True)
        for line in processes.splitlines():
            group, state = line.split()
            if int(group) == pid and not state.startswith("Z"):
                raise


def run_worker(command, cwd, environment, timeout=5, cancelled=lambda: False,
               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE):
    with subprocess.Popen(
        command,
        cwd=cwd,
        env=environment,
        stdin=stdin,
        stdout=stdout,
        stderr=subprocess.PIPE,
        start_new_session=True,
    ) as process, selectors.DefaultSelector() as selector:
        streams = {"stdout": bytearray(), "stderr": bytearray()}
        if process.stdout is not None:
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        deadline = time.monotonic() + timeout
        try:
            exited = False
            while selector.get_map() or not exited:
                if not exited and os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT):
                    # Keep the exited leader unreaped until its process group has been stopped.
                    stop_group(process.pid)
                    exited = True
                    if not selector.get_map():
                        break
                if cancelled():
                    raise WorkerStopped("cancelled")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise WorkerStopped("timeout")
                if not selector.get_map():
                    time.sleep(min(remaining, 0.02))
                    continue
                for key, _ in selector.select(min(remaining, 0.02)):
                    chunk = os.read(key.fd, 8192)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    if sum(map(len, streams.values())) + len(chunk) > OUTPUT_LIMIT:
                        raise WorkerStopped("output limit")
                    streams[key.data].extend(chunk)
        finally:
            if not exited:
                stop_group(process.pid)
            process.wait()

        if process.returncode != 0:
            raise subprocess.CalledProcessError(
                process.returncode, command, bytes(streams["stdout"]), bytes(streams["stderr"])
            )
        return bytes(streams["stdout"])
