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

### Added since 1.0.0-rc.2
- Update check: once a day the app looks for a newer release on GitHub and offers it in a banner. **Download &
  Install…** fetches the package, checks it against the release's `SHA256SUMS.txt` and opens it in Installer
  (nothing installs silently). Also in About (Check for Updates) and the app menu. A new **Setup > Advanced** section
  turns the daily check off and chooses whether release candidates are offered (by default only while you run one);
  options there are app-side and never write to the Mbox. The app now reports its full release version (for
  example 1.0.0-rc.3).
- `GHOSTBOX_NO_DEVICE=1` keeps a development copy of the app off the Mbox.

### Fixed since 1.0.0-rc.2
- Installing or updating while audio plays no longer leaves the Mbox silent. Core Audio runs the driver in a
  process of its own, which lingered for about 5 s after the installer restarted Core Audio, kept streaming, and
  was then killed mid-stream, after the installer's software replug. That left the Mbox ignoring playback until it
  was unplugged, and kept the new driver from opening the Mbox, so the app's audio failed to start. Now:
  - the installers stop the old driver process before the software replug;
  - the driver stops streaming cleanly as soon as its process is told to end;
  - starting audio waits up to 7 s for the Mbox instead of failing when another process still holds it.
- Replugging the Mbox while audio plays no longer stalls Core Audio's playback clock. The driver used to restart
  its streams underneath the running session, which reset the clock to zero; it now has Core Audio stop and
  restart audio on a fresh timeline.
- The Mbox no longer goes silent when the panel connects to it while audio plays (at launch, after a replug or
  after a USB hiccup). The panel rewrote the clock selector every time, and a clock-selector write, even with the
  value the Mbox already has, silences a running stream until the Mbox is replugged. The panel now writes it only
  when it actually changes, which also keeps a sample-rate change in Setup from silencing playback.
- Moving an FX send or an effect knob no longer silences the Mbox. The panel re-sent the effect preset with every
  effect change, and the Mbox drops its playback and monitor outputs whenever the preset is written while audio
  streams, until it is replugged. Effect controls are now sent only when they change, the app keeps the preset of a
  Mbox that has been up for a while when it starts, and a deliberate change of effect type replugs the Mbox in software
  (about a second of silence).
- Playback is no longer choppy. The driver revised each zero timestamp as new USB timestamps arrived, so Core Audio
  re-anchored its IO timeline every few milliseconds ("Sample time is not consecutive") and skipped output: about
  3 % of the frames at a 384-frame buffer, a third at 128 frames and up to three quarters at 96 kHz (Intel
  hackintosh, macOS 13). Zero timestamps now follow a timeline that never revises a boundary once published and is
  steered gently toward the USB clock.
- Larger IO buffers: the zero timestamp period is now one lap of the rings (16384 frames) instead of 1024, which
  limited every app to 384-frame buffers at every rate (4 ms at 96 kHz).
- The driver log now records output-stream errors and input-rate corrections, which used to leave no trace.

### Fixed since 1.0.0-rc.1
- Playback no longer turns noisy after a USB stall. When the Mac held back USB completions for longer than the
  input queue (seen while Safari launched), the driver restarted its input stream without counting the skipped
  frames, which moved Core Audio's timeline away from the output stream until playback restarted. Skipped frames
  now count as silence, sent output frames are cleared so a late write plays silence instead of older audio, and
  the input queue is twice as deep (32 ms, no added latency).
- The Signal flow diagram (Flow) is redrawn. Several of its lines stopped short or led nowhere, and it left out
  that the Mac's playback and the FX return reach both mixes. It now shows the two paths, what you record (the
  inputs straight to the Mac) and what you hear (the hardware mixer), with three short notes on what that means
  in practice, and it takes its colours from the panel's theme.

### Notes
- Not affiliated with Avid. Licensed under GPL-3.0-or-later.
- Pre-release builds were called "Mbox 3 Control": the installer removes them, the app copies their settings, and
  the Core Audio device keeps its identifier.
