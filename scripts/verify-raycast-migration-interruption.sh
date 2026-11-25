#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneRaycastInterruption.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
swiftc -package-name Keylane -swift-version 5 -target "$(uname -m)-apple-macos26.0" -enable-testing -emit-library -emit-module -module-name KeylaneCore Sources/KeylaneCore/*.swift -lsqlite3 -emit-module-path "$task_directory/KeylaneCore.swiftmodule" -o "$task_directory/libKeylaneCore.dylib"
cp Tests/Integration/raycast-interruption-main.swift "$task_directory/main.swift"
swiftc -package-name Keylane -swift-version 5 -target "$(uname -m)-apple-macos26.0" -I "$task_directory" -L "$task_directory" -lKeylaneCore -Xlinker -rpath -Xlinker @executable_path "$task_directory/main.swift" -o "$task_directory/interruption"
for task_kind in snippets clipboard conversations; do
    for task_point in created copying verified published; do
        task_case="$task_directory/$task_kind-$task_point"
        "$task_directory/interruption" seed "$task_case" "$task_kind" "$task_point"
        if "$task_directory/interruption" interrupt "$task_case" "$task_kind" "$task_point"; then
            echo "Expected forced process interruption" >&2
            exit 1
        else
            task_status=$?
            if [[ "$task_status" != 73 ]]; then exit "$task_status"; fi
        fi
        "$task_directory/interruption" recover "$task_case" "$task_kind" "$task_point"
    done
done
