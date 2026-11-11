#!/bin/bash
# Runs on a fresh GitHub-hosted macOS runner.
set -euo pipefail
: "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}" "${GITHUB_OUTPUT:?}"

if [[ -z "$CERTIFICATE" && -z "$CERTIFICATE_PASSWORD" && -z "$APPLE_ID" && -z "$APPLE_TEAM_ID" && -z "$APPLE_APP_PASSWORD" ]]; then
  if [[ "$GITHUB_REF" == refs/heads/main ]]; then
    echo 'Configure Developer ID and Apple notarization secrets before releasing.' >&2
    exit 1
  fi
  echo 'No distribution credentials configured. This build is for testing.'
  exit 0
fi
: "${CERTIFICATE:?}" "${CERTIFICATE_PASSWORD:?}" "${APPLE_ID:?}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_PASSWORD:?}"

umask 077
certificate="$(mktemp "$RUNNER_TEMP/keylane-cert.XXXXXX")"
trap 'rm -f "$certificate"' EXIT
keychain="$RUNNER_TEMP/keylane-signing.keychain-db"
password="$(openssl rand -hex 32)"
printf '%s' "$CERTIFICATE" | base64 -D > "$certificate"

security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$certificate" -k "$keychain" -f pkcs12 -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain"

identity="$(security find-identity -v -p codesigning "$keychain" | awk '/"Developer ID Application:/ {print $2}')"
[[ "$identity" =~ ^[0-9A-Fa-f]{40}$ ]] || { echo 'Expected exactly one Developer ID Application identity.' >&2; exit 1; }
printf 'KEYLANE_SIGNING_IDENTITY=%s\nKEYLANE_DISTRIBUTION=1\n' "$identity" >> "$GITHUB_ENV"
echo 'enabled=true' >> "$GITHUB_OUTPUT"
