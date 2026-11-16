#!/usr/bin/env python3
"""Production transaction engine, temporary file backend, restrictive Seatbelt.

Never run the transaction fixture if the deny probes fail. This does not launch
the app, access cfprefsd, test native panels, or establish installed-app acceptance.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
base = Path(tempfile.mkdtemp(prefix="KeylaneConfigurationContained.", dir="/private/tmp"))
data = base / "data"
build = base / "build"
outside = base / "outside"
for directory in (data, build, outside):
    directory.mkdir(mode=0o700)
canary = outside / "canary.txt"
canary.write_text("synthetic boundary canary")
(data / "escape").symlink_to(outside, target_is_directory=True)
home, temporary = data / "home", data / "tmp"
home.mkdir(mode=0o700)
temporary.mkdir(mode=0o700)
child_environment = {"PATH": "/usr/bin:/bin", "HOME": str(home), "TMPDIR": str(temporary) + "/",
                     "LANG": "C", "LC_ALL": "C"}
profile = base / "fixture.sb"
profile.write_text("""(version 1)
(deny default)
(import "/System/Library/Sandbox/Profiles/dyld-support.sb")
(deny sysctl-write)
(deny network*)
(deny mach-lookup)
(deny file-read* (subpath "/Users") (subpath "/System/Volumes/Data/Users"))
(allow syscall*)
(allow mach-bootstrap)
(allow process-exec)
(allow sysctl-read)
(allow file-read-metadata (literal "/") (literal "/private") (literal "/private/tmp") %s)
(allow file-read* (subpath "/System/Library") (subpath "/System/Cryptexes") (subpath "/System/Volumes/Preboot/Cryptexes") (subpath "/usr/lib") (subpath "/usr/share")
 (literal "/usr/bin/touch") (literal "/bin/cat") (literal "/dev/urandom") (literal "/dev/null") %s %s)
(allow file-map-executable (subpath "/System/Library") (subpath "/System/Cryptexes") (subpath "/System/Volumes/Preboot/Cryptexes") (subpath "/usr/lib") (literal "/usr/bin/touch") (literal "/bin/cat") %s)
(allow file-write* %s)
""" % (f"(literal {json.dumps(str(base))})", f"(subpath {json.dumps(str(build))})",
       f"(subpath {json.dumps(str(data))})", f"(subpath {json.dumps(str(build))})", f"(subpath {json.dumps(str(data))})"))


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sandbox(*command, must_succeed=True):
    stdout, stderr = data / "command.stdout", data / "command.stderr"
    with stdout.open("w") as output, stderr.open("w") as errors:
        completed = subprocess.run(["/usr/bin/sandbox-exec", "-f", str(profile), *map(str, command)],
                                   stdin=subprocess.DEVNULL, stdout=output, stderr=errors, timeout=60,
                                   cwd=data, env=child_environment)
    result = subprocess.CompletedProcess(completed.args, completed.returncode, stdout.read_text(), stderr.read_text())
    if must_succeed and result.returncode:
        raise RuntimeError(f"Contained command failed (exit={result.returncode}): " + result.stderr[-3000:])
    return result


try:
    # Establish enforcement before compiling or launching the transaction chain.
    sandbox("/usr/bin/touch", data / "allowed")
    require(sandbox("/bin/cat", data / "allowed").stdout == "", "Inside-root read failed")
    require(sandbox("/usr/bin/touch", outside / "blocked", must_succeed=False).returncode != 0, "Outside write was not denied")
    require(not (outside / "blocked").exists(), "Outside file was created")
    require(sandbox("/bin/cat", canary, must_succeed=False).returncode != 0, "Outside read was not denied")
    require(sandbox("/usr/bin/touch", data / "escape/blocked", must_succeed=False).returncode != 0, "Symlink escape was not denied")
    require(not (outside / "blocked").exists(), "Outside file was created")
    alias = Path("/System/Volumes/Data") / str(canary).lstrip("/")
    if alias.exists():
        require(sandbox("/bin/cat", alias, must_succeed=False).returncode != 0, "APFS alias read was not denied")
        print("CONTAINMENT_APFS_ALIAS_READ_DENIED_OK", flush=True)
    else:
        print("CONTAINMENT_APFS_ALIAS_NOT_PRESENT", flush=True)
    print("CONTAINMENT_PREFLIGHT_ALLOW_ROOT_DENY_OUTSIDE_READ_WRITE_SYMLINK_OK", flush=True)
    environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(build / "modules"))
    target = subprocess.check_output(["uname", "-m"], text=True).strip() + "-apple-macos26.0"
    subprocess.run(["swiftc", "-swift-version", "5", "-module-cache-path", str(build / "modules"), "-target", target, "-emit-library", "-emit-module",
                    "-module-name", "KeylaneCore", *map(str, sorted((repo / "Sources/KeylaneCore").glob("*.swift"))),
                    "-lsqlite3", "-emit-module-path", str(build / "KeylaneCore.swiftmodule"),
                    "-o", str(build / "libKeylaneCore.dylib")], check=True, env=environment)
    source = build / "main.swift"
    shutil.copy2(repo / "Tests/Integration/configuration-contained-main.swift", source)
    binary = build / "ConfigurationContained"
    subprocess.run(["swiftc", "-swift-version", "5", "-module-cache-path", str(build / "modules"), "-target", target, "-I", str(build), "-L", str(build),
                    "-lKeylaneCore", "-Xlinker", "-rpath", "-Xlinker", str(build), str(source), "-o", str(binary)],
                   check=True, env=environment)
    for phase in ("seed", "stage", "apply", "cancel-and-undo", "undo", "rollback", "readback-and-rollback-failure", "changed-and-corrupt"):
        result = sandbox(binary, phase, data)
        print(result.stdout.strip(), flush=True)
    for path in data.rglob("*.plist"):
        require(path.stat().st_mode & 0o777 == 0o600, "Fixture plist is not owner-only")
    require((data / "recovery").stat().st_mode & 0o777 == 0o700, "Recovery directory is not private")
    print("CONTAINED_PRIVATE_FILES_AND_NEW_PROCESS_CHAIN_OK", flush=True)
finally:
    shutil.rmtree(base)
