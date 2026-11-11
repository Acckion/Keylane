#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
utility_tmp="$(mktemp -d /private/tmp/KeylaneUtilities.XXXXXX)"
trap 'rm -rf "$utility_tmp"' EXIT
export CLANG_MODULE_CACHE_PATH="$utility_tmp/modules"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" -emit-library -emit-module -module-name KeylaneCore Sources/KeylaneCore/*.swift -lsqlite3 -emit-module-path "$utility_tmp/KeylaneCore.swiftmodule" -o "$utility_tmp/libKeylaneCore.dylib"
cp Tests/Integration/utilities-main.swift "$utility_tmp/main.swift"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" -I "$utility_tmp" -L "$utility_tmp" -lKeylaneCore -Xlinker -rpath -Xlinker "$utility_tmp" Sources/Keylane/NativeUtilities.swift "$utility_tmp/main.swift" -o "$utility_tmp/verify"
"$utility_tmp/verify"
