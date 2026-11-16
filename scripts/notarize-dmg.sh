#!/bin/bash
set -euo pipefail
: "${APPLE_ID:?}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_PASSWORD:?}"
image="${1:?expected one DMG}"
result="$(mktemp)"
trap 'rm -f "$result"' EXIT
credentials=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")

xcrun notarytool submit "$image" "${credentials[@]}" --wait --timeout 15m --output-format json > "$result"
if ! python3 -c 'import json, sys; sys.exit(json.load(open(sys.argv[1]))["status"] != "Accepted")' "$result"; then
  submission="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"])' "$result")"
  xcrun notarytool log "$submission" "${credentials[@]}"
  exit 1
fi
xcrun stapler staple "$image"
