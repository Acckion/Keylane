#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneConversationTypography.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
# Compile the actual renderer without the release-history host and its application services.
python3 - "$task_directory/ReleaseNotesBody.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Keylane/ReleaseNotesLauncher.swift').read_text()
Path(sys.argv[1]).write_text('import SwiftUI\n' + source[source.index('struct ReleaseNotesBody: View {'):])
PY
cp Tests/Integration/ai-conversation-typography-main.swift "$task_directory/main.swift"
swiftc -Xfrontend -disable-sandbox -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
  "$task_directory/ReleaseNotesBody.swift" Sources/Keylane/AIConversationMarkdownBody.swift \
  "$task_directory/main.swift" -o "$task_directory/verify"
"$task_directory/verify"
