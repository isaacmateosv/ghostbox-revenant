# Status

Where version 1.0.0 stands: what is verified and how, what still needs testing, known limitations and what is
missing. Updated 2026-11-10 (rc.3 checks on Apple Silicon and on the Intel hackintosh: [TESTING-rc3.md](TESTING-rc3.md)).

**rc.3 is out** ([v1.0.0-rc.3](https://github.com/isaacmateosv/ghostbox-revenant/releases/tag/v1.0.0-rc.3), Nov 10):
installing while music plays and the panel connecting during playback no longer silence the Mbox, checked on an
M4 (macOS 27) and on the Intel hackintosh (macOS 13.7.8). The hackintosh run found two more problems, fixed for
rc.4: a clock-source change during playback silenced the Mbox, and the driver could crash when the Mbox left the
bus mid-stream. rc.4 also adds the Session page (peaks, clips, Out 1/2 history, clip alerts), A/B mixes, talkback
and new Multi button actions.

**Summary:** release candidate. Everything has been built, unit tested and used on one Mac with a real Mbox 3.
That Mac now runs the published rc.1 package (installed Oct 31: driver loaded, watchdog healthy), but the listening
test with the restructured driver is still to be reported. On GitHub's Macs the package installs and runs on
macOS 15 and 26 (Apple Silicon and Intel), and it passed on macOS 14 (Apple Silicon) up to rc.1, before CI dropped those runners (GitHub retires them on Nov 2); it has not yet run on a second Mac with an Mbox. The first pre-release, [v1.0.0-rc.1](https://github.com/isaacmateosv/ghostbox-revenant/releases/tag/v1.0.0-rc.1), is out (Oct 29); 1.0.0 follows once the checks marked *pending* are done.

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
| The package on macOS 14, 15 and 26, Apple Silicon and Intel: install, signatures, native CLI, Core Audio loading the driver, the app and its API security, the watchdog surviving the installer, uninstall | GitHub Actions ([CI](https://github.com/isaacmateosv/ghostbox-revenant/actions/workflows/ci.yml)), first green run Oct 29. Every push now covers macOS 15 and 26; macOS 14 (Apple Silicon only) passed up to rc.1, then left CI because GitHub retires its runners on Nov 2 |
| The rc.1 package on a real Mac with the Mbox (Apple Silicon, macOS 27): replaces the pre-rename driver, Core Audio loads the new one, the watchdog runs its 3 minutes from the installer (Core Audio at 1 % CPU), the app connects, settings kept; installed files identical to the release | On the development Mac, Oct 31 |
| The update check against GitHub: a build stamped 1.0.0-rc.1 is offered rc.2, downloads its package, verifies it against the release's `SHA256SUMS.txt`; rc.2 reports itself up to date; the banner, About and Setup > Advanced in a development copy kept off the Mbox | On the development Mac, Nov 10 (unit tests cover the rules with a fake GitHub) |

## Pending (needs the hardware or other machines)

- [ ] **Streaming through the restructured driver**: installed on Oct 29, then from the rc.1 package on Oct 31;
      play and record to confirm.
- [ ] **Balanced and Low latency modes on hardware**, and the round-trip figure in a DAW.
- [ ] **The watchdog after an in-app update.** The first update showed that the background watchdog never ran
      (the password prompt's shell ended it). It now runs as a launchd daemon, verified for the package on all CI runners and on the development Mac;
      the next in-app update should log "watching Core Audio" in `/var/tmp/ghostbox-revenant-driver.log`.
- [ ] **Tuner pitch messages**: confirm the Control-port messages and whether notes count from A.
- [ ] **Multi button**: which MIDI message it sends.
- [ ] **Rear XLR inputs and the +48V LED** (analog: only the levels can be checked).
- [ ] **S/PDIF** input, output and clock following, with a real source.
- [ ] **88.2 and 96 kHz** in longer sessions.
- [ ] **Hot plug** with the restructured driver while a DAW is running.
- [x] **Installing while audio plays** (Nov 10, Apple Silicon, macOS 27): Music pauses itself when Core Audio
      restarts (macOS does that for every app); pressing play reached the Mbox at once, with no replug. A software
      replug while music played restarted the stream cleanly too.
- [x] **The same on Intel / macOS 13 Ventura** (Nov 10, hackintosh, 13.7.8): install while music plays, the panel
      connecting during playback, a software replug during playback, the update check and playback timing (halio,
      0.000 % never rendered at 128 and 384 frames) all pass. On macOS 13 Music does not pause when Core Audio
      restarts. Results in [TESTING-rc3.md](TESTING-rc3.md).
- [ ] **rc.4 on the hackintosh**: a clock-source change during playback (sound back after about a second), Reset
      USB Connection during playback (no driver crash), the Session page, A/B, Talk and the new Multi button actions.
- [ ] **Another Apple Silicon Mac** (the owner's M2) and **an Intel hackintosh** (Sonoma, Sequoia, Tahoe).
- [x] **macOS 13 Ventura** (Intel hackintosh, 13.7.8): driver loads and streams; the choppy playback found there is fixed
      and verified through coreaudiod at every rate and buffer size (Nov 1).
- [ ] **Intel Sonoma**: no free GitHub runner; only the hackintosh can cover it.
- [ ] **Apple Silicon Sonoma**: CI passed there up to rc.1, but GitHub retires its macOS 14 runners on Nov 2, so CI
      no longer runs it; later builds need an Apple Silicon Mac on Sonoma.

## Known limitations

- Phantom power, gain, pad, Soft Limit and the front/rear source switches are analog controls on the Mbox; no
  software can switch or read them.
- Builds are not signed with an Apple Developer ID until the project has one, so macOS asks users to allow the
  installer once ([INSTALL.md](INSTALL.md)). The release pipeline signs and notarizes automatically once the
  credentials are added ([RELEASING.md](RELEASING.md)).
- Mixer gains cannot be read back from the hardware: the app restores its saved state whenever the Mbox attaches.
- Up to rc.2, restarting Core Audio while audio was streaming (installing or updating the driver does) could leave
  the Mbox ignoring playback until it was unplugged and plugged back in. The panel connecting during playback could
  too. Both causes are fixed for rc.3: the previous driver process lingering after Core Audio went away, and the
  panel rewriting the clock selector. Apps still pause when Core Audio restarts (macOS behaviour): press play again.
- One Mbox at a time.
- Mixer gain tops out at 0 dB (the hardware reports no range).

## Not implemented yet

- Developer ID signing and notarization (needs an Apple Developer account; the pipeline is ready).
- Automatic latency tuning from the measured USB timing.
- Lower driver CPU use (about 13 % of a core while streaming; fewer bus-frame queries are the first candidate).
- Support for more than one Mbox, localization, a light theme.
