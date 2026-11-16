#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/keylane-navigation-check.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
target="$(uname -m)-apple-macos26.0"
swiftc -target "$target" -module-cache-path "$task_directory/cache" -emit-module -emit-library \
    -module-name KeylaneCore Sources/KeylaneCore/*.swift -lsqlite3 \
    -emit-module-path "$task_directory/KeylaneCore.swiftmodule" -o "$task_directory/libKeylaneCore.dylib"
swiftc -target "$target" -module-cache-path "$task_directory/cache" \
    -I "$task_directory" -L "$task_directory" -lKeylaneCore -Xlinker -rpath -Xlinker "$task_directory" \
    Sources/Keylane/SystemNavigation.swift Sources/Keylane/NavigationController.swift \
    Tests/Integration/navigation-main.swift -o "$task_directory/navigation-check"
"$task_directory/navigation-check"
