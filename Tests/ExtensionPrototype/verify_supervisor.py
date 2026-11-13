"""Reproduce successful and failed leaders leaving stdio-free same-group children."""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

from supervise import run_worker

PROGRAM = """
import json, subprocess, sys
child = subprocess.Popen(["/bin/sleep", "5"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(json.dumps(child.pid), flush=True)
raise SystemExit(int(sys.argv[1]))
"""


def is_running(pid):
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
    state = result.stdout.strip()
    return bool(state) and not state.startswith("Z")


with tempfile.TemporaryDirectory(prefix="keylane-supervisor-") as directory:
    for exit_code in (0, 23):
        try:
            output = run_worker([sys.executable, "-c", PROGRAM, str(exit_code)], directory, {})
        except subprocess.CalledProcessError as error:
            if error.returncode != exit_code:
                raise
            output = error.output
        else:
            if exit_code != 0:
                raise RuntimeError("nonzero worker exit was lost")
        pid = json.loads(output)
        try:
            deadline = time.monotonic() + 1
            while is_running(pid) and time.monotonic() < deadline:
                time.sleep(0.02)
            if is_running(pid):
                raise RuntimeError(f"descendant survived worker exit {exit_code}")
        finally:
            if is_running(pid):
                os.kill(pid, signal.SIGKILL)
        print(f"supervisor descendant cleanup: leader status {exit_code}")
