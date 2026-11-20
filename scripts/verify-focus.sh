#!/bin/bash
# Isolated controller, browser-transport and native-view fixtures. Does not block real apps or tabs.
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/keylane-focus-fixture.XXXXXX)"
task_cleanup() {
    if [[ -f "$task_directory/helper.pid" ]]; then
        read -r task_helper_pid < "$task_directory/helper.pid" || true
        task_helper_command="$(ps -p "${task_helper_pid:-0}" -o command= 2>/dev/null || true)"
        case "$task_helper_command" in
            "$task_directory/FocusBlockedFixture.app/Contents/MacOS/FocusBlockedFixture"*|"${task_directory/\/private\/tmp/\/tmp}/FocusBlockedFixture.app/Contents/MacOS/FocusBlockedFixture"*)
                kill -TERM "$task_helper_pid" 2>/dev/null || true ;;
        esac
    fi
    rm -rf "$task_directory"
}
trap task_cleanup EXIT
task_build_directory="${KEYLANE_FOCUS_BUILD:-/private/tmp/keylane-focus-build}"
swift build --jobs 4 --scratch-path "$task_build_directory" --disable-sandbox
task_binary_directory="$(swift build --scratch-path "$task_build_directory" --show-bin-path --disable-sandbox)"
python3 - "$task_directory/fixture.swift" <<'PYTHON'
import pathlib, sys
fixture = pathlib.Path('Tests/Integration/focus-main.swift').read_text()
header = "import AppKit\nimport SwiftUI\nimport Darwin\nimport KeylaneCore\n@testable import Keylane\n\n"
entry = '@_cdecl("keylane_focus_fixture_main")\n@MainActor public func focusFixtureMain() -> Int32 {\n    do {\n'
footer = '\n        return 0\n    } catch {\n        fputs("Focus fixture: \\(error)\\n", stderr)\n        return 1\n    }\n}\n'
pathlib.Path(sys.argv[1]).write_text(header + entry + fixture + footer)
PYTHON
# Compile against an immutable snapshot; other build commands may refresh the shared cache.
mkdir -p "$task_directory/Dependencies"
for task_dependency in "$task_binary_directory/"*.o "$task_binary_directory/"*.swiftmodule; do
    cp -R "$task_dependency" "$task_directory/Dependencies/"
done
task_object_directory="$task_build_directory/out/Intermediates.noindex/Keylane.build/Debug/Keylane-p.build/Objects-normal/$(uname -m)"
if [[ ! -f "$task_object_directory/main.o" || ! -f "$task_object_directory/Keylane.swiftmodule" ]]; then
    echo "Focus fixture requires the Xcode SwiftPM object layout; no production bootstrap is run." >&2
    exit 1
fi
cp "$task_object_directory/Keylane.swiftmodule" "$task_directory/Dependencies/Keylane.swiftmodule"
mkdir -p "$task_directory/Objects"
task_app_objects=()
for task_object in "$task_object_directory/"*.o; do
    cp "$task_object" "$task_directory/Objects/"
    task_app_objects+=("$task_directory/Objects/$(basename "$task_object")")
done
# Import the actual debug module; an alternate, checked Mach-O entry point bypasses production bootstrap.
swiftc -parse-as-library -emit-object -swift-version 5 -module-name KeylaneFocusFixture \
    -target "$(uname -m)-apple-macos26.0" -I "$task_directory/Dependencies" \
    -I "$task_build_directory/checkouts/Yams/Sources/CYaml/include" \
    "$task_directory/fixture.swift" -o "$task_directory/fixture.o"
swiftc "$task_directory/fixture.o" "${task_app_objects[@]}" \
    "$task_directory/Dependencies/KeylaneCore.o" "$task_directory/Dependencies/KeylaneProviderConfig.o" \
    "$task_directory/Dependencies/Yams.o" "$task_directory/Dependencies/CYaml.o" -lsqlite3 \
    -Xlinker -e -Xlinker _keylane_focus_fixture_main -o "$task_directory/verify"
python3 - "$task_directory/verify" <<'PYTHON'
import pathlib, struct, subprocess, sys
binary = pathlib.Path(sys.argv[1]); data = binary.read_bytes()
assert struct.unpack_from('<I', data)[0] == 0xfeedfacf
commands = struct.unpack_from('<I', data, 16)[0]; offset = 32
entry = text = None
for _ in range(commands):
    command, size = struct.unpack_from('<II', data, offset)
    if command == 0x80000028: entry = struct.unpack_from('<Q', data, offset + 8)[0]
    if command == 0x19 and data[offset + 8:offset + 24].rstrip(b'\0') == b'__TEXT':
        text = struct.unpack_from('<Q', data, offset + 24)[0]
    offset += size
symbols = subprocess.check_output(['nm', '-g', str(binary)], text=True).splitlines()
address = next(int(line.split()[0], 16) for line in symbols if line.split()[-1] == '_keylane_focus_fixture_main')
assert entry is not None and text is not None and entry + text == address, 'Production bootstrap must never be the fixture entry point'
print('PASS fixture entry bypasses production bootstrap')
PYTHON
task_helper_app="$task_directory/FocusBlockedFixture.app"
mkdir -p "$task_helper_app/Contents/MacOS"
cat > "$task_directory/helper.swift" <<'SWIFT'
import AppKit
let pidFile = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("helper.pid")
try? String(ProcessInfo.processInfo.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "Focus — 专用测试应用"
window.orderFront(nil)
app.run()
SWIFT
swiftc "$task_directory/helper.swift" -o "$task_helper_app/Contents/MacOS/FocusBlockedFixture"
python3 - "$task_helper_app/Contents/Info.plist" <<'PYTHON'
import pathlib, plistlib, sys, uuid
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'FocusBlockedFixture', 'CFBundlePackageType': 'APPL',
    'CFBundleIdentifier': 'org.keylane.focus.fixture.' + uuid.uuid4().hex,
    'CFBundleName': 'Focus Blocked Fixture', 'CFBundleVersion': '1', 'LSUIElement': False,
}))
PYTHON
task_runner_app="$task_directory/FocusIntegrationFixture.app"
mkdir -p "$task_runner_app/Contents/MacOS"
mv "$task_directory/verify" "$task_runner_app/Contents/MacOS/verify"
python3 - "$task_runner_app" "$task_helper_app" <<'PYTHON'
import pathlib, plistlib, subprocess, sys, uuid
sys.path.insert(0, 'scripts')
from signing import signing_identity
runner, helper = map(pathlib.Path, sys.argv[1:])
(runner / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'verify', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
    'CFBundleIdentifier': 'org.keylane.focus.fixture.runner.' + uuid.uuid4().hex,
    'CFBundleName': 'Focus Integration Fixture', 'LSUIElement': True,
    'NSAppleEventsUsageDescription': '仅用于 Keylane Focus 隔离验证。',
}))
identity = signing_identity(require_apple_development=True)
for app in (runner, helper):
    subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
PYTHON
"$task_runner_app/Contents/MacOS/verify" "${1:-/private/tmp/keylane-focus-preview}" "$task_helper_app"
