#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_build_directory="$PWD/.build-current"
export CLANG_MODULE_CACHE_PATH="$task_build_directory/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_build_directory/module-cache"
swift_build_args=(--scratch-path "$task_build_directory" --build-system swiftbuild -c release --disable-sandbox)
swift build "${swift_build_args[@]}"
task_binary_directory="$(swift build "${swift_build_args[@]}" --show-bin-path)"
if [[ -z "$task_binary_directory" || ! -f "$task_binary_directory/Keylane" || ! -x "$task_binary_directory/Keylane" ]]; then
    printf 'Keylane executable not found in Swift build output: %s\n' "$task_binary_directory" >&2
    exit 1
fi
task_version="$(python3 -c 'import sys; sys.path.insert(0, "scripts"); from versioning import load_version; print(load_version()["version"])')"
task_architecture="$(uname -m)"
python3 scripts/package.py "$task_binary_directory/Keylane" "dist/Keylane-$task_version-macos-$task_architecture.dmg"
