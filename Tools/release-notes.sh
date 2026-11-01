#!/bin/zsh
# Prints the CHANGELOG.md section of a version (for the GitHub release body), plus install notes.
#
#   Tools/release-notes.sh 1.0.0 [signed]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: release-notes.sh <version> [signed]}
SIGNED=${2:-}
TAG=${GITHUB_REF_NAME:-v$VERSION}
REPO_URL=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-isaacmateosv/ghostbox-revenant}
INSTALL_DOC="$REPO_URL/blob/$TAG/docs/INSTALL.md"   # release pages do not resolve relative links

if [[ "$TAG" == *-* ]]; then
    print "> **Release candidate.** Used daily with a real Mbox 3 on one Mac and installed on macOS 15 and 26"
    print "> (Apple Silicon and Intel) by CI. Please report anything that does not work in"
    print "> [Issues]($REPO_URL/issues)."
    print
fi

awk -v v="$VERSION" '
    /^## \[/ { if (found) exit; if (index($0, "## [" v "]") == 1) { found = 1; next } }
    found { print }
' CHANGELOG.md

print
print "### Install"
print
print "Download **GhostBoxRevenant-$VERSION.dmg**, open it and run **Install GhostBox Revenant.pkg**."
print "Pause anything playing through the Mbox first: if audio is playing while the installer restarts Core Audio,"
print "the Mbox can stay silent until you unplug it and plug it back in."
print "Works on Apple Silicon and Intel Macs (including OpenCore hackintoshes) with macOS 13 Ventura or later."
print
if [[ "$SIGNED" == signed ]]; then
    print "The installer is signed with a Developer ID and notarized by Apple."
else
    print "This build is not signed with an Apple Developer ID, so macOS asks before opening the installer:"
    print "open **System Settings > Privacy & Security** and click **Open Anyway** next to the message"
    print "(on macOS 13-14 you can also Control-click the package and choose **Open**). See [docs/INSTALL.md]($INSTALL_DOC)."
fi
print
print "Verify the download: \`shasum -a 256 -c SHA256SUMS.txt\`"
