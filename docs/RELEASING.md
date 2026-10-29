# Releasing

## The pipeline

Two GitHub Actions workflows build everything on GitHub's Macs, so a release never depends on one developer's
machine.

**CI** ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)), on every push to `main` and every pull request:

1. **Build and test** on macOS 26 (Apple Silicon): the unit tests, then the universal app, driver, installer and
   disk image, then [`Tools/verify-artifacts.sh`](../Tools/verify-artifacts.sh), which checks that every binary
   has both architectures and targets macOS 13, that signatures, versions and the package contents are right,
   and writes SHA-256 checksums. The results are uploaded as a workflow artifact.
2. **Install tests** on five machines: macOS 26 Tahoe and 15 Sequoia on both Apple Silicon and Intel, and macOS 14
   Sonoma on Apple Silicon. Each one installs the package with [`Tools/ci-install-test.sh`](../Tools/ci-install-test.sh):
   files and signatures in place, the CLI running natively on that CPU, Core Audio loading the driver, the app
   serving its panel and refusing foreign websites, Core Audio staying healthy, and the uninstaller working.
   macOS 14 runners are being retired by GitHub, so a failure there does not fail the run.

What CI cannot prove: audio with a real Mbox (no USB device on the runners), macOS 13 (no runners left) and Intel
Sonoma (no free runner). Those stay on the [STATUS.md](STATUS.md) checklist.

**Release** ([`.github/workflows/release.yml`](../.github/workflows/release.yml)), on a version tag: tests, build,
optional signing and notarization, checks, then a GitHub release with the disk image, the package and
`SHA256SUMS.txt`, its notes taken from [CHANGELOG.md](../CHANGELOG.md).

## Cutting a release

1. Update `VERSION` (three numbers, e.g. `1.0.0`) and add a `## [1.0.0] - YYYY-MM-DD` section to `CHANGELOG.md`.
2. Run `./build.sh test && ./build.sh dist` locally, and do the hardware checks in [STATUS.md](STATUS.md).
3. Commit, then tag and push:
   ```bash
   git tag v1.0.0
   git push origin main v1.0.0
   ```
   A tag with a suffix, like `v1.0.0-rc.1`, publishes a **pre-release** built as version 1.0.0. The tag must match
   `VERSION` or the workflow stops.

## Signing and notarization (optional)

Without them, releases are ad-hoc signed and users allow the installer once in System Settings. With an Apple
Developer account (paid), add these repository secrets (**Settings > Secrets and variables > Actions**) and every
release is signed with a Developer ID and notarized by Apple:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATES_P12` | Base64 of a `.p12` holding the **Developer ID Application** and **Developer ID Installer** certificates with their keys (`base64 -i certs.p12 \| pbcopy`) |
| `MACOS_CERTIFICATES_PASSWORD` | The `.p12` password |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `MACOS_INSTALLER_IDENTITY` | e.g. `Developer ID Installer: Your Name (TEAMID)` |
| `NOTARY_APPLE_ID` | The Apple ID used for notarization |
| `NOTARY_TEAM_ID` | The 10-character team ID |
| `NOTARY_PASSWORD` | An app-specific password for that Apple ID (appleid.apple.com) |

What happens then: binaries are signed inside out with the hardened runtime and a secure timestamp (the app with
[`Sources/App/GhostBoxRevenant.entitlements`](../Sources/App/GhostBoxRevenant.entitlements): microphone for the tuner,
Apple Events for the driver installer), the package is signed with the installer identity, notarized and stapled,
and the disk image is built around it, signed, notarized and stapled too.

Locally, the same signing is available with
`GHOSTBOX_SIGN_IDENTITY=… GHOSTBOX_INSTALLER_IDENTITY=… ./build.sh dist` and `Tools/notarize.sh <file>`.

## Version numbers

`VERSION` is the single source: the app, the driver, the package and the release all take it from there. Bump the
minor version for features, the patch version for fixes, and the major version for changes that need users to do
something (a new minimum macOS, for example).
