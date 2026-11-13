#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneCalculator.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
target="$(uname -m)-apple-macos26.0"
swiftc -swift-version 5 -target "$target" -emit-library -emit-module -module-name KeylaneCore Sources/KeylaneCore/*.swift -lsqlite3 -emit-module-path "$task_directory/KeylaneCore.swiftmodule" -o "$task_directory/libKeylaneCore.dylib"
cp Tests/Integration/calculator-main.swift "$task_directory/main.swift"
swiftc -swift-version 5 -target "$target" -I "$task_directory" -L "$task_directory" -lKeylaneCore -Xlinker -rpath -Xlinker "$task_directory" Sources/Keylane/CalculatorExchangeRates.swift "$task_directory/main.swift" -o "$task_directory/verify"
"$task_directory/verify" "$@"
