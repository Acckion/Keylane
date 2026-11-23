#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneResourceBudget.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
swiftc -O -swift-version 5 -emit-library -emit-module -module-name KeylaneCore Sources/KeylaneCore/CostBoundedCache.swift -emit-module-path "$task_directory/KeylaneCore.swiftmodule" -o "$task_directory/libKeylaneCore.dylib"
cp Tests/Integration/resource-budget-main.swift "$task_directory/main.swift"
swiftc -O -D KEYLANE_RESOURCE_TESTING -swift-version 5 -I "$task_directory" -L "$task_directory" -lKeylaneCore -Xlinker -rpath -Xlinker "$task_directory" Sources/Keylane/ResourceCache.swift "$task_directory/main.swift" -o "$task_directory/verify"
"$task_directory/verify"
