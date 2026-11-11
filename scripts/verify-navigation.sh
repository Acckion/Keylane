#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/keylane-navigation-check.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
swiftc -module-cache-path "$task_directory/cache" Sources/Keylane/SystemNavigation.swift \
    Tests/Integration/navigation-main.swift -o "$task_directory/navigation-check"
"$task_directory/navigation-check"
