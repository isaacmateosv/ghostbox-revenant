# Installing

## Requirements

- An Avid Mbox (3rd generation), USB ID `0dba:5000`.
- A Mac with Apple Silicon or Intel, or an OpenCore hackintosh, running **macOS 13 Ventura or later**
  (tested in CI on macOS 15 Sequoia and 26 Tahoe, and on 14 Sonoma up to v1.0.0-rc.1; see [STATUS.md](STATUS.md)).
- Nothing else: no Avid software, no Python, no Xcode. If Avid's old Mbox driver is still installed from an
  older macOS, uninstall it first.

## Install

1. Download `GhostBoxRevenant-<version>.dmg` from the GitHub releases page. Optionally check it:
   `shasum -a 256 -c SHA256SUMS.txt`.
2. Pause anything that is playing through the Mbox, then open the disk image and run
   **Install GhostBox Revenant.pkg**.
3. If macOS refuses to open it (builds without an Apple Developer ID signature):
   - **macOS 15 Sequoia and later**: open **System Settings > Privacy & Security**, scroll down and click
     **Open Anyway** next to the message about the package, then confirm with your password.
   - **macOS 13 Ventura and 14 Sonoma**: Control-click the package and choose **Open**, or use **Open Anyway**
     as above.
4. Accept the license. The installer puts **GhostBox Revenant GUI** in Applications and the driver in
   `/Library/Audio/Plug-Ins/HAL`, restarts Core Audio (sound stops for a second) and opens the app.
5. Plug in the Mbox and choose **Mbox 3** as input and output in **System Settings > Sound** or in your DAW.

For three minutes after installing, a watchdog checks Core Audio and removes the driver again if Core Audio
misbehaves, so your Mac's sound always comes back (log: `/var/tmp/ghostbox-revenant-driver.log`).

## Updating

Pause your audio first, then install the newer package the same way, or, when the app carries a newer driver than
the one installed, click
**Update Driver…** in its banner (About > **Reinstall Driver…** repairs an install). Your mixes and presets are
kept.

## Hackintosh notes (OpenCore)

- The same package works on Intel hackintoshes; the app and the driver are universal.
- Map the USB port the Mbox uses in your USB map (USBToolBox or a similar kext). The Mbox needs a USB 2.0
  high-speed connection; a USB 3 port that passes USB 2.0 through is fine. Avoid hubs shared with busy devices.
- macOS 26 Tahoe is the last macOS version for Intel Macs. On Macs that OpenCore Legacy Patcher brings to newer
  versions, nothing in this project depends on the patcher; report problems with the details the issue form asks
  for.
- No kernel extension is installed, so SIP and secure boot settings do not matter for this driver.

## Uninstall

Run **Uninstall GhostBox Revenant** from the disk image, or choose **GhostBox Revenant GUI > Uninstall GhostBox Revenant**.
Your mixes and presets stay in `~/Library/Application Support/GhostBox Revenant` (delete that folder to remove them).

## Troubleshooting

| Symptom | What to do |
|---|---|
| No sound after installing or updating | Pause the audio, then unplug the Mbox and plug it back in. Menu bar > **Reset USB Connection** helps only while nothing is playing |
| No sound at all | Look for the yellow solo bar; check that Software Returns 1/2 are up in the mix you listen to (Analog 1/2 = Line Out and headphones) |
| Clicks | Setup > Driver Latency > **Safe**; avoid shared USB hubs |
| Audio MIDI Setup or apps hang | Core Audio is stuck: uninstall, restart, and report it with the issue form |
| The Mbox is not detected | Try another port or cable; on a hackintosh, check the USB map |
| The installer cannot be opened | See step 3 above |

## Building from source

Needs the Xcode command line tools (`xcode-select --install`).

```bash
./build.sh test                     # unit tests, no hardware needed
./build.sh dist                     # universal app, driver, installer, disk image, checks and checksums
./build.sh install-app
./build.sh install-driver --watch   # asks for your password; watches Core Audio for 3 minutes
```
