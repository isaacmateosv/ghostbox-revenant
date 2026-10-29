# Security

## Reporting a vulnerability

Please report security problems privately through GitHub's **Report a vulnerability** button on the Security tab of
this repository, not in a public issue. Include the macOS version, the app and driver versions, and steps to
reproduce. You will get an answer as soon as possible; fixes ship in a new release.

## What runs where

- **The driver** runs inside macOS's audio system (`coreaudiod` loads it in its own driver process). It talks only
  to the Mbox over USB.
- **The installer** and **Update Driver** run a small script as root (`Installer/install-driver.sh`) after the
  administrator prompt: they copy the driver, restart Core Audio and run a 3-minute watchdog.
- **GhostBox Revenant GUI** serves its panel on `127.0.0.1` only. Requests must be addressed to 127.0.0.1 or localhost,
  browser requests must come from the panel's own origin, and every state change is a JSON POST, so websites
  cannot drive the Mbox through it.

## Supported versions

Only the latest release receives fixes.
