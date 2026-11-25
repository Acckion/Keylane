#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneFileToolsIntegration.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
swiftc -Xfrontend -disable-sandbox -swift-version 5 -target "$(uname -m)-apple-macos26.0" -emit-library -emit-module -module-name KeylaneCore Sources/KeylaneCore/*.swift -lsqlite3 -emit-module-path "$task_directory/KeylaneCore.swiftmodule" -o "$task_directory/libKeylaneCore.dylib"
# Run the picker regression in its own executable and reuse the unsigned Core build.
cp Tests/Integration/picker-resource-route.swift "$task_directory/main.swift"
swiftc -Xfrontend -disable-sandbox -swift-version 5 -target "$(uname -m)-apple-macos26.0" -I "$task_directory" -L "$task_directory" -lKeylaneCore -Xlinker -rpath -Xlinker "$task_directory" \
    Sources/Keylane/AIActionSource.swift Sources/Keylane/AIConversationComposer.swift Sources/Keylane/AIVisualSource.swift Sources/Keylane/AIFileAttachment.swift \
    "$task_directory/main.swift" -o "$task_directory/verify-picker"
"$task_directory/verify-picker"

swiftc -Xfrontend -disable-sandbox -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos26.0" -I "$task_directory" -L "$task_directory" -lKeylaneCore -Xlinker -rpath -Xlinker "$task_directory" Sources/Keylane/AIToolRuntime.swift Sources/Keylane/AIChatProject.swift Sources/Keylane/AIFileToolProvider.swift Tests/Integration/ai-file-tools-main.swift -o "$task_directory/verify"
"$task_directory/verify"
