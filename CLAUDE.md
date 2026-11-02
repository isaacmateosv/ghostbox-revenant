# GhostBox Revenant — project guide for Claude

Independent macOS driver + control panel for the **Avid Mbox (3rd gen)**, USB `0dba:5000`, firmware 0x0108.
Goal: a stable, portable v1.0 (Apple Silicon + Intel/hackintosh, macOS 13+) installable from a .pkg/.dmg.
The maintainer tests on real hardware. Ask before anything that needs sudo or changes the audio setup.
The maintainer's status, TODO list and private notes live in `CLAUDE.local.md` (git-ignored, not published): read it
first when it exists, and keep its Status section current before stopping.

## Layout
- `Sources/Shared/MboxProtocol.h` the USB protocol in plain C (units, registers, meters, mixer addressing,
  UIDs). Single source of truth for the driver, MboxKit, the CLI and Swift (bridging header).
- `Sources/MboxKit/` C API for the control path: `MboxUSB.cpp` (device, raw requests, replug),
  `MboxControl.cpp` (registers, meters, mixer taper, effect, clock), `MboxCoreAudio.cpp` (HAL client: driver
  presence, rate, latency mode `mbox_coreaudio_*_latency_mode`, installed driver version).
- `Sources/MboxCtl/main.cpp` `mbox3-ctl` CLI (JSON): status (incl. driverVersion, latency), meters, regs,
  latency [mode], ca-rate, batch, dsp, get, reenumerate, ...
- `Sources/Driver/` Core Audio AudioServerPlugIn, one module per concern (see `DriverConfig.h` header):
  `PlugIn.cpp` (HAL entry points), `ObjectModel.cpp` (objects/properties), `UsbHost.cpp` (USB thread, hot plug,
  control requests), `HardwareClock.cpp` (rate/source/S/PDIF follow), `IsochStream.cpp` (iso streaming + rings),
  `ClockModel.cpp` (zero timestamps), `PacketCodec.h` (24-bit packing, pure), `DebugExports.cpp` (harness hooks),
  `DriverState.h` (shared atomics). Built with -fvisibility=hidden: exports only Mbox3_Create + test hooks.
  Runs in "Core Audio Driver (GhostBoxRevenant.driver)"; installed at `/Library/Audio/Plug-Ins/HAL/GhostBoxRevenant.driver`.
- `Sources/App/` Swift app "GhostBox Revenant GUI", layered:
  `Model/` (pure, unit tested: StateTree, PanelState incl. migration, MixLaw, Meters, Tuner),
  `Hardware/` (Interfaces.swift: MboxControl + AudioDriverControl protocols the engine depends on; MboxHardware:
  MboxKit wrapper that writes only changed gains; CoreAudioDriver: HAL client),
  `Core/` (Engine: state owner, poll, sync, revision counter; EngineActions: the /api/state actions),
  `Services/` (StateStore, MidiMonitor, MultiButton, Diagnostics, DriverInstaller), `Server/` (HTTPServer transport,
  APIRouter: routes + security), `Shell/` (AppDelegate composition root, MainWindowController, MainMenu,
  StatusMenuController, main.swift).
- `Sources/UI/` the panel: `index.html`, `css/` (tokens, base, console, controls, panels, layouts),
  `js/` ES modules: app.js (bootstrap, actions, poll), api.js (API + ActionQueue coalescing), store.js,
  gain.js (taper mirror + fader law), controls/ (knob, fader, meter), views/ (console, chrome, dialogs, tuner,
  tools, fit, toast).
- `Tests/` `DriverTests.cpp` (clock model, codec, taper, addressing; `--taper-table`), `AppModelTests.swift`
  (mix law, meters, tuner, persistence), `EngineTests.swift` (engine with fake Mbox/driver), `PanelTests.js`
  (gain.js vs the C taper, fader laws; run by JavaScriptCore `jsc -m`). `./build.sh test` runs all + JS syntax.
- `Tools/` `driver_test.cpp` (loads build/GhostBoxRevenant.driver in-process like coreaudiod; env LATENCYTEST, LATENCYMODE,
  CLOCKPROBE), `stream_test.cpp`, `diagnose.sh`, `make_icon.swift`. `./build.sh tools` builds them.
- `Installer/` pkg scripts (postinstall starts the watchdog), `install-driver.sh` (install/watch/uninstall, run as
  root by the app's Update Driver and by build.sh), Distribution.xml, ReadMe, Uninstall.command.
- `.github/` CI (`ci.yml`: tests, universal build, artifact checks, install tests on macOS 26/15 arm64+Intel)
  and release (`release.yml`: tag vX.Y.Z → GitHub release; optional Developer ID signing+notarization
  from secrets), dependabot, issue form. `Tools/verify-artifacts.sh`, `ci-install-test.sh`,
  `ci-import-certificates.sh`, `notarize.sh`, `release-notes.sh` support them.
- Docs: `README.md`, `docs/` (ARCHITECTURE, PROTOCOL, LOGBOOK, STATUS, INSTALL, RELEASING), `CHANGELOG.md`,
  `AUTHORS.md` (credits), `NOTICE.md` (legal/interoperability/trademarks), `LICENSE` (GPL-3.0 text, project is
  GPL-3.0-or-later), `CONTRIBUTING.md`, `SECURITY.md`. Keep docs/STATUS.md and CHANGELOG.md current.
- `legacy/` old Python version and `panel-1.0-classic.html` (the previous single-file panel) — reference only.
- User data: `~/Library/Application Support/GhostBox Revenant/` (`last_state.json`, `presets/`).

## API contract (Sources/App/Server/APIRouter.swift)
GET /api/state → {state, rev, info{app_version, driver_version, driver_latency|null, spdif_locked, data_dir,
multi_actions}}; GET /api/meters (also carries `rev`; the panel refetches state when rev advances);
POST /api/install-driver (async; progress in info.driver_job {state,message,id}, info.bundled_driver_version);
POST /api/state {action,...} (EngineActions: update_channel(+sibling_val), update_channel_pair, update_links,
update_fx_sends, update_fx_ret, update_dsp, update_master, switch_bus, copy_mix, clear_solos, set_layout,
update_ui{fit,tools_open,tools_tab}, toggle_global, set_global{feature,on}, set_tuner, update_setup,
update_multi_cfg, midi_learn, midi_forget, reset_defaults); POST /api/presets/save|load|delete, /api/init,
/api/reenumerate, /api/open-ams, /api/reveal-data. Security: Host must be 127.0.0.1/localhost, Origin (if any)
must equal http://<Host>, POST needs Content-Type application/json, state changes are POST only.
Dev: `GHOSTBOX_PORT`, `GHOSTBOX_DATA_DIR` (isolated settings), `GHOSTBOX_UI_DIR=Sources/UI` (live panel edits).

## Hardware facts (verified)
- UAC2 descriptors under vendor class 255, so Apple's driver ignores it. High speed.
  Playback: interface 2 alt 1, EP 0x01 iso OUT, 4 ch x 24-bit, max packet 156, implicit feedback from IN.
  Capture: interface 3 alt 1, EP 0x81 iso IN, 4 ch x 24-bit. Interface 4 = class-compliant USB MIDI
  (macOS already exposes "Mbox" with ports **External** (5-pin DIN) and **Control** (Avid control port)).
- Isochronous OUT packets must be **packed back to back** in the transfer buffer (cumulative frReqCount).
  Fixed 156-byte slots = garbled audio (the "distortion" bug). IN can use fixed slots (all requests 156).
- USB completions arrive up to ~7 ms late (USB stack, not priority) → driver margins (latency modes). Under load
  (an app launching) they can stall > 16 ms: an IN resync must keep device time continuous (skipped frames count as
  silence) or the OUT stream drifts off the HAL's timeline and plays unwritten ring frames (noise).
- Controller rejects iso frames scheduled too close to the bus ("TooNew" at lead 0-2 ms): keep OUT 5-10 ms
  ahead, never resync backwards, pump OUT from both IN and OUT completions.
- Meter block (MEM 0x10 @0x2001, 15 words): 0-1 In1/In2, 2-3 S/PDIF in, 4-7 SW returns, 8-9 Out1/2,
  10-11 Out3/4, 12 FX input, 13-14 FX out L/R. Full scale 32767.
- Registers @0x2001 (bRequest 3): 0 LLM (keep 0), 1 Mono, 2 Dim, 3 Tuner, 4 LED dim, 5 hold time
  (3/5/8/10 = 250/500/750/1000 ms). Confirmed from Avid's daemon symbols.
- Mixer/FX-send gains are **write-only** (GET CUR returns 0 for every crosspoint; RANGE reports 0 subranges).
  Max gain treated as 0 dB.
- Writing the effect **preset** (0x4301 wValue 0x0200, any value, even the current one) while audio streams silences
  SW returns, Out 1/2 and FX output until a replug (USB, Core Audio and inputs keep running). Volume, duration and
  feedback are safe. Send the preset only when it changes (`EffectSettings.changes`).
- **No USB control exists for 48V, gain, pad, Soft Limit, front/rear source** (Avid's driver has none).
- Tuner: while tuner mode is on, pitch arrives as MIDI Poly Aftertouch (0xAn note cents) on the Control port
  (cents signed 7-bit, clamp ±50). Note index meaning unconfirmed (0-11 from A per Avid order, else MIDI note).
- S/PDIF validity (0x8201 wValue 0x0200) reads 1 even on the internal clock with nothing connected: only
  meaningful while the S/PDIF clock is selected.
- Unit powers up on **S/PDIF clock** (streaming disabled without signal): driver switches to internal if
  S/PDIF selected but not valid.
- After Core Audio is killed mid-stream the Mbox can ignore playback until replugged → `mbox3-ctl reenumerate`
  (software replug) fixes it; install script does it automatically.

## Hard-won rules
- Core Audio owns the sample rate when the driver is installed. Never write the hardware rate from the panel
  (use Core Audio: `mbox_coreaudio_set_rate`). Never poll hardware rate and push it to Core Audio in internal
  mode (ping-pong loop). Driver may request config changes only for S/PDIF follow.
- Never add a driver custom property whose value changes on its own (stats property pinned coreaudiod).
  `'mbxl'` latency mode is OK because it only changes when the user picks a mode.
- Driver device object is static (always listed); hot-plug only flips DeviceIsAlive. Never announce
  device-list changes (coreaudiod proxy-list Reconcile spun forever).
- Observed hardware values (rate/clock from a DAW) are not persisted; only the user's own choices are.
- StateTree helpers convert immutable containers to mutable copies (never drop them): Swift values stored in the
  tree are immutable.
- Toggles from the panel use explicit-value actions (set_global, set_tuner) because the ActionQueue coalesces.
- Don't run Tools/driver_test or stream_test while the installed driver is streaming (exclusive access).
- Installing the driver needs the user's password; use `--watch` style watchdog (auto-remove if coreaudiod > 80%).
  In the background it runs as a one-shot daemon bootstrapped into launchd's **system** domain (plist in a private
  mktemp folder): the admin prompt's shell and the package installer kill leftover background processes, and a
  `launchctl submit` job under the installer died too (first CI run on GitHub, all five runners).

## Build
`./build.sh [all|test|tools|app|driver|ctl|pkg|dmg|install-app|install-driver [--watch]|uninstall|clean]` —
universal arm64+x86_64, min macOS 13, ad-hoc signed. Outputs in `build/`: `mbox3-ctl`, `GhostBoxRevenant.driver`,
`GhostBox Revenant GUI.app` (Resources: UI/, mbox3-ctl, AppIcon.icns, copy of GhostBoxRevenant.driver),
`GhostBoxRevenant-<VERSION>.pkg` (postinstall: killall coreaudiod + reenumerate + open app; bundles non-relocatable),
`GhostBoxRevenant-<VERSION>.dmg` (pkg + Read Me + License + Uninstall command). Version in `VERSION`.
`./build.sh dist` = dmg + Tools/verify-artifacts.sh (writes build/dist with SHA256SUMS.txt). Signing: ad-hoc unless
GHOSTBOX_SIGN_IDENTITY / GHOSTBOX_INSTALLER_IDENTITY are set. Publishing rules: never commit Avid material (binaries,
manual, decompiled code), third-party closed-source products or copied kernel code; .gitignore enforces it.
