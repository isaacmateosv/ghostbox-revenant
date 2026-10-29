#!/bin/zsh
# Captures 5-second CPU samples of coreaudiod and the Mbox 3 driver process while Core Audio is stuck,
# then removes the driver and restarts Core Audio so your audio works again.
set -u
cd "$(dirname "$0")"
OUT=diag
mkdir -p "$OUT"
echo "[*] Sampling coreaudiod for 5 s (asks for your password)..."
sudo sample coreaudiod 5 -file "$OUT/coreaudiod.txt" >/dev/null 2>&1
DRV=$(pgrep -f "Core Audio Driver \(GhostBoxRevenant" | head -1)
if [[ -n "$DRV" ]]; then
    echo "[*] Sampling the Mbox 3 driver process ($DRV) for 5 s..."
    sudo sample "$DRV" 5 -file "$OUT/mbox3-driver.txt" >/dev/null 2>&1
fi
sudo chown "$USER" "$OUT"/* 2>/dev/null
echo "[*] Removing the driver and restarting Core Audio..."
sudo rm -rf /Library/Audio/Plug-Ins/HAL/GhostBoxRevenant.driver
sudo killall coreaudiod
echo "[+] Done. Samples saved in $(pwd)/$OUT; your Mac's audio should work again."
