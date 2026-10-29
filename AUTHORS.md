# Authors and credits

## Orchestrator and builder

**[isaacmateosv](https://github.com/isaacmateosv)** owns the hardware this was built for. They captured and studied the Mbox's USB traffic on
Windows, directed the AI assistants through every phase, tested each build on a real Mbox 3 (guitar on Input 1,
Logic Pro), and decided what the project should become.

## AI assistance

This project was built with AI assistants, directed and tested by the author:

| Assistant | Contribution |
|---|---|
| **Google Gemini** | Early research: reading the USB descriptors and the Windows captures (with the REA toolkit, below), the codeless-kext experiment, the first Python control panel and the first IOKit control tool (`mbox3-ctl`). |
| **DeepSeek** | Condensed Avid's official Mbox user guide into a summary of every screen and view of the original control panel. It was the checklist for rebuilding the panel, so that no function was missed. |
| **Anthropic Claude** (Claude Code) | The native implementation: the Core Audio driver with isochronous USB streaming, confirming the register map, finding the tuner protocol, the Swift app and its control panel, the modular architecture, the tests, the build and release pipeline, and this documentation. |

How the assistants' early notes compare with what was finally verified is recorded in
[docs/LOGBOOK.md](docs/LOGBOOK.md#early-hypotheses-and-what-turned-out-to-be-true).

## Open-source work this builds on

- **Linux kernel, ALSA USB audio, Avid Mbox 3 support** (GPL), by **Conner Knox** (2022: the original Mbox 3
  quirk, commit `b01104fc62b6`) and **Manuel Barrio Linares** (2024: support for all four sample rates and the
  default setup routine, commit `44f69ddccb`). Their work showed that the Mbox 3 is a USB Audio Class 2 device
  underneath, and gave the clock selector, the mixer addressing and a known-good default state, which this
  project's defaults follow. No kernel code is included here.
- **Apple's AudioServerPlugIn API** and its sample driver (NullAudio), used as the reference for the plug-in
  interface. No sample code is included.

## Hardware and legacy software studied for interoperability

Nothing from these is included in this repository (see [NOTICE.md](NOTICE.md)):

- The **Avid Mbox (3rd generation)** itself, firmware 1.08, owned by the author: most facts were confirmed by
  experiment on the hardware.
- **Avid's Windows driver and control panel**: their USB traffic was captured with Wireshark and USBPcap.
- **Avid Mbox driver 1.2.13 for macOS** (2018, the last release): its interfaces were examined to confirm the
  front-panel registers and the meter block, and to learn how its control panel decodes the tuner's MIDI messages.
- **The Avid Mbox user guide**: the features and terminology of the original control panel.

## Prior art

- **Limbus Audio's Mbox 3 driver**, a closed-source macOS driver by an independent developer, showed that the
  Mbox 3 can work on current macOS. This project is independent of it and contains nothing from it.

## Tools

- **REA** ([morluto/rea](https://github.com/morluto/rea), MIT license), an agent toolkit for reverse engineering,
  was used with Gemini in the early research for binary analysis, to put names to the units and requests seen in
  the USB captures. Most of the conclusions from that phase did not survive testing (see the
  [logbook](docs/LOGBOOK.md#early-hypotheses-and-what-turned-out-to-be-true)); nothing it produced is in this
  repository, and the register map was re-derived from the sources above and confirmed on the hardware.
- Wireshark and USBPcap (USB captures), Apple's Xcode command line tools (clang, swiftc, otool, objdump, strings,
lipo, codesign, pkgbuild, productbuild), JavaScriptCore (panel tests), GitHub Actions (builds and install tests).
