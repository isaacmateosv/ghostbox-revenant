# Contributing

Thanks for helping keep this hardware alive. Bug reports from real setups are as valuable as code: the more Macs,
macOS versions and hackintoshes this runs on, the better.

## Before you start

- Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit, and [docs/STATUS.md](docs/STATUS.md)
  for what still needs testing.
- Build and test:
  ```bash
  ./build.sh test     # no hardware needed
  ./build.sh dist     # universal build, installer, artifact checks
  ```
- For panel work, run the built app with `GHOSTBOX_UI_DIR=Sources/UI` (edits appear on reload) and
  `GHOSTBOX_DATA_DIR=<folder>` so your own settings stay untouched.

## Ground rules

- **Never contribute Avid material**: no Avid code, decompiled or disassembled code, binaries, firmware,
  installers, manual text, screenshots or logos, and nothing from other closed-source products. Describe facts
  (register numbers, message formats, behaviour) in your own words, with how you verified them. See
  [NOTICE.md](NOTICE.md).
- Hardware facts go in [`Sources/Shared/MboxProtocol.h`](Sources/Shared/MboxProtocol.h) and
  [docs/PROTOCOL.md](docs/PROTOCOL.md), so every component shares one definition.
- Keep the module boundaries: pure logic in the app's `Model/` with tests, hardware access behind the protocols in
  `Hardware/Interfaces.swift`, one concern per driver module.
- Driver changes must keep `coreaudiod` healthy: no properties that change on their own, no device-list
  announcements, nothing slow on the IO path. Test with `./build.sh tools` and `build/tools/driver_test` (it
  needs the Mbox to itself), then install with `./build.sh install-driver --watch`.
- Match the surrounding style. New source files may start with `// SPDX-License-Identifier: GPL-3.0-or-later`.

## Pull requests

- Describe what changed and how you tested it, including the Mac, the macOS version and whether a real Mbox was
  attached.
- CI must pass (unit tests, universal build, artifact checks, install tests).
- By contributing you agree that your contribution is licensed under GPL-3.0-or-later.
