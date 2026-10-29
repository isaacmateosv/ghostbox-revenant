# Logbook: bringing the Mbox 3 back to life

The story of how an abandoned 2010 USB audio interface became a working macOS sound device again, in order, with
the dead ends left in. Dates are local time (UTC−6). For what is done and what still needs testing, see
[STATUS.md](STATUS.md).

## The problem

The Avid Mbox (3rd generation) is a two-channel USB 2.0 interface with a zero-latency hardware mixer, a built-in
reverb/delay, a tuner, S/PDIF and MIDI. Avid's last macOS driver, 1.2.13, came out in March 2018 for macOS 10.13
High Sierra. It depends on a kernel extension and 32-bit components that later macOS versions cannot load. On a
current Mac the Mbox shows up as a MIDI device and nothing else.

The goal: make it a normal Core Audio device again, recreate Avid's control panel, and run on Apple Silicon and
Intel Macs, hackintoshes included.

## Phase 1: listening to the wire (with Gemini)

The first step was to see what the hardware says and what Avid's software sends.

- **USB descriptors**, dumped on Windows: vendor ID `0x0DBA` (Digidesign), and USB Audio Class descriptors hidden
  behind **vendor class codes (`0xFF`)**. That alone explains why macOS ignores the device: its class driver only
  claims class `0x01`.
- **Wireshark with USBPcap on Windows 11**, capturing control traffic while Avid's control panel was used: every
  fader move, sample-rate change and button press shows up as a USB class request, `bmRequestType 0x21` to write
  and `0xA1` to read, with `wIndex` = unit number × 256 + interface 1.
- **Binary analysis with REA**: Gemini used the [REA](https://github.com/morluto/rea) agent toolkit to look for
  driver symbols that would put names to the units and requests in the captures. Its readings of the unit roles
  (`0x2001` as the clock, `0x4001` as the preamps, `0x4301` as the mixer) were all disproved later (see the table
  at the end), so none of them reached the final code.
- A burst of about **58 control requests** when the device starts. Gemini read this as a wake-up handshake that
  unlocks the hardware. It later turned out to be the driver writing a default state: clock, mixer, effect and
  front-panel settings (see the table below).

## Phase 2: the codeless kext (abandoned)

The first idea was a "codeless kext": an `Info.plist` that tells Apple's own USB audio driver to claim the Mbox
anyway. It failed. Streams would not start (pipe errors), the kernel driver then held the interfaces exclusively
so nothing else could talk to the device, and the device's quirks (implicit feedback, the S/PDIF power-up clock,
the silent default mixer) were never going to be handled by a generic driver. Kernel extensions are also
increasingly hard to install on current macOS, especially on Apple Silicon. The project moved to user space.

## Phase 3: a user-space control panel (Gemini, up to Oct 27)

- **`mbox3-ctl`**, a C++ tool that sends the Mbox's control requests through IOKit from user space.
- **A Python web panel** recreating Avid's Driver Control Panel (mixer, effects, setup), served locally.
- **A first audio driver attempt** (Oct 26-27): an AudioServerPlugIn fed by a separate daemon through shared
  memory. It never produced sound, and the Mbox did not appear as an audio device.

## Phase 4: finishing the control path (Claude, Oct 28)

- Fixed stalled control requests and rebuilt the hardware access as a small C++ library.
- Found the **meter block** (extension unit `0x2001`, memory request `0x10`: 15 levels) and confirmed which word is
  which by playing real signals into each input.
- Confirmed the register map from three independent sources that agree: the **Linux kernel's Mbox 3 support**
  (clock selector, mixer addressing, a known-good default state), **Avid's 1.2.13 macOS driver** (the front-panel
  registers: Low Latency Monitoring, Mono, Dim, Tuner, LED dimming, hold time), and experiments on the hardware.
- Rebuilt the panel feature by feature from the Avid user guide, checked against **DeepSeek**'s condensed version
  of it, which listed every screen and view of Avid's control panel: two stereo mixes, links, the effect unit,
  setup, tuner mode, and the Multi button.

## Phase 5: a real Core Audio driver (Claude, Oct 28-29)

A new AudioServerPlugIn that streams over USB itself, with no daemon and no kernel extension. The bring-up log:

| Symptom | Cause | Fix |
|---|---|---|
| The Mbox was not a sound device | No working driver | Isochronous streaming with IOKit's low-latency API inside the plug-in |
| Crackle and distortion | OUT packets were written in fixed 156-byte slots | Pack packets back to back in each transfer |
| OUT transfers rejected ("TooNew") | Frames scheduled too close to the bus | Keep OUT 5-10 ms ahead, pump it from IN and OUT completions, never resync backwards |
| Clicks under load | USB completions arrive up to ~7 ms late | Wider safety offsets (later: latency modes) |
| `coreaudiod` at 100 % CPU, Audio MIDI Setup frozen | A constantly changing custom property, and announcing device-list changes on hot plug | Static device that only flips `DeviceIsAlive`; custom properties that change only when the user asks |
| The sample rate bounced between values | The driver pushed hardware rate changes back to Core Audio | Core Audio is the only authority; the panel changes the rate through Core Audio |
| Silence after reinstalling | The Mbox ignores playback after Core Audio is killed mid-stream | Software replug (`USBDeviceReEnumerate`) in the installer; select alt 0 before streaming |
| No audio at power-up | The Mbox starts on the S/PDIF clock and does not stream without a signal | The driver switches to the internal clock when S/PDIF is not valid |

On the evening of Oct 28 the owner reported clean audio through Logic (48 kHz, 128-sample buffer, 33 ms round trip
in the most conservative latency mode).

## Phase 6: a native app, v1.0 (Claude, Oct 29)

- **GhostBox Revenant GUI**: a Swift app replaced Python. It hosts the engine, serves the panel to its own window and
  adds a menu bar item. It saves the mix and restores it after unplugging.
- **The hardware tuner**: Avid's 1.2.13 control panel showed that, in tuner mode, the Mbox reports pitch itself
  as MIDI Polyphonic Aftertouch on its Control port. The app decodes it, so the tuner no longer needs a microphone.
- **Latency modes** (Safe, Balanced, Low), **S/PDIF rate following**, and the known issues listed for Avid's
  1.2.13 driver taken into account (Low Latency Monitoring muting inputs, audio lost when switching to S/PDIF and
  back).
- **Universal builds** (arm64 + x86_64) for macOS 13 or later, an installer package and a disk image. The Intel
  versions were tested under Rosetta: the CLI, the app and the driver all work on the x86_64 slice.

## Phase 7: architecture and comfort (Claude, Oct 29)

- **Modular code everywhere**: the driver split into modules with a byte-identical Core Audio surface (747 property
  reads compared before and after), a layered Swift app, and the panel as ES modules.
- **Tests that need no hardware**: 648 checks across the driver, the library, the app's model and engine, and the
  panel's math (compared with the C code).
- **A new panel**: faders with real dB scales and meters beside them, a console-style fader law, a solo warning,
  Fit to Window, native menus and shortcuts.
- Bugs found on the way: the mixer taper jumped 18 dB at 15 % fader travel; whole-percent levels stepped 3 dB at
  low levels; settings from the Python era needed migrating.
- **Update Driver…** in the app installs the bundled driver with the administrator prompt and a 3-minute Core
  Audio watchdog.

## Phase 8: release engineering (Oct 29, afternoon)

GPL-3.0-or-later license, a legal notice, credits, and a GitHub Actions pipeline that builds, tests, verifies and
installs the package on macOS 14, 15 and 26 (Apple Silicon and Intel) before publishing a release.

## Phase 9: GhostBox Revenant (Oct 29, evening)

- The project got its name, **GhostBox Revenant**, with a ghost for an icon: a cyan outline with the Mbox's
  green LEDs for eyes. Settings and installs from the builds named "Mbox 3 Control" carry over automatically;
  the Core Audio device keeps its identifier, so DAWs keep their settings.
- The owner's first in-app driver update installed the new driver correctly, but its log had no watchdog lines:
  the password prompt's shell had ended the background watchdog. It now runs as a one-shot launchd job, which CI
  checks after installing the package.
- The credits were checked against the early notes: what Gemini, DeepSeek and the REA toolkit each contributed is
  now recorded in [AUTHORS.md](../AUTHORS.md).

## Early hypotheses and what turned out to be true

The early research notes (written with Gemini) captured the method well, but several conclusions did not survive
testing on the hardware. Kept here because the method is reusable, and the mistakes are instructive.

| Early note | What turned out to be true |
|---|---|
| The Mbox hides its audio class behind vendor codes `0xFF` | ✅ True. This is why macOS ignores it. |
| Class requests: `0x21` write, `0xA1` read; `wIndex` = unit × 256 + interface 1 | ✅ True |
| A codeless kext can make Apple's driver take the device | ❌ It cannot run the device properly; abandoned for a user-space driver |
| A "58-packet handshake" wakes up the DSP, the clock PLL and mute relays | ⚠️ The burst is the default state (clock, mixer, effect, front panel). No unlock is needed; sound needs a valid clock and non-zero mixer gains. |
| `0x2001` is the clock and sample-rate controller | ❌ `0x2001` is the extension unit: front-panel functions and meters. The clock is `0x8001`/`0x8101`/`0x8201`. |
| `0x4001` controls the preamps and +48V | ❌ `0x4001` is the monitor mixer |
| `0x4301` is the monitor mixer | ❌ `0x4301` is the reverb/delay effect unit |
| +48V phantom power can be switched from macOS | ❌ Phantom power, gain, pad and Soft Limit are analog front-panel controls with no USB access, in Avid's driver too |
| Reads use `bRequest 0x81` (GET_CUR) | ❌ That is USB Audio Class 1. This is a Class 2 device: `0x01` (CUR) with `0xA1` |
| Kernel drivers lock the device and block user-space control | ✅ True, and a reason for the user-space design |

## Lessons

- Verify every claim on the hardware; captures show *what* is sent, not *why*.
- In `coreaudiod`, anything that changes on its own (a property, the device list) can spin the whole audio system.
- One owner per setting: Core Audio owns the sample rate, the app owns the mixer.
- Write-only hardware needs software that remembers and restores.
- Test what can be tested without hardware, and keep the hardware tests short and explicit.
