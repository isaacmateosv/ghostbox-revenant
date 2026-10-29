#!/bin/zsh
# Submits a signed .pkg or .dmg to Apple's notary service, waits for the verdict and staples the ticket, so
# Gatekeeper opens it without warnings, even offline. Needs NOTARY_APPLE_ID, NOTARY_TEAM_ID and NOTARY_PASSWORD
# (an app-specific password for that Apple ID).
#
#   Tools/notarize.sh build/GhostBoxRevenant-1.0.0.pkg
set -euo pipefail
FILE=${1:?usage: notarize.sh <signed pkg or dmg>}
print "notarizing ${FILE:t}"
xcrun notarytool submit "$FILE" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
    --password "$NOTARY_PASSWORD" --wait --timeout 30m
xcrun stapler staple "$FILE"
xcrun stapler validate "$FILE"
spctl --assess --type install --verbose=2 "$FILE" 2>&1 || true
