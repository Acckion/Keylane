#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneComposerLayout.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
python3 - "$task_directory/LauncherMenuSurface.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Keylane/ResultTypeFilter.swift').read_text()
Path(sys.argv[1]).write_text('import SwiftUI\n' + source[source.index('struct LauncherMenuSurface: ViewModifier {'):])
PY
cp Tests/Integration/ai-composer-layout-main.swift "$task_directory/main.swift"
swiftc -Xfrontend -disable-sandbox -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
  Sources/Keylane/AIInteractionPreferences.swift Sources/Keylane/AIConversationComposer.swift Sources/Keylane/AIContextLoadState.swift Sources/Keylane/AIFileAttachment.swift Sources/Keylane/AIConversationTextInput.swift \
  Sources/Keylane/VisualStyle.swift Sources/Keylane/NativeHoverButton.swift Sources/Keylane/ConversationComposer.swift \
  "$task_directory/LauncherMenuSurface.swift" "$task_directory/main.swift" -o "$task_directory/verify"
"$task_directory/verify"
