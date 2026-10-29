#!/bin/zsh
# Removes the GhostBox Revenant driver and app (and the older "Mbox 3 Control" names), then restarts Core Audio.
# Saved mixes and presets in ~/Library/Application Support/GhostBox Revenant are kept.
echo "This removes the GhostBox Revenant driver and app (macOS will ask for your password)."
read -q "REPLY?Continue? [y/N] " || { echo; exit 0; }
echo
pkill -x GhostBoxRevenantGUI 2>/dev/null; pkill -x Mbox3Control 2>/dev/null
sudo launchctl bootout system/ghostbox-revenant.driver-watchdog 2>/dev/null
sudo rm -rf /Library/Audio/Plug-Ins/HAL/GhostBoxRevenant.driver /Library/Audio/Plug-Ins/HAL/Mbox3.driver \
    "/Applications/GhostBox Revenant GUI.app" "/Applications/Mbox 3 Control.app"
sudo killall coreaudiod
for p in $(pkgutil --pkgs | grep -E 'ghostbox-revenant|local\.mbox3'); do sudo pkgutil --forget $p >/dev/null 2>&1; done
echo "Done. You can close this window."
