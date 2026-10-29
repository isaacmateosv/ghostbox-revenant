#!/bin/zsh
# CI only: imports the Developer ID certificates (a base64 .p12 in MACOS_CERTIFICATES_P12, password in
# MACOS_CERTIFICATES_PASSWORD) into a temporary keychain that codesign and productbuild can use.
set -euo pipefail
KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
KEYCHAIN_PASSWORD=$(uuidgen)
P12="$RUNNER_TEMP/certificates.p12"

print -r -- "$MACOS_CERTIFICATES_P12" | base64 --decode > "$P12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -P "$MACOS_CERTIFICATES_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
rm -f "$P12"
security find-identity -v "$KEYCHAIN" | grep -E "Developer ID (Application|Installer)" | sed 's/^/  /'
