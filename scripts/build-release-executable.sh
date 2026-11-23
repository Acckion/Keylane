#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_build_directory="$PWD/.build-current"
export CLANG_MODULE_CACHE_PATH="$task_build_directory/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_build_directory/module-cache"
swift_build_args=(--scratch-path "$task_build_directory" --build-system swiftbuild -c release --disable-sandbox)
swift build "${swift_build_args[@]}" >&2
task_binary_directory="$(swift build "${swift_build_args[@]}" --show-bin-path)"
if [[ "$task_binary_directory" != /* || "$task_binary_directory" == *$'\n'* || ! -f "$task_binary_directory/Keylane" || ! -x "$task_binary_directory/Keylane" ]]; then
    printf 'Keylane executable not found in Swift build output: %s\n' "$task_binary_directory" >&2
    exit 1
fi
printf '%s\n' "$task_binary_directory/Keylane"
