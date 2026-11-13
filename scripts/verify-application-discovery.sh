#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/keylane-discovery-check.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
cp Tests/Integration/application-discovery-main.swift "$task_directory/main.swift"
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" -emit-library -emit-module -module-name KeylaneCore Sources/KeylaneCore/*.swift -lsqlite3 -emit-module-path "$task_directory/KeylaneCore.swiftmodule" -o "$task_directory/libKeylaneCore.dylib"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" -I "$task_directory" -L "$task_directory" -lKeylaneCore -Xlinker -rpath -Xlinker "$task_directory" Sources/Keylane/ApplicationDiscovery.swift "$task_directory/main.swift" -o "$task_directory/verify"
mkdir "$task_directory/fixtures"
"$task_directory/verify" "$task_directory/fixtures"
