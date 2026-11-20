#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneComposerLayout.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
swiftc -Xfrontend -disable-sandbox -swift-version 5 -target "$(uname -m)-apple-macos26.0" -emit-library -emit-module -module-name KeylaneCore \
  Sources/KeylaneCore/LauncherModuleCatalog.swift Sources/KeylaneCore/AIActionDefinition.swift \
  -emit-module-path "$task_directory/KeylaneCore.swiftmodule" -o "$task_directory/libKeylaneCore.dylib"
python3 - "$task_directory/LauncherMenuSurface.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Keylane/ResultTypeFilter.swift').read_text()
Path(sys.argv[1]).write_text('import SwiftUI\n' + source[source.index('struct LauncherMenuRow<Trailing: View>: View {'):])
Path(sys.argv[1]).write_text(Path(sys.argv[1]).read_text() + '\nstruct WorkspaceItemIcon: View { let path: String; var body: some View { EmptyView() } }\n')
PY
cp Tests/Integration/ai-composer-layout-main.swift "$task_directory/main.swift"
swiftc -Xfrontend -disable-sandbox -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
  -I "$task_directory" -L "$task_directory" -lKeylaneCore -Xlinker -rpath -Xlinker "$task_directory" \
  Sources/Keylane/AIInteractionPreferences.swift Sources/Keylane/AIConversationComposer.swift Sources/Keylane/AIContextLoadState.swift Sources/Keylane/AIFileAttachment.swift Sources/Keylane/AIConversationTextInput.swift \
  Sources/Keylane/VisualStyle.swift Sources/Keylane/NativeHoverButton.swift Sources/Keylane/ConversationComposer.swift Sources/Keylane/MenuOutsideClickDismissal.swift Sources/Keylane/LauncherActionMenuPanel.swift Sources/Keylane/AIConversationComposerMenu.swift Sources/Keylane/SearchField.swift \
  "$task_directory/LauncherMenuSurface.swift" "$task_directory/main.swift" -o "$task_directory/verify"
"$task_directory/verify"
