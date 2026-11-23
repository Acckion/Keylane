#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneTranslatorIntegration.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
swiftc -package-name Keylane -j 2 -swift-version 5 -target "$(uname -m)-apple-macos26.0" -emit-library -emit-module -module-name KeylaneCore Sources/KeylaneCore/*.swift -lsqlite3 -emit-module-path "$task_directory/KeylaneCore.swiftmodule" -o "$task_directory/libKeylaneCore.dylib"
cp Tests/Integration/translator-main.swift "$task_directory/main.swift"
swiftc -package-name Keylane -j 2 -swift-version 5 -target "$(uname -m)-apple-macos26.0" -I "$task_directory" -L "$task_directory" -lKeylaneCore -Xlinker -rpath -Xlinker "$task_directory" \
    Sources/Keylane/TranslatorController.swift Sources/Keylane/TranslatorSpeech.swift Sources/Keylane/TranslatorTextView.swift Sources/Keylane/TranslationSelection.swift \
    Sources/Keylane/AIConfiguration.swift Sources/Keylane/AIRuntime.swift Sources/Keylane/AIToolRuntime.swift Sources/Keylane/AIToolHTTPTransport.swift Sources/Keylane/AIClaudeToolTransport.swift Sources/Keylane/AIStreamProgress.swift Sources/Keylane/AIProviderPreset.swift Sources/Keylane/AIModelMenuCatalog.swift \
    Sources/Keylane/AnthropicAIProtocol.swift Sources/Keylane/AICLIProcess.swift Sources/Keylane/AISubscriptionTransport.swift \
    "$task_directory/main.swift" -o "$task_directory/verify"
"$task_directory/verify"
