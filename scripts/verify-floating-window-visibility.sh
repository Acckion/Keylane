#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneWindowVisibility.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
cp Tests/Integration/floating-window-visibility-main.swift "$task_directory/main.swift"
swiftc Sources/Keylane/FloatingWindowVisibility.swift "$task_directory/main.swift" -o "$task_directory/verify"
"$task_directory/verify"
