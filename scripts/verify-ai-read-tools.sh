#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export KEYLANE_AI_FIXTURE_SOURCE=Tests/Integration/ai-read-tools.swift
export KEYLANE_AI_UI_EVIDENCE="${KEYLANE_AI_UI_EVIDENCE:-/private/tmp/keylane-ai-read-tools-evidence}"
bash scripts/verify-module-ai-window.sh
