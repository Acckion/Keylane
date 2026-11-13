"""Run the two local fixtures under distinct macOS sandbox profiles."""
import base64
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

from supervise import WorkerStopped, run_worker

FIXTURES = Path(__file__).resolve().parent
DENIALS = {"EACCES", "EPERM"}


def literal(path):
    return f"(literal {json.dumps(str(path))})"


def subtree(path):
    return f"(subpath {json.dumps(str(path))})"


def policy(node, directory, write_directory):
    # This SBPL profile is an experimental macOS backend, not a distribution entitlement.
    readable = " ".join(map(subtree, [directory, "/System", "/usr/lib", "/opt/homebrew/Cellar", "/opt/homebrew/opt"]))
    return f"""
(version 1)
(deny default)
(allow process-exec {literal(node)})
(allow sysctl-read)
(allow file-read-metadata)
(allow file-read-data (require-any {readable} {literal('/')} {literal('/dev/null')} {literal('/dev/urandom')}))
(allow file-write* (require-any {subtree(write_directory)} {literal('/dev/null')}))
"""


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def check_report(label, report, expected_denied):
    print(label, json.dumps(report, sort_keys=True), flush=True)
    violations = []
    for name in ("read", "symlinkRead", "write", "phaseRead", "writeInput", "spawn", "network"):
        outcome = report[name]
        if outcome not in (DENIALS if expected_denied else {"allowed"}):
            violations.append(f"{name}={outcome}")
    if report["inheritedSecret"] is expected_denied:
        violations.append(f"inheritedSecret={report['inheritedSecret']}")
    require(not violations, f"{label} isolation checks failed: {', '.join(violations)}")


def main(node):
    with tempfile.TemporaryDirectory(prefix="keylane-isolation-", dir="/private/tmp") as temporary:
        root = Path(temporary).resolve()
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            port = str(listener.getsockname()[1])
            phases = {}
            for label in ("control", "build", "run"):
                phase = root / label
                phase.mkdir()
                (phase / "output").mkdir()
                (phase / "private").write_text("phase-only")
                shutil.copyfile(FIXTURES / "probe.cjs", phase / "probe.cjs")
                phases[label] = phase
            secret = root / "protected"
            secret.write_text("synthetic-secret")
            for phase in phases.values():
                (phase / "outside-link").symlink_to(secret)

            # Control runs first and modifies its own fixture only.
            control_script = phases["control"] / "extension.cjs"
            shutil.copyfile(FIXTURES / "extension.cjs", control_script)
            control = run_worker(
                [node, control_script, secret, port, phases["build"] / "private"],
                phases["control"], {
                    "PATH": "/usr/bin:/bin", "HOME": str(phases["control"]),
                    "KEYLANE_TEST_SECRET": "synthetic-parent-only",
                },
            )
            check_report("control", json.loads(control), False)
            secret.write_text("synthetic-secret")

            def worker(label, entry, *args, **limits):
                phase = phases[label]
                output = phase / "output"
                profile = root / f"{label}.sb"
                profile.write_text(policy(node, phase, output if label == "build" else phase / "no-write"))
                environment = {
                    "PATH": "/usr/bin:/bin", "HOME": str(phase), "TMPDIR": str(output),
                    "OPENSSL_CONF": "/dev/null",
                }
                return run_worker(
                    ["/usr/bin/sandbox-exec", "-f", profile, node, entry, *args],
                    phase, environment, **limits,
                )

            build = phases["build"]
            shutil.copyfile(FIXTURES / "build.cjs", build / "build.cjs")
            shutil.copyfile(FIXTURES / "extension.cjs", build / "extension.cjs")
            execution = phases["run"]
            report = worker("build", build / "build.cjs", secret, port, execution / "private")
            check_report("build", json.loads(report), True)
            artifact = build / "output" / "extension.cjs"
            require(artifact.read_bytes() == (FIXTURES / "extension.cjs").read_bytes(), "unexpected build artifact")
            shutil.copyfile(artifact, execution / "extension.cjs")
            report = json.loads(worker("run", execution / "extension.cjs", secret, port, build / "private"))
            check_report("run", report, True)
            require(base64.b64decode(report["result"]).decode() == "Keylane 中文", "unexpected runtime result")
            require(secret.read_text() == "synthetic-secret", "protected file changed")

            for label in ("build", "run"):
                check_worker_limits(label, phases[label], worker)


def check_worker_limits(label, phase, worker):
    for name, program, limits in (
        ("timeout", "setInterval(() => {}, 1000)", {"timeout": 0.3}),
        ("cancelled", "setInterval(() => {}, 1000)", {"cancelled": None}),
        ("output limit", "process.stderr.write('x'.repeat(100000))", {}),
    ):
        script = phase / "failure.cjs"
        script.write_text(program)
        if name == "cancelled":
            deadline = time.monotonic() + 0.25
            limits["cancelled"] = lambda: time.monotonic() >= deadline
        try:
            worker(label, script, **limits)
        except WorkerStopped as error:
            require(str(error) == name, f"expected {name}, got {error}")
            print(f"{label} supervisor: {name}", flush=True)
        else:
            raise AssertionError(f"worker unexpectedly finished: {name}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify.py /absolute/path/to/node")
    try:
        main(Path(sys.argv[1]).resolve(strict=True))
    except subprocess.CalledProcessError as error:
        sys.stderr.write(error.stderr.decode(errors="replace") if error.stderr else "")
        raise SystemExit(f"Worker exited with status {error.returncode}") from error
