#!/bin/zsh
# GhostBox Revenant build script: universal binaries (Apple Silicon + Intel), macOS 13 or later.
#
#   ./build.sh                     build mbox3-ctl, the Core Audio driver and the app into ./build
#   ./build.sh test                unit tests (driver, MboxKit, app model, panel scripts); no hardware needed
#   ./build.sh tools               hardware test tools into build/tools (driver_test, stream_test)
#   ./build.sh pkg                 ... plus build/GhostBoxRevenant-<version>.pkg (app + driver installer)
#   ./build.sh dmg                 ... plus build/GhostBoxRevenant-<version>.dmg (pkg + read-me + uninstaller)
#   ./build.sh dist                dmg, then Tools/verify-artifacts.sh: checks + build/dist with SHA-256 sums
#   ./build.sh verify              only the checks (after dmg)
#   ./build.sh disk-image          only the dmg, from the existing pkg (used after notarizing the pkg)
#   ./build.sh install-app         copy the app to /Applications (no password)
#   ./build.sh install-driver      install the driver (asks for your password), restart Core Audio, replug the Mbox
#   ./build.sh install-driver --watch   ... then watch Core Audio for 3 minutes and remove the driver if it pins the CPU
#   ./build.sh uninstall           remove the driver and the app (asks for your password)
#   ./build.sh clean
#
# Signing: ad-hoc by default. With a Developer ID set in the environment the binaries get the hardened runtime and
# a timestamp, and the package an installer signature (see docs/RELEASING.md):
#   GHOSTBOX_SIGN_IDENTITY="Developer ID Application: …"  GHOSTBOX_INSTALLER_IDENTITY="Developer ID Installer: …"
set -e
setopt NULL_GLOB
cd "$(dirname "$0")"

VERSION=$(tr -d '[:space:]' < VERSION)

# Names and identifiers, in one place
PRODUCT="GhostBox Revenant"
APP_NAME="GhostBox Revenant GUI"
APP_EXEC=GhostBoxRevenantGUI
DRIVER_NAME=GhostBoxRevenant                      # also the base of the installer file names
OWNER=isaacmateosv                                # GitHub account that publishes the project
ID_PREFIX=${GHOSTBOX_ID_PREFIX:-io.github.${OWNER:l}}
APP_ID=$ID_PREFIX.ghostbox-revenant
DRIVER_ID=$APP_ID.driver
PKG_ID=$APP_ID.pkg
LEGACY_APP="/Applications/Mbox 3 Control.app"      # the app's name before the rename

B=build
OBJ=$B/obj
ARCHS=(arm64 x86_64)
MINOS=13.0
APP="$B/$APP_NAME.app"
DRV="$B/$DRIVER_NAME.driver"
HAL=/Library/Audio/Plug-Ins/HAL
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc
CXXFLAGS=(-std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=$MINOS)
FRAMEWORKS=(-framework IOKit -framework CoreFoundation -framework CoreAudio)
MBOXKIT_SRC=(Sources/MboxKit/*.cpp)
DRIVER_SRC=(Sources/Driver/*.cpp)
APP_SRC=(Sources/App/**/*.swift)
MODEL_SRC=(Sources/App/Model/*.swift)
mkdir -p $OBJ

SIGN_IDENTITY=${GHOSTBOX_SIGN_IDENTITY:--}           # "-" = ad-hoc
INSTALLER_IDENTITY=${GHOSTBOX_INSTALLER_IDENTITY:-}

say() { print -P "%F{cyan}[*]%f $*"; }
ok()  { print -P "%F{green}[+]%f $*"; }

# sign <path> [codesign options]: ad-hoc, or Developer ID with the hardened runtime and a secure timestamp
sign() {
    local target=$1; shift
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        codesign --force --sign - "$@" "$target"
    else
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@" "$target"
    fi
}

build_ctl() {
    say "mbox3-ctl (universal)"
    for a in $ARCHS; do
        clang++ $CXXFLAGS -arch $a $MBOXKIT_SRC Sources/MboxCtl/main.cpp -o $OBJ/mbox3-ctl-$a $FRAMEWORKS
    done
    lipo -create $OBJ/mbox3-ctl-$^ARCHS -output $B/mbox3-ctl
    sign $B/mbox3-ctl
}

build_driver() {
    say "Core Audio driver (universal)"
    for a in $ARCHS; do
        clang++ $CXXFLAGS -fvisibility=hidden -DGHOSTBOX_APP_ID="\"$APP_ID\"" -DGHOSTBOX_DRIVER_ID="\"$DRIVER_ID\"" \
            -arch $a -bundle $DRIVER_SRC -o $OBJ/$DRIVER_NAME-$a $FRAMEWORKS
    done
    rm -rf $DRV
    mkdir -p $DRV/Contents/MacOS
    lipo -create $OBJ/$DRIVER_NAME-$^ARCHS -output $DRV/Contents/MacOS/$DRIVER_NAME
    cat > $DRV/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$DRIVER_NAME</string>
    <key>CFBundleIdentifier</key><string>$DRIVER_ID</string>
    <key>CFBundleName</key><string>$PRODUCT</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MINOS</string>
    <key>CFPlugInFactories</key>
    <dict><key>8D2B3A61-6C0E-4F3B-9E57-3F1C0A4B5D21</key><string>Mbox3_Create</string></dict>
    <key>CFPlugInTypes</key>
    <dict><key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key><array><string>8D2B3A61-6C0E-4F3B-9E57-3F1C0A4B5D21</string></array></dict>
    <key>AudioServerPlugIn_IOKitUserClientClasses</key>
    <array>
        <string>AppleUSBHostDeviceUserClient</string>
        <string>AppleUSBHostInterfaceUserClient</string>
        <string>IOUSBDeviceUserClientV2</string>
        <string>IOUSBInterfaceUserClientV3</string>
    </array>
</dict>
</plist>
PLIST
    sign $DRV
}

build_icon() {
    if [[ ! -f $B/AppIcon.icns || Tools/make_icon.swift -nt $B/AppIcon.icns ]]; then
        say "app icon"
        local set=$OBJ/AppIcon.iconset
        rm -rf $set && mkdir -p $set
        swift Tools/make_icon.swift $OBJ/icon_1024.png
        for s in 16 32 128 256 512; do
            sips -z $s $s $OBJ/icon_1024.png --out $set/icon_${s}x${s}.png >/dev/null
            sips -z $((s * 2)) $((s * 2)) $OBJ/icon_1024.png --out $set/icon_${s}x${s}@2x.png >/dev/null
        done
        iconutil -c icns $set -o $B/AppIcon.icns
    fi
}

build_app() {
    build_icon
    say "GhostBox Revenant GUI app (universal)"
    for a in $ARCHS; do
        local objs=()
        for src in $MBOXKIT_SRC; do
            clang++ $CXXFLAGS -arch $a -c $src -o $OBJ/${src:t:r}-$a.o
            objs+=($OBJ/${src:t:r}-$a.o)
        done
        swiftc -O -swift-version 5 -target $a-apple-macos$MINOS -import-objc-header Sources/App/Bridging.h \
            $APP_SRC $objs -lc++ $FRAMEWORKS -framework CoreMIDI -o $OBJ/$APP_EXEC-$a
    done
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    lipo -create $OBJ/$APP_EXEC-$^ARCHS -output "$APP/Contents/MacOS/$APP_EXEC"
    ditto Sources/UI "$APP/Contents/Resources/UI"
    cp $B/AppIcon.icns $B/mbox3-ctl Installer/install-driver.sh "$APP/Contents/Resources/"
    ditto $DRV "$APP/Contents/Resources/$DRIVER_NAME.driver"   # copy for repair installs and Update Driver
    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$APP_ID</string>
    <key>CFBundleExecutable</key><string>$APP_EXEC</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MINOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>The tuner can listen to an audio input when the Mbox's own tuner is not reporting.</string>
    <key>NSAppleEventsUsageDescription</key><string>Installing the Core Audio driver asks for your administrator password.</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 $OWNER and contributors. Free software (GPL-3.0-or-later). Independent driver and panel for the Avid Mbox (3rd gen); not affiliated with Avid.</string>
</dict>
</plist>
PLIST
    # Inside out: nested code first, then the app with its entitlements
    sign "$APP/Contents/Resources/$DRIVER_NAME.driver"
    sign "$APP/Contents/Resources/mbox3-ctl"
    sign "$APP" --entitlements Sources/App/GhostBoxRevenant.entitlements
}

run_tests() {
    say "driver and MboxKit unit tests"
    clang++ $CXXFLAGS Tests/DriverTests.cpp Sources/Driver/ClockModel.cpp $MBOXKIT_SRC -o $OBJ/driver-tests $FRAMEWORKS
    $OBJ/driver-tests
    say "app model unit tests"
    swiftc -O -swift-version 5 $MODEL_SRC Tests/AppModelTests.swift -o $OBJ/app-model-tests
    $OBJ/app-model-tests
    say "engine tests (fake Mbox and driver)"
    swiftc -O -swift-version 5 -import-objc-header Sources/App/Bridging.h $MODEL_SRC Sources/App/Core/*.swift \
        Sources/App/Hardware/Interfaces.swift Sources/App/Services/{StateStore,MidiMonitor,DriverInstaller}.swift \
        Tests/EngineTests.swift -framework CoreMIDI -o $OBJ/engine-tests
    $OBJ/engine-tests
    say "panel script syntax and gain math"
    for f in Sources/UI/js/**/*.js; do
        $JSC -e "checkModuleSyntax(readFile('$f'))" || { print -P "%F{red}[-]%f $f"; return 1; }
    done
    $OBJ/driver-tests --taper-table > $OBJ/taper.json
    $JSC -m Tests/PanelTests.js -- $OBJ/taper.json
    ok "all tests passed"
}

build_tools() {
    say "hardware test tools"
    mkdir -p $B/tools
    clang++ $CXXFLAGS Tools/driver_test.cpp -o $B/tools/driver_test -framework CoreAudio -framework CoreFoundation
    clang++ $CXXFLAGS -arch x86_64 Tools/driver_test.cpp -o $B/tools/driver_test_x86 -framework CoreAudio -framework CoreFoundation
    clang++ $CXXFLAGS Tools/stream_test.cpp -o $B/tools/stream_test -framework IOKit -framework CoreFoundation
    ok "$B/tools (streaming tests need the Mbox to themselves: quit apps that use it first)"
}

build_pkg() {
    say "installer package"
    local root=$OBJ/pkgroot comp=$OBJ/component.plist
    rm -rf $root
    mkdir -p "$root/Applications" "$root$HAL"
    ditto "$APP" "$root/Applications/$APP_NAME.app"
    ditto $DRV "$root$HAL/$DRIVER_NAME.driver"
    # Never let Installer "relocate" the app to some other copy it finds on disk
    pkgbuild --analyze --root $root $comp >/dev/null
    local i=0 pb=/usr/libexec/PlistBuddy
    while $pb -c "Print :$i:RootRelativeBundlePath" $comp >/dev/null 2>&1; do
        $pb -c "Delete :$i:BundleIsRelocatable" $comp >/dev/null 2>&1 || true
        $pb -c "Add :$i:BundleIsRelocatable bool false" $comp
        i=$((i + 1))
    done
    chmod +x Installer/scripts/*
    pkgbuild --root $root --component-plist $comp --identifier $PKG_ID --version $VERSION \
        --scripts Installer/scripts --install-location / $OBJ/$DRIVER_NAME-component.pkg >/dev/null
    sed -e "s/@VERSION@/$VERSION/g" -e "s/@PKG_ID@/$PKG_ID/g" -e "s/@COMPONENT@/$DRIVER_NAME-component.pkg/g" \
        -e "s/@PRODUCT@/$PRODUCT/g" Installer/Distribution.xml > $OBJ/Distribution.xml
    # Installer pages: the read-me, then the license (a short notice, then the GPL) that users accept
    local res=$OBJ/installer-resources
    rm -rf $res && mkdir -p $res
    cp Installer/resources/ReadMe.txt $res/
    { cat Installer/resources/LicenseNotice.txt; print; print; cat LICENSE; } > $res/License.txt
    local signing=()
    [[ -n "$INSTALLER_IDENTITY" ]] && signing=(--sign "$INSTALLER_IDENTITY" --timestamp)
    productbuild --distribution $OBJ/Distribution.xml --package-path $OBJ --resources $res $signing \
        $B/GhostBoxRevenant-$VERSION.pkg >/dev/null
    ok "$B/GhostBoxRevenant-$VERSION.pkg${INSTALLER_IDENTITY:+ (signed)}"
}

build_dmg() {
    say "disk image"
    local stage=$OBJ/dmg
    rm -rf $stage && mkdir -p $stage
    cp $B/$DRIVER_NAME-$VERSION.pkg "$stage/Install $PRODUCT.pkg"
    cp Installer/resources/ReadMe.txt "$stage/Read Me.txt"
    cp Installer/Uninstall.command "$stage/Uninstall $PRODUCT.command"
    chmod +x "$stage/Uninstall $PRODUCT.command"
    rm -f $B/GhostBoxRevenant-$VERSION.dmg
    cp LICENSE "$stage/License.txt"
    hdiutil create -volname "$PRODUCT $VERSION" -srcfolder $stage -ov -format UDZO $B/GhostBoxRevenant-$VERSION.dmg >/dev/null
    [[ "$SIGN_IDENTITY" != "-" ]] && codesign --force --timestamp --sign "$SIGN_IDENTITY" $B/GhostBoxRevenant-$VERSION.dmg
    ok "$B/GhostBoxRevenant-$VERSION.dmg"
}

install_driver() {
    [[ -d $DRV ]] || build_driver
    [[ -f $B/mbox3-ctl ]] || build_ctl  # the script replugs the Mbox with the mbox3-ctl next to the driver
    say "installing the driver (macOS will ask for your password)"
    [[ "$1" == "--watch" ]] && say "then watching Core Audio for 3 minutes; use your audio normally"
    if sudo /bin/sh Installer/install-driver.sh install "$PWD/$DRV" ${1:+--watch}; then
        ok "driver installed${1:+; Core Audio stayed healthy}"
    else
        print -P "%F{red}[-]%f the watchdog removed the driver (Core Audio pinned the CPU); sample in /var/tmp/ghostbox-revenant-coreaudiod-sample.txt"
        return 1
    fi
}

case "${1:-all}" in
    all)            build_ctl; build_driver; build_app; ok "built $B/mbox3-ctl, $DRV and $APP ($VERSION)" ;;
    ctl)            build_ctl ;;
    driver)         build_driver ;;
    app)            build_ctl; build_driver; build_app ;;
    test)           run_tests ;;
    tools)          build_driver; build_tools ;;
    pkg)            build_ctl; build_driver; build_app; build_pkg ;;
    dmg)            build_ctl; build_driver; build_app; build_pkg; build_dmg ;;
    dist)           build_ctl; build_driver; build_app; build_pkg; build_dmg; Tools/verify-artifacts.sh ;;
    verify)         Tools/verify-artifacts.sh ;;
    disk-image)     build_dmg ;;
    install-app)    [[ -d "$APP" ]] || { build_ctl; build_driver; build_app; }
                    pkill -x $APP_EXEC 2>/dev/null || true; pkill -x Mbox3Control 2>/dev/null || true; sleep 1
                    rm -rf "/Applications/$APP_NAME.app" "$LEGACY_APP"; ditto "$APP" "/Applications/$APP_NAME.app"
                    ok "installed /Applications/$APP_NAME.app" ;;
    install-driver) install_driver "$2" ;;
    uninstall)      sudo /bin/sh Installer/install-driver.sh uninstall; sudo rm -rf "/Applications/$APP_NAME.app" "$LEGACY_APP"
                    ok "removed the driver and the app (your settings stay in ~/Library/Application Support/$PRODUCT)" ;;
    clean)          rm -rf $OBJ "$APP" $DRV $B/mbox3-ctl $B/*.pkg $B/*.dmg $B/tools $B/dist; ok "cleaned" ;;
    *)              sed -n '2,22p' "$0"; exit 2 ;;
esac
