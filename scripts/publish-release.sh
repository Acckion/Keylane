#!/bin/bash
# Called only after Checks on main. Never overwrite an already published release.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${GITHUB_SHA:?missing checked commit}"
: "${GH_REPO:?missing repository}"
[[ "${GITHUB_REF:-}" == refs/heads/main ]] || { echo 'Release must run on main' >&2; exit 1; }
python3 scripts/check-version.py --base-ref HEAD^ --require-bump --release-policy
task_version="$(python3 -c 'import sys; sys.path.insert(0, "scripts"); from versioning import load_version; print(load_version()["version"])')"
task_tag="v$task_version"
task_archive="Keylane-$task_version-macos-arm64.dmg"
(cd dist && sha256sum --check "$task_archive.sha256")
task_release_state="$(mktemp)"
trap 'rm -f "$task_release_state"' EXIT
if gh release view "$task_tag" --json isDraft,assets > "$task_release_state"; then
  if python3 - "$task_release_state" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
sys.exit(0 if state['isDraft'] else 1)
PY
  then
    # Retrying an unpublished draft may replace incomplete assets.
    gh release upload "$task_tag" "dist/$task_archive" "dist/$task_archive.sha256" --clobber
  else
    # A completed retry must refer to this exact commit and have both assets.
    test "$(git rev-parse "$task_tag^{commit}")" = "$GITHUB_SHA"
    python3 - "$task_release_state" "$task_archive" <<'PY'
import json, sys
names = {a['name'] for a in json.load(open(sys.argv[1]))['assets']}
if not {sys.argv[2], sys.argv[2] + '.sha256'} <= names:
    raise SystemExit('Published release has missing assets; do not silently overwrite it')
PY
    echo "$task_tag already published for $GITHUB_SHA; keeping immutable assets."
    exit 0
  fi
else
  task_notes="$(mktemp)"
  cat > "$task_notes" <<'NOTES'
## Build information

- Apple Silicon (arm64); macOS 26 or newer.
- Signed with Developer ID and notarized by Apple.
- Updating may require granting system permissions again.
- Automated tests and package checks passed; this does not certify every real-world interaction.
- See the release pull request for validated changes and known limitations.
- Source available under PolyForm Noncommercial 1.0.0; commercial use requires separate authorization.

Open the DMG and drag Keylane into Applications. The app includes its license, and the release includes a SHA-256 checksum.
NOTES
  gh release create "$task_tag" "dist/$task_archive" "dist/$task_archive.sha256" \
    --target "$GITHUB_SHA" --title "Keylane $task_tag" --draft --generate-notes --notes-file "$task_notes"
  rm -f "$task_notes"
fi
# Publish only once the complete, verified assets have been uploaded to the draft.
gh release edit "$task_tag" --draft=false
