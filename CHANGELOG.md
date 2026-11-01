# Changelog

All notable changes to this project. The format follows [Keep a Changelog](https://keepachangelog.com/) and the
project uses [semantic versioning](https://semver.org/). The story behind each step is in
[docs/LOGBOOK.md](docs/LOGBOOK.md).

## [1.0.0] - Unreleased

The first public release: the Avid Mbox (3rd generation) as a Core Audio device on current macOS, with a modern
control panel.

### Added
- Core Audio driver (AudioServerPlugIn, no kernel extension): 4 inputs and 4 outputs at 44.1, 48, 88.2 and 96
  kHz, hot plug, S/PDIF rate following, and three latency modes (Safe, Balanced, Low).
- GhostBox Revenant GUI: the hardware mixer (two stereo mixes with pan, solo, mute, links, width, balance, master), FX
  sends and returns, the reverb/delay unit, Mono and Dim, meters with peak hold and clip indicators, presets, a
  tuner fed by the Mbox's own pitch detection, the Multi button (learn and map to actions or MIDI), Hardware
  Check, MIDI and System pages, and a menu bar item.
- Fit to Window, horizontal, vertical and meters-only layouts, keyboard and scroll control, native menus.
- Update Driver: installs the bundled driver with the administrator prompt and a 3-minute Core Audio watchdog
  (a one-shot launchd daemon, so it outlives the prompt and the package installer).
- `mbox3-ctl` command-line tool with JSON output.
- Universal installer package and disk image for macOS 13 or later (Apple Silicon and Intel).
- Tests (driver, library, app model, engine, panel) and a CI pipeline that installs the package on macOS 15
  and 26, Apple Silicon and Intel.
- Documentation: architecture, protocol, logbook, status, install and release guides.

### Notes
- Not affiliated with Avid. Licensed under GPL-3.0-or-later.
- Pre-release builds were called "Mbox 3 Control": the installer removes them, the app copies their settings, and
  the Core Audio device keeps its identifier.
