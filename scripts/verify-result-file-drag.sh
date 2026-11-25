#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneResultFileDrag.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
export KEYLANE_RESULT_DRAG_TEST_ROOT="$task_directory"
cp Tests/Integration/result-file-drag-main.swift "$task_directory/main.swift"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" Sources/Keylane/ResultFileDrag.swift "$task_directory/main.swift" -o "$task_directory/verify"
"$task_directory/verify" "$@"
