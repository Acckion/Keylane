#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneResultFileDrag.XXXXXX)"
keep_directory=0
trap 'if [ "$keep_directory" = 0 ]; then rm -rf "$task_directory"; fi' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
export KEYLANE_RESULT_DRAG_TEST_ROOT="$task_directory"
cp Tests/Integration/result-file-drag-main.swift "$task_directory/main.swift"
swiftc -package-name Keylane -swift-version 5 -target "$(uname -m)-apple-macos26.0" -emit-library -emit-module -module-name KeylaneCore Sources/KeylaneCore/*.swift -lsqlite3 -emit-module-path "$task_directory/KeylaneCore.swiftmodule" -o "$task_directory/libKeylaneCore.dylib"
swiftc -package-name Keylane -swift-version 5 -target "$(uname -m)-apple-macos26.0" -I "$task_directory" -L "$task_directory" -lKeylaneCore -Xlinker -rpath -Xlinker "$task_directory" Sources/Keylane/{ResultFileDrag,ResultList}.swift "$task_directory/main.swift" -o "$task_directory/verify"
if [ "${1:-}" = "--prepare-ui" ]; then
    "$task_directory/verify"
    # The operator launches this only after foreground interaction is authorized.
    printf '#!/bin/bash\nexport KEYLANE_RESULT_DRAG_TEST_ROOT=%q\nexec %q --ui\n' "$task_directory" "$task_directory/verify" > "$task_directory/Open-Drag-Test.command"
    chmod +x "$task_directory/Open-Drag-Test.command"
    keep_directory=1
    echo "PREPARED_NOT_LAUNCHED: $task_directory/Open-Drag-Test.command"
else
    "$task_directory/verify" "$@"
fi
