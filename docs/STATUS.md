# Status

Where version 1.0.0 stands: what is verified and how, what still needs testing, known limitations and what is
missing. Updated 2026-10-29.

**Summary:** release candidate. Everything has been built, unit tested and used on one Mac with a real Mbox 3.
The restructured driver is installed on that Mac (through the app's *Update Driver…*) but its listening test is
still to be reported, and the installer has not yet run on another Mac. Publish the first build as a pre-release (`v1.0.0-rc.1`) until the checks marked *pending* are done.

## Verified

| Area | How it was verified |
|---|---|
| Audio in and out at 48 kHz in Logic and system audio | On hardware (Apple Silicon, macOS 27) with the earlier single-file driver, which uses the same streaming code |
| The restructured driver publishes exactly the same Core Audio objects | All 747 property reads compared with the earlier driver, byte for byte |
| Latency modes switch and are remembered | In-process driver test on arm64 and x86_64 (Rosetta); safety offsets 10/13, 6/9, 4/6 ms |
| Intel builds run | CLI, app and driver x86_64 slices under Rosetta on Apple Silicon; CI runs them natively on Intel runners |
| Mixer, links, solo, mute, master, FX sends and returns, effect, Mono, Dim | On hardware through the panel (writes accepted; the Mbox cannot report mixer gains back) |
| Meters and clip indicators | On hardware, with real signals in each input |
| Tuner mode on and off, from the panel and from the Mbox | On hardware |
| Saved mix restored after unplugging, presets, settings migration | On hardware and in the engine tests |
| Panel security (only the local panel can drive the Mbox) | Request tests against the running app |
| Gain math (panel readouts = hardware taper) | Unit tests, every quarter percent |
| No memory errors or undefined behaviour in tested code | AddressSanitizer and UBSan on the C++ and Swift tests; Clang static analyzer clean |
| Builds from a clean checkout | Built and tested from only the files in the repository |
| In-app driver update: password prompt, install, software replug, Core Audio restart | On the owner's Mac (Oct 29); Core Audio loaded the new driver in Safe mode |

## Pending (needs the hardware or other machines)

- [ ] **Streaming through the restructured driver**: installed on Oct 29; play and record to confirm.
- [ ] **Balanced and Low latency modes on hardware**, and the round-trip figure in a DAW.
- [ ] **The watchdog after an in-app update.** The first update showed that the background watchdog never ran
      (the password prompt's shell ended it). It now runs as a launchd job; CI checks this for the package, and
      the next in-app update should log "watching Core Audio" in `/var/tmp/ghostbox-revenant-driver.log`.
- [ ] **Tuner pitch messages**: confirm the Control-port messages and whether notes count from A.
- [ ] **Multi button**: which MIDI message it sends.
- [ ] **Rear XLR inputs and the +48V LED** (analog: only the levels can be checked).
- [ ] **S/PDIF** input, output and clock following, with a real source.
- [ ] **88.2 and 96 kHz** in longer sessions.
- [ ] **Hot plug** with the restructured driver while a DAW is running.
- [ ] **Another Apple Silicon Mac** (the owner's M2) and **an Intel hackintosh** (Sonoma, Sequoia, Tahoe).
- [ ] **macOS 13 Ventura**: built for it, but GitHub no longer offers macOS 13 runners and no Ventura Mac was
      available.
- [ ] **Intel Sonoma**: no free GitHub runner; only the hackintosh can cover it.

## Known limitations

- Phantom power, gain, pad, Soft Limit and the front/rear source switches are analog controls on the Mbox; no
  software can switch or read them.
- Builds are not signed with an Apple Developer ID until the project has one, so macOS asks users to allow the
  installer once ([INSTALL.md](INSTALL.md)). The release pipeline signs and notarizes automatically once the
  credentials are added ([RELEASING.md](RELEASING.md)).
- Mixer gains cannot be read back from the hardware: the app restores its saved state whenever the Mbox attaches.
- Restarting Core Audio while audio is streaming can leave the Mbox ignoring playback until it is replugged (the
  app's *Reset USB Connection* does it in software).
- One Mbox at a time.
- Mixer gain tops out at 0 dB (the hardware reports no range).

## Not implemented yet

- Developer ID signing and notarization (needs an Apple Developer account; the pipeline is ready).
- Automatic latency tuning from the measured USB timing.
- Lower driver CPU use (about 13 % of a core while streaming; fewer bus-frame queries are the first candidate).
- Support for more than one Mbox, localization, a light theme.
