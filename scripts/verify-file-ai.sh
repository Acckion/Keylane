#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneFileAIIntegration.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
swiftc -Xfrontend -disable-sandbox -swift-version 5 -target "$(uname -m)-apple-macos26.0" -emit-library -emit-module -module-name KeylaneCore Sources/KeylaneCore/*.swift -lsqlite3 -emit-module-path "$task_directory/KeylaneCore.swiftmodule" -o "$task_directory/libKeylaneCore.dylib"
python3 - "$task_directory/ReleaseNotesBody.swift" <<'PYBODY'
from pathlib import Path
import sys
source = Path('Sources/Keylane/ReleaseNotesLauncher.swift').read_text()
Path(sys.argv[1]).write_text('import SwiftUI\n' + source[source.index('struct ReleaseNotesBody:'):])
PYBODY
cp Tests/Integration/file-ai-main.swift "$task_directory/main.swift"
cat Tests/Integration/ai-tools-main.swift Tests/Integration/visual-wire-fixture.swift Tests/Integration/visual-wire-main.swift >> "$task_directory/main.swift"
swiftc -Xfrontend -disable-sandbox -swift-version 5 -target "$(uname -m)-apple-macos26.0" -I "$task_directory" -L "$task_directory" -lKeylaneCore -Xlinker -rpath -Xlinker "$task_directory" Sources/Keylane/AIRunHandle.swift Sources/Keylane/AIActionSource.swift Sources/Keylane/SnippetAIContextSource.swift Sources/Keylane/AppleNotesAIReader.swift Sources/Keylane/AppleNotesAutomation.swift Sources/Keylane/ExtensionProcessRequest.swift Sources/Keylane/AIActionSession.swift Sources/Keylane/AIActionResultView.swift Sources/Keylane/AIResponseProgressView.swift Sources/Keylane/AIConversationMarkdownBody.swift "$task_directory/ReleaseNotesBody.swift" Sources/Keylane/FileAIContextSource.swift Sources/Keylane/FileAI.swift Sources/Keylane/AIConfiguration.swift Sources/Keylane/AIInteractionPreferences.swift Sources/Keylane/AIConversationComposer.swift Sources/Keylane/AIContextLoadState.swift Sources/Keylane/AIStreamProgress.swift Sources/Keylane/AIConversationTurn.swift Sources/Keylane/AIFileAttachment.swift Sources/Keylane/AIResponseFormatting.swift Sources/Keylane/AIConversationHostActions.swift Sources/Keylane/AIVisualMessage.swift Sources/Keylane/AIRuntime.swift Sources/Keylane/AIToolRuntime.swift Sources/Keylane/AIToolHTTPTransport.swift Sources/Keylane/AIClaudeToolTransport.swift Sources/Keylane/AIProviderPreset.swift Sources/Keylane/AIModelMenuCatalog.swift Sources/Keylane/AnthropicAIProtocol.swift Sources/Keylane/AICLIProcess.swift Sources/Keylane/AISubscriptionTransport.swift Sources/Keylane/ThemeStore.swift Sources/Keylane/ThemeStyle.swift Sources/Keylane/WindowLoadingIndicator.swift Sources/Keylane/AIConversationSession.swift Sources/Keylane/AIConversationRepository.swift Sources/Keylane/AIChatProject.swift Sources/Keylane/AITextCommand.swift Sources/Keylane/CustomAICommandLibrary.swift -lsqlite3 "$task_directory/main.swift" -o "$task_directory/verify"
"$task_directory/verify"
