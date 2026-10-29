# Architecture

GhostBox Revenant has three deliverables built from one source tree: a **Core Audio driver**, the **GhostBox Revenant GUI**
app with its panel, and the **`mbox3-ctl`** command-line tool. They share one description of the hardware
protocol ([`Sources/Shared/MboxProtocol.h`](../Sources/Shared/MboxProtocol.h), explained in
[PROTOCOL.md](PROTOCOL.md)).

```
                ┌──────────────── macOS ────────────────────────────────────────────────┐
  DAW / apps ──►│ Core Audio (coreaudiod)                                               │
                │   └─ "Core Audio Driver (GhostBoxRevenant.driver)" process                       │
                │        GhostBoxRevenant.driver  ── isochronous IN/OUT (interfaces 2, 3) ─────────┼──► Mbox 3
                │                                                                       │    (USB 2.0)
                │ GhostBox Revenant GUI.app ── control requests (interface 1) ─────────────────┼──►
                │   Engine ◄─ HTTP 127.0.0.1 ─► panel (WKWebView, HTML/CSS/JS)           │
                │   MIDI monitor ◄── CoreMIDI ◄── USB MIDI (interface 4, Apple's driver)│◄──
                │ mbox3-ctl ── control requests (diagnostics, installer) ───────────────┼──►
                └───────────────────────────────────────────────────────────────────────┘
```

The driver streams audio and owns the sample rate on behalf of Core Audio. The app owns everything else the
Mbox can do (mixer, effect, front-panel functions, meters) and talks to the hardware directly, without exclusive
access, so the two coexist. USB MIDI needs nothing: the interface is class compliant.

## The driver (`Sources/Driver`)

An **AudioServerPlugIn**: a user-space plug-in that `coreaudiod` loads in its own driver process. No kernel
extension is needed, which keeps it working on current macOS on both Apple Silicon and Intel.

| Module | Responsibility |
|---|---|
| `PlugIn.cpp` | The HAL entry points: initialize, start/stop IO, zero timestamps, IO operations, configuration changes |
| `ObjectModel.cpp` | The Core Audio objects (plug-in, one device, an input and an output stream) and their properties |
| `UsbHost.cpp` | The USB thread and its run loop: hot plug, control requests, every USB callback |
| `HardwareClock.cpp` | Sample rate and clock source; leaves an invalid S/PDIF clock; follows an S/PDIF source's rate |
| `IsochStream.cpp` | Isochronous streaming, implicit feedback, the audio rings, the statistics |
| `ClockModel.cpp` | Maps device sample time to host time from per-microframe USB timestamps |
| `PacketCodec.h` | 24-bit packing and unpacking (pure functions, unit tested) |
| `DriverState.h`, `DriverConfig.h` | Shared state (atomics) and constants, including the latency profiles |
| `DebugExports.cpp` | Counters for `Tools/driver_test`, which loads the driver in-process like `coreaudiod` |

**Streaming.** Sixteen 1 ms IN transfers stay queued on the bus. IN completes in real time, so it paces
everything: it fills the input ring, feeds the clock model, records each packet's frame count and tops up OUT.
OUT reuses those frame counts (implicit feedback) and is scheduled a latency-profile lead ahead of the bus, never
behind frames already queued. Ring positions are device sample times: the HAL reads input frame *n* and writes
output frame *n* at sample time *n*.

**Timing.** USB completions can arrive up to about 7 ms late, so the safety offsets ride out such stalls. Three
latency modes trade margin for latency: Safe (10 ms in / 13 ms out), Balanced (6 / 9) and Low (4 / 6). The mode
is a custom property (`'mbxl'`) stored in the HAL's plug-in storage and applied through a configuration change.

**Sample rate authority.** Core Audio owns the rate. The driver programs the hardware to match it and never pushes
hardware changes back (that once looped forever), except on the S/PDIF clock, where the source decides and the
driver asks Core Audio to follow.

**Hot plug.** The device object always exists; plugging the Mbox in or out only flips `DeviceIsAlive`.
Announcing device-list changes made `coreaudiod` reconcile in a loop at 100 % CPU.

## The app (`Sources/App`)

Swift, layered so each layer only depends on the ones below it:

| Layer | Contents |
|---|---|
| `Model/` | Pure logic, unit tested: the state tree, defaults and migrations (`PanelState`), the mixer law (`MixLaw`), meter ballistics, tuner decoding |
| `Hardware/` | `Interfaces.swift` (the protocols the engine depends on), `MboxHardware` (MboxKit wrapper that writes only gains that changed), `CoreAudioDriver` (HAL client: driver presence, rate, latency mode) |
| `Core/` | `Engine`: owns the state, polls the hardware, syncs it, counts revisions; `EngineActions`: what the panel can ask for |
| `Services/` | Persistence and presets, the MIDI monitor, the Multi button, diagnostics, the in-app driver installer |
| `Server/` | A minimal HTTP/1.1 server on 127.0.0.1 and the API router (routes, static files, security checks) |
| `Shell/` | `AppDelegate` (composition root), the window, the menus, the menu bar item |

**The engine** runs on one serial queue. Every 55 ms it attaches to the Mbox if needed (pushing the saved state on
attach), reads the clock and the driver's state, follows the front-panel buttons, and reads the meters. Meters are
read at full rate only while a panel is watching; otherwise a slow heartbeat detects unplugging. Every state change
bumps a revision number, which the panel polls to notice changes it did not make (menus, front panel, DAW).

**Writes.** The mixer law turns fader, pan, width, balance, mute, solo and master settings into 36 crosspoint
levels. `MboxHardware` sends only the gains that changed, so a fader move costs 2-4 USB requests instead of 18.
Levels are fractional all the way down, so the hardware's 0.25 dB steps are the only quantization.

**The local API** serves the panel and the menus. Requests must be addressed to 127.0.0.1 or localhost, browser
requests must come from the panel's own origin, and state changes are JSON POSTs. Websites in the user's browser
therefore cannot drive the Mbox.

## The panel (`Sources/UI`)

Plain HTML, CSS and ES modules, no framework and no build step.

| Part | Contents |
|---|---|
| `js/api.js` | API calls and `ActionQueue`, which sends one action at a time and coalesces rapid updates |
| `js/store.js` | The panel's copy of the engine state |
| `js/gain.js` | A mirror of the hardware taper (checked against the C code in tests) and the console fader law |
| `js/controls/` | Knob, fader and meter components |
| `js/views/` | Console (strips, master, FX), chrome (top bar, banners, status), dialogs, tuner, tools panel, Fit to Window, toasts |
| `css/` | Design tokens, then base widgets, console, controls, panels and layouts |

Controls update the local state at once and post an action; responses that arrive mid-drag wait until the drag
ends, so the pointer never fights the network.

## Shared pieces

- **MboxKit** (`Sources/MboxKit`): the C API used by the app and the CLI. `MboxUSB.cpp` (device and raw
  requests), `MboxControl.cpp` (registers, meters, mixer taper, effect, clock), `MboxCoreAudio.cpp` (talks to
  the driver through Core Audio).
- **`mbox3-ctl`** (`Sources/MboxCtl`): JSON output for scripts, the installer (software replug) and diagnostics.

## Build, packaging and tests

- `build.sh` builds everything universal (arm64 + x86_64) for macOS 13 or later, then the installer package and
  the disk image. `Tools/verify-artifacts.sh` checks the architectures, the deployment target of every slice,
  signatures, versions and the package contents.
- The installer puts the app in `/Applications` and the driver in `/Library/Audio/Plug-Ins/HAL`, restarts Core
  Audio, replugs the Mbox in software and starts a 3-minute watchdog (`Installer/install-driver.sh`) that removes
  the driver again if Core Audio pins the CPU. The watchdog runs as a one-shot daemon in launchd's system domain,
  because the installer and the password prompt's shell end any process a script leaves behind.
- Tests need no hardware: `Tests/DriverTests.cpp` (clock model, packet codec, taper, addressing),
  `Tests/AppModelTests.swift` (mixer law, meters, tuner, persistence), `Tests/EngineTests.swift` (the engine
  against a fake Mbox and a fake driver) and `Tests/PanelTests.js` (the panel's gain math against the C taper).
  CI also installs the package on several macOS versions and both CPU types (see [RELEASING.md](RELEASING.md)).
