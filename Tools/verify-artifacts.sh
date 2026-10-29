#!/bin/zsh
# Checks the build outputs before they ship: universal binaries (arm64 + x86_64), the macOS deployment target
# on every slice, code signatures, bundle versions, and the installer's contents and requirements. Then writes
# build/dist/ with the installer, the disk image and SHA-256 checksums.
#
#   Tools/verify-artifacts.sh            (after ./build.sh dmg; ./build.sh dist runs both)
set -u
setopt NULL_GLOB
cd "$(dirname "$0")/.."

VERSION=$(tr -d '[:space:]' < VERSION)
MINOS=13.0
B=build
APP="$B/GhostBox Revenant GUI.app"
PKG="$B/GhostBoxRevenant-$VERSION.pkg"
DMG="$B/GhostBoxRevenant-$VERSION.dmg"
failures=0

pass() { print -P "%F{green}  ok%f   $*"; }
fail() { print -P "%F{red}  FAIL%f $*"; failures=$((failures + 1)); }
check() { local msg=$1; shift; if "$@" >/dev/null 2>&1; then pass "$msg"; else fail "$msg"; fi; }

macho_ok() {  # universal, and every slice targets $MINOS
    local file=$1 archs minos
    archs=$(lipo -archs "$file" 2>/dev/null)
    [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || { fail "$file: architectures '$archs' (need arm64 x86_64)"; return; }
    for a in ${=archs}; do
        minos=$(vtool -arch $a -show-build "$file" 2>/dev/null | awk '$1 == "minos" { print $2; exit }')
        [[ "$minos" == "$MINOS" ]] || { fail "$file ($a): minimum macOS '$minos', expected $MINOS"; return; }
    done
    pass "${file:t}: universal ($archs), minimum macOS $MINOS"
}

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

print "Verifying $VERSION"

print "Binaries"
macho_ok "$APP/Contents/MacOS/GhostBoxRevenantGUI"
macho_ok "$B/GhostBoxRevenant.driver/Contents/MacOS/GhostBoxRevenant"
macho_ok "$B/mbox3-ctl"
macho_ok "$APP/Contents/Resources/GhostBoxRevenant.driver/Contents/MacOS/GhostBoxRevenant"
macho_ok "$APP/Contents/Resources/mbox3-ctl"

print "Driver exports (only the factory and the test hooks)"
exports=$(nm -gU -arch arm64 "$B/GhostBoxRevenant.driver/Contents/MacOS/GhostBoxRevenant" | awk '{print $3}' | sort | tr '\n' ' ')
[[ "$exports" == "_Mbox3_ClockProbe _Mbox3_Create _Mbox3_DebugCounters _Mbox3_LeadHist _Mbox3_Stats " ]] \
    && pass "exports: $exports" || fail "unexpected driver exports: $exports"

print "Bundles"
[[ "$(plist_value "$APP" CFBundleShortVersionString)" == "$VERSION" ]] && pass "app version $VERSION" || fail "app version mismatch"
[[ "$(plist_value "$B/GhostBoxRevenant.driver" CFBundleShortVersionString)" == "$VERSION" ]] && pass "driver version $VERSION" || fail "driver version mismatch"
[[ "$(plist_value "$APP" LSMinimumSystemVersion)" == "$MINOS" ]] && pass "app LSMinimumSystemVersion $MINOS" || fail "app LSMinimumSystemVersion"
[[ "$(plist_value "$B/GhostBoxRevenant.driver" LSMinimumSystemVersion)" == "$MINOS" ]] && pass "driver LSMinimumSystemVersion $MINOS" || fail "driver LSMinimumSystemVersion"
check "the app bundles the same driver build" cmp "$B/GhostBoxRevenant.driver/Contents/MacOS/GhostBoxRevenant" "$APP/Contents/Resources/GhostBoxRevenant.driver/Contents/MacOS/GhostBoxRevenant"
for f in UI/index.html UI/js/app.js UI/css/tokens.css install-driver.sh mbox3-ctl AppIcon.icns; do
    [[ -e "$APP/Contents/Resources/$f" ]] && pass "app contains $f" || fail "app is missing Resources/$f"
done

print "Signatures"
check "app signature" codesign --verify --deep --strict "$APP"
check "driver signature" codesign --verify --strict "$B/GhostBoxRevenant.driver"
check "mbox3-ctl signature" codesign --verify --strict "$B/mbox3-ctl"
authority=$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority/ { print $2; exit }')
pass "app signed by: ${authority:-ad-hoc (no Developer ID: Gatekeeper asks users to allow it)}"

print "Installer"
if [[ -f "$PKG" ]]; then
    payload=$(pkgutil --payload-files "$PKG")
    for p in "./Library/Audio/Plug-Ins/HAL/GhostBoxRevenant.driver/Contents/MacOS/GhostBoxRevenant" "./Applications/GhostBox Revenant GUI.app/Contents/MacOS/GhostBoxRevenantGUI" \
             "./Applications/GhostBox Revenant GUI.app/Contents/Resources/install-driver.sh"; do
        print -r -- "$payload" | grep -qxF -- "$p" && pass "package installs ${p#./}" || fail "package lacks ${p#./}"
    done
    dist=$(pkgutil --expand "$PKG" "$B/obj/verify-pkg" >/dev/null 2>&1 && cat "$B/obj/verify-pkg/Distribution"; rm -rf "$B/obj/verify-pkg")
    print -r -- "$dist" | grep -q "os-version min=\"$MINOS\"" && pass "package requires macOS $MINOS or later" || fail "package minimum macOS"
    print -r -- "$dist" | grep -q 'hostArchitectures="arm64,x86_64"' && pass "package runs on Apple Silicon and Intel" || fail "package architectures"
    print -r -- "$dist" | grep -q '<license ' && pass "package shows the license" || fail "package has no license page"
    sig=$(pkgutil --check-signature "$PKG" 2>&1 | awk -F': ' '/Status/ { print $2; exit }')
    pass "package signature: ${sig:-unknown}"
else
    fail "no $PKG (run ./build.sh dmg)"
fi
if [[ -f "$DMG" ]]; then
    check "disk image checksum" hdiutil verify -quiet "$DMG"
else
    fail "no $DMG (run ./build.sh dmg)"
fi

if (( failures )); then
    print -P "%F{red}$failures check(s) failed%f"
    exit 1
fi

print "Writing $B/dist"
rm -rf "$B/dist" && mkdir -p "$B/dist"
cp "$PKG" "$DMG" "$B/dist/"
(cd "$B/dist" && shasum -a 256 *.pkg *.dmg > SHA256SUMS.txt && cat SHA256SUMS.txt)
print -P "%F{green}all checks passed%f"
