#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export KEYLANE_AI_FIXTURE_SUPPORT_SOURCE=Tests/Integration/visual-wire-fixture.swift
export KEYLANE_AI_FIXTURE_SOURCE=Tests/Integration/visual-context.swift
export KEYLANE_AI_UI_EVIDENCE="${KEYLANE_AI_UI_EVIDENCE:-/private/tmp/keylane-ai-visual-evidence}"
bash scripts/verify-module-ai-window.sh
