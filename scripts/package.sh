#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_binary="$(bash scripts/build-release-executable.sh)"
task_version="$(python3 -c 'import sys; sys.path.insert(0, "scripts"); from versioning import load_version; print(load_version()["version"])')"
task_architecture="$(uname -m)"
python3 scripts/package.py "$task_binary" "dist/Keylane-$task_version-macos-$task_architecture.dmg"
