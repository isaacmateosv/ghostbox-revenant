#!/bin/zsh
# Builds the Mbox 3 Core Audio driver into driver/build/Mbox3.driver.
#   ./build_driver.sh            build only
#   ./build_driver.sh --install  build, install into /Library/Audio/Plug-Ins/HAL (asks for your password)
#                                and restart Core Audio
#   ./build_driver.sh --install --watch   install, then watch coreaudiod for 3 minutes; if it pins the CPU,
#                                         save diagnostic samples and remove the driver automatically
#   ./build_driver.sh --uninstall
set -e
cd "$(dirname "$0")"
BUNDLE=build/Mbox3.driver
HAL=/Library/Audio/Plug-Ins/HAL

if [[ "$1" == "--uninstall" ]]; then
    sudo rm -rf "$HAL/Mbox3.driver"
    sudo killall coreaudiod
    echo "[+] Removed $HAL/Mbox3.driver"
    exit 0
fi

echo "[*] Compiling driver..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
clang++ -std=c++17 -O2 -Wall -Wno-unused-parameter -bundle Mbox3Driver.cpp -o "$BUNDLE/Contents/MacOS/Mbox3" \
    -framework CoreAudio -framework IOKit -framework CoreFoundation

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Mbox3</string>
    <key>CFBundleIdentifier</key><string>local.mbox3.driver</string>
    <key>CFBundleName</key><string>Mbox 3</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFPlugInFactories</key>
    <dict>
        <key>8D2B3A61-6C0E-4F3B-9E57-3F1C0A4B5D21</key><string>Mbox3_Create</string>
    </dict>
    <key>CFPlugInTypes</key>
    <dict>
        <key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>
        <array><string>8D2B3A61-6C0E-4F3B-9E57-3F1C0A4B5D21</string></array>
    </dict>
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

codesign --force --sign - "$BUNDLE"
echo "[+] Built $BUNDLE"

if [[ "$1" == "--install" ]]; then
    echo "[*] Installing (macOS will ask for your password)..."
    sudo rm -rf "$HAL/Mbox3.driver"
    sudo cp -R "$BUNDLE" "$HAL/"
    sudo chown -R root:wheel "$HAL/Mbox3.driver"
    sudo killall coreaudiod
    # Killing Core Audio mid-stream can leave the Mbox ignoring playback until it is replugged; replug it in software
    sleep 2
    ../mbox3-ctl reenumerate >/dev/null 2>&1 && echo "[*] Re-enumerated the Mbox (software replug)"
    echo "[+] Installed. Core Audio restarted; the Mbox 3 should appear in Audio MIDI Setup."

    if [[ "${2:-}" == "--watch" ]]; then
        echo "[*] Watching Core Audio for 3 minutes. Use your audio normally (music, DAW, Audio MIDI Setup)."
        hot=0
        for i in {1..180}; do
            sleep 1
            cpu=$(ps -axo %cpu,comm | awk '/\/usr\/sbin\/coreaudiod$/ {print int($1)}' | head -1)
            if [[ "${cpu:-0}" -gt 80 ]]; then hot=$((hot + 1)); else hot=0; fi
            if (( i % 30 == 0 )); then echo "    ${i}s: coreaudiod ${cpu:-?}% CPU"; fi
            if (( hot >= 15 )); then
                echo "[-] Core Audio has been above 80% CPU for 15 s. Saving samples and removing the driver..."
                mkdir -p diag
                sudo sample coreaudiod 5 -file diag/coreaudiod.txt >/dev/null 2>&1
                DRV=$(pgrep -f "Core Audio Driver \(Mbox3" | head -1)
                [[ -n "$DRV" ]] && sudo sample "$DRV" 5 -file diag/mbox3-driver.txt >/dev/null 2>&1
                sudo chown "$USER" diag/* 2>/dev/null
                sudo rm -rf "$HAL/Mbox3.driver"
                sudo killall coreaudiod
                echo "[+] Driver removed and Core Audio restarted. Samples are in $(pwd)/diag."
                exit 1
            fi
        done
        echo "[+] Core Audio stayed healthy for 3 minutes."
    fi
fi
