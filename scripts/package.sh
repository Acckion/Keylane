#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_build_directory="$PWD/.build-current"
export CLANG_MODULE_CACHE_PATH="$task_build_directory/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_build_directory/module-cache"
swift build --scratch-path "$task_build_directory" -c release --disable-sandbox
task_binary_directory="$task_build_directory/release"
python3 scripts/package.py "$task_binary_directory/Keylane" dist/Keylane-0.10.0.zip
