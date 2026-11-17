"""Verify the no-view HUD presentation handshake using the pinned UUID fixture."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys


def verify(scratch, sentinel, action, acknowledge, framed=False):
    uuid = "550e8400-e29b-41d4-a716-446655440000"
    command = [scratch / "host", scratch / "Image", scratch / "noview.cpio",
               sentinel, "noview-app", f"{action}:{uuid}", uuid.replace("-", "")]
    name = f"hud-{'framed-' if framed else ''}{action}-{'ack' if acknowledge else 'rejected'}"
    environment = {**os.environ, "KEYLANE_ACKNOWLEDGE_HUD": "1", "KEYLANE_INTERACTIVE_TOAST": "1" if framed else "0"}
    with (scratch / f"{name}.log").open("wb") as log, subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, bufsize=0,
        env=environment,
    ) as process:
        try:
            process.stdin.write(json.dumps({"defaultAction": action}).encode() + b"\n")
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                assert selector.select(8), "HUD request did not arrive"
                event = process.stdout.readline()
                assert event.startswith(b"guest-hud="), event
                assert not selector.select(0.25), "Guest completed before receiving the presentation acknowledgment"
            body = json.loads(event.removeprefix(b"guest-hud="))
            assert body["text"].endswith(uuid), body
            assert body["popToRootType"] == "default" and body["clearRootSearch"] is False, body
            if framed:
                # A previous toast selection on the same channel cannot acknowledge a HUD.
                process.stdin.write(b"00000000-0000-0000-0000-000000000000:primary\n")
                process.stdin.write(b"hud:shown\n" if acknowledge else b"hud:rejected\n")
            elif acknowledge:
                process.stdin.write(b"\x01")
            process.stdin.close()
            process.stdin = None
            result, _ = process.communicate(timeout=15)
            status = process.returncode
            (scratch / f"{name}.out").write_bytes(event + result)
            if acknowledge:
                assert status == 0 and f"guest-result={action}:{uuid}".encode() in result, result
                assert b"guest probe passed" in result and b"state=0" in result, result
            else:
                assert status != 0 and b"guest-result=" not in result, result
                assert b"guest probe failed" in result and b"state=0" in result, result
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)


if __name__ == "__main__":
    scratch = Path(sys.argv[1]).resolve()
    sentinel = Path(sys.argv[2]).resolve()
    for framed in (False, True):
        for action, acknowledge in (("copy", True), ("paste", True), ("copy", False)):
            verify(scratch, sentinel, action, acknowledge, framed)
    print("PASS HUD waits for presentation acknowledgment, rejects missing acknowledgment, and reclaims the VM")
