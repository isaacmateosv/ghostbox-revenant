GhostBox Revenant GUI — driver and control panel for the Avid Mbox (3rd generation)

This installs:
  • GhostBox Revenant GUI (in Applications): the mixer, effects, tuner and setup panel, with a menu bar item.
  • The Mbox 3 Core Audio driver (in /Library/Audio/Plug-Ins/HAL): makes the Mbox a sound device with
    4 inputs (Input 1, Input 2, S/PDIF L/R) and 4 outputs (Software Returns 1-4) at 44.1-96 kHz.

Works on Apple Silicon and Intel Macs with macOS 13 Ventura or later.
Not affiliated with Avid. Avid's own Mbox driver should not be installed at the same time.

During installation macOS restarts its audio system, so sound stops for a second.

First run:
  1. Plug in the Mbox. GhostBox Revenant GUI opens and restores your mix.
  2. Choose "Mbox 3" as the input/output in System Settings > Sound or in your DAW.
  3. Set the sample rate in your DAW or Audio MIDI Setup (Core Audio owns it).

If macOS blocks the installer ("can't be opened because it is from an unidentified developer"):
  Control-click the package and choose Open, or go to System Settings > Privacy & Security and click
  "Open Anyway" next to the message, then run it again.

Phantom power, gain, pad, Soft Limit and the front/rear source buttons are analog front-panel controls;
the Hardware Check tab in the panel shows live input levels to set them by.

Tips: the Fit button (or Command-9) scales the whole panel to the window; a yellow bar means a solo is
silencing the other channels; Setup (Command-comma) holds the clock, sample rate and driver latency.
Later driver updates install from the app itself (Update Driver…).

To uninstall: run "Uninstall GhostBox Revenant" from the disk image, or choose
GhostBox Revenant GUI > Uninstall GhostBox Revenant. Your saved mixes and presets stay in
~/Library/Application Support/GhostBox Revenant.
