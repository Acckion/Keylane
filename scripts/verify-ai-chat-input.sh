#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneChatInput.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
cp Tests/Integration/ai-chat-input-main.swift "$task_directory/main.swift"
swiftc -Xfrontend -disable-sandbox -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
  Sources/Keylane/AIInteractionPreferences.swift Sources/Keylane/AIChatTextInput.swift \
  "$task_directory/main.swift" -o "$task_directory/verify"
"$task_directory/verify"
