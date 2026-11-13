#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneEmoji.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
target="$(uname -m)-apple-macos26.0"
swiftc -swift-version 5 -target "$target" -emit-library -emit-module -module-name KeylaneCore \
    -emit-module-path "$task_directory/KeylaneCore.swiftmodule" Sources/KeylaneCore/*.swift -lsqlite3 -o "$task_directory/libKeylaneCore.dylib"
swiftc -swift-version 5 -D DEBUG -target "$target" -I "$task_directory" -L "$task_directory" \
    -lKeylaneCore -Xlinker -rpath -Xlinker "$task_directory" \
    Sources/Keylane/{EmojiSearch,ResultGrid,ResultList,ResultTypeFilter,VisualStyle,ContentActionButtonStyle,NativeHoverButton,SearchField}.swift \
    Tests/Integration/emoji-main.swift -o "$task_directory/verify"
"$task_directory/verify"
