# Legal notice

Copyright © 2026 isaacmateosv and the GhostBox Revenant contributors (see [AUTHORS.md](AUTHORS.md)).

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General
Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option)
any later version (SPDX: `GPL-3.0-or-later`). The full text is in [LICENSE](LICENSE).

## Why this project exists

Avid ended macOS support for the Mbox (3rd generation) with driver 1.2.13 in March 2018 (macOS 10.13 High
Sierra). That driver depends on a kernel extension and 32-bit components that current versions of macOS cannot
load, so the hardware stopped working for its owners. This project lets people keep using hardware they own, by
providing an independently written driver and control panel that interoperate with it.

## Independent implementation

- Everything in this repository was written for this project, except the license text.
- It contains **no** Avid source code, binaries, firmware, installers, manuals or manual text, artwork or logos,
  and nothing from any other closed-source product.
- It does not circumvent any technical protection measure: no copy protection, license check or firmware is
  bypassed or modified. It talks to the device only through standard USB requests.
- Using it does not require any Avid software.

## How the interface was learned

The information needed to interoperate with the hardware came from:

1. observing the USB traffic between the Mbox and its original software, on hardware the author owns;
2. the USB descriptors the device publishes;
3. public open-source work, in particular the Linux kernel's support for this device (credited in AUTHORS.md);
4. examining the interfaces of the manufacturer's legacy macOS driver, only to the extent needed to interoperate
   with the hardware (register numbers and message formats, not code);
5. experiments on the hardware itself.

Facts such as register numbers, message formats and protocol behaviour are functional information needed for
interoperability. The project documents them in its own words ([docs/PROTOCOL.md](docs/PROTOCOL.md)).

## Background (informational, not legal advice)

Many legal systems recognise reverse engineering for interoperability. For example, the EU Software Directive
(2009/24/EC) allows observing, studying and testing a program to determine its underlying ideas (Art. 5(3)) and,
under conditions, decompilation to achieve interoperability (Art. 6); contract terms contrary to these are void
(Art. 8). In the United States, courts have found reverse engineering for interoperability to be fair use
(*Sega v. Accolade*, 1992; *Sony v. Connectix*, 2000), 17 U.S.C. § 1201(f) addresses interoperability, and
copyright does not extend to methods of operation (17 U.S.C. § 102(b)). Laws differ between countries and
change over time. This notice is not legal advice; consult a lawyer about your own situation.

## Trademarks

Avid, Mbox, Digidesign and Pro Tools are trademarks or registered trademarks of Avid Technology, Inc. or its
subsidiaries. Apple, macOS and Core Audio are trademarks of Apple Inc. These names are used only to identify the
hardware and systems this software works with. This project is not affiliated with, endorsed by or supported by
Avid Technology, Inc. or Apple Inc.

## No warranty

This software is provided "as is", without warranty of any kind, to the extent permitted by applicable law (see
sections 15 and 16 of the GPL). The driver runs inside macOS's audio system and the installer runs with
administrator rights; use them at your own risk.

## Rights holders

If you believe something in this repository infringes your rights, please open an issue or contact the
maintainer. It will be reviewed promptly and in good faith, and removed if appropriate.
