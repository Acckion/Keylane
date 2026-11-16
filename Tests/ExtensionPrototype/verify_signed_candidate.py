"""Measure a separate App Sandbox candidate with a temporary ad-hoc signature."""
import json
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile

from supervise import run_worker
from verify import check_report


def main(node):
    with tempfile.TemporaryDirectory(prefix="keylane-signed-", dir="/private/tmp") as temporary:
        root = Path(temporary)
        identifier = "org.keylane.extension-isolation-probe"
        bundle = root / "IsolationProbe.app"
        executable_directory = bundle / "Contents" / "MacOS"
        executable_directory.mkdir(parents=True)
        (bundle / "Contents" / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "node",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
        }))
        binary = executable_directory / "node"
        shutil.copyfile(node, binary)
        binary.chmod(0o700)
        for library in (node.parent.parent / "lib").glob("libnode.*.dylib"):
            shutil.copyfile(library, executable_directory / library.name)
        entitlements = root / "entitlements.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
        subprocess.run([
            "/usr/bin/codesign", "--force", "--sign", "-", "--identifier",
            identifier, "--entitlements", entitlements, bundle,
        ], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", bundle], check=True)
        protected_file = root / "protected"
        protected_file.write_text("synthetic")
        (root / "outside-link").symlink_to(protected_file)
        (root / "probe.cjs").write_text("synthetic-read-only-input")
        # Inline the reviewed fixture so the probe can start even if it cannot read its source directory.
        program = Path(__file__).with_name("probe.cjs").read_text() + """
process.argv.splice(1, 0, "fixture");
module.exports().then(report => console.log(JSON.stringify(report))).catch(error => {
  console.error(error);
  process.exitCode = 1;
});
"""
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            report = run_worker(
                [binary, "--jitless", "-e", program, protected_file, str(listener.getsockname()[1]), protected_file, root],
                root,
                {"PATH": "/usr/bin:/bin", "HOME": str(root), "TMPDIR": str(root), "OPENSSL_CONF": "/dev/null"},
            )
        check_report("signed candidate", json.loads(report), True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify_signed_candidate.py /absolute/path/to/node")
    try:
        main(Path(sys.argv[1]).resolve(strict=True))
    except RuntimeError as error:
        raise SystemExit(str(error)) from error
    except subprocess.CalledProcessError as error:
        sys.stderr.write(error.stderr.decode(errors="replace") if error.stderr else "")
        raise SystemExit(f"Signed candidate exited with status {error.returncode}") from error
