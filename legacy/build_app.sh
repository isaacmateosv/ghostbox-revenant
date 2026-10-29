#!/bin/zsh
# Builds "Mbox 3 Control.app" into ./build and installs it into /Applications.
#   ./build_app.sh            build + install
#   ./build_app.sh --no-install
set -e
setopt NULL_GLOB
cd "$(dirname "$0")"

APP_NAME="Mbox 3 Control"
BUILD=build
APP="$BUILD/$APP_NAME.app"
DATA="$HOME/Library/Application Support/Mbox3 Control"

echo "[*] Compiling mbox3-ctl..."
mkdir -p "$BUILD"
clang++ -std=c++17 -O2 main.cpp -o "$BUILD/mbox3-ctl" -framework IOKit -framework CoreFoundation -framework CoreAudio

echo "[*] Compiling app shell..."
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" app/Mbox3Control.swift -o "$BUILD/Mbox3Control"

if [[ ! -f "$BUILD/AppIcon.icns" || app/make_icon.swift -nt "$BUILD/AppIcon.icns" ]]; then
    echo "[*] Rendering icon..."
    ICONSET="$BUILD/AppIcon.iconset"
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    swift app/make_icon.swift "$BUILD/icon_1024.png"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$BUILD/AppIcon.icns"
fi

echo "[*] Assembling bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Mbox3Control" "$APP/Contents/MacOS/"
cp "$BUILD/mbox3-ctl" server.py "$BUILD/AppIcon.icns" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Mbox 3 Control</string>
    <key>CFBundleDisplayName</key><string>Mbox 3 Control</string>
    <key>CFBundleIdentifier</key><string>local.mbox3.control</string>
    <key>CFBundleExecutable</key><string>Mbox3Control</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>The tuner needle listens to an audio input to show pitch.</string>
</dict>
</plist>
PLIST

echo "[*] Signing (ad hoc)..."
codesign --force --deep --sign - "$APP"

# First install: carry over the session and presets from this folder
if [[ ! -f "$DATA/last_state.json" && -f last_state.json ]]; then
    mkdir -p "$DATA/presets"
    cp last_state.json "$DATA/"
    cp presets/*.json "$DATA/presets/" 2>/dev/null || true
    echo "[+] Copied your saved session and presets into $DATA"
fi

if [[ "$1" != "--no-install" ]]; then
    echo "[*] Installing into /Applications..."
    osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    echo "[+] Installed /Applications/$APP_NAME.app"
fi
echo "[+] Done: $APP"
