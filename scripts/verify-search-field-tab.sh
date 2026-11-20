#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneTabFixture.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" -parse-as-library \
    Sources/Keylane/SearchField.swift Tests/Integration/search-field-tab-main.swift \
    -o "$task_directory/verify"
"$task_directory/verify"
