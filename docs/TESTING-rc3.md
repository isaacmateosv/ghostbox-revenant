# Testing 1.0.0-rc.3 with a real Mbox

rc.3 fixes the silences around Core Audio restarts and the panel's reconnects. This page lists what was already
checked on the development Mac, and the checks still to do on other machines (first the owner's Intel hackintosh
on macOS 13 Ventura), in the order to run them.

## Already checked (Nov 10, Apple Silicon M4, macOS 27, the rc.3 candidate)

| Check | Result |
|---|---|
| Install the driver while music plays | Pass. The installer stopped the previous driver process, replugged the Mbox, and Core Audio loaded the new driver at once. Music paused itself (every app does when Core Audio restarts); pressing play reached the Mbox with no replug. Before rc.3 the Mbox stayed silent here until it was unplugged. |
| Software replug while music plays | Pass. The driver logged *restarting IO after the Mbox returned*, and the music continued after a short gap. |
| The panel connecting while music plays | Before the fix the music died 1-2 s after the panel connected. Writing each of the panel's start-up settings alone found the cause: rewriting the clock selector, even with the same value, silences a running stream. rc.3 writes it only when it changes; this still needs a check with the fixed panel (test 2 below). |
| Playback timing with the new zero timestamps (#6) | Pass. `build/tools/halio --seconds 10 --buffer 128` and `--buffer 384`: 0.000% of the output timeline never rendered, no jumps, no overloads. Music played through the candidate driver for more than 10 minutes. |

## To check on each new machine

Have the Mbox connected and a song ready in Music (or any player) going to the Mbox. Useful views:

- Meters from the terminal (words 4-5 are the music coming from the Mac):
  `"/Applications/GhostBox Revenant GUI.app/Contents/Resources/mbox3-ctl" meters`
- The driver log (in zsh, `log` is a built-in, so use the full path):
  `/usr/bin/log show --last 5m --info --predicate 'subsystem == "io.github.isaacmateosv.ghostbox-revenant.driver"'`
- The installer log: `/var/tmp/ghostbox-revenant-driver.log`

1. **Install while music plays.** Play music through the Mbox on the installed version, then install rc.3 from the
   disk image (`GhostBoxRevenant-1.0.0.dmg` on the
   [v1.0.0-rc.3 release](https://github.com/isaacmateosv/ghostbox-revenant/releases/tag/v1.0.0-rc.3)).
   - Expect, in the installer log: *stopped the previous driver process* (only if Core Audio runs drivers in their
     own process on that macOS version: check `pgrep -fl "Core Audio Driver"` beforehand), then *replugged the Mbox
     in software* and *Core Audio restarted*.
   - Music pauses: press play. The music must reach the Mbox (meters, and your ears) without unplugging it.
2. **The panel connecting while music plays.** With music playing, quit GhostBox Revenant GUI (⌘Q) and open it
   again. The music must keep playing after the panel connects (watch for 10 s).
3. **Software replug while music plays.** Menu bar icon > *Reset USB Connection*. After a short gap the music must
   come back by itself; the driver log shows *restarting IO after the Mbox returned*.
4. **Update check.** About shows the version as `1.0.0-rc.3` and *Up to date*. Setup > Advanced has *Check GitHub
   for a new version once a day* (on) and *Release candidates* (Automatic).
5. **Playback timing** (from a checkout of the `v1.0.0-rc.3` tag, `./build.sh tools`):
   `build/tools/halio --seconds 10 --buffer 128`, then `--buffer 384`. Both must end with *0.000% of the output
   timeline never rendered*.
6. **Everyday use.** A few minutes of listening, a DAW session, the Balanced and Low latency modes (Setup), and
   recording a guitar on Input 1.

Report anything that fails as a GitHub issue: the macOS version and Mac model, which step failed, and the driver
log of that minute.

## Results on the Intel hackintosh (Nov 10, macOS 13.7.8, i7-8550U)

The Mbox on a direct USB port, rc.3 installed from the release package. Driver log captured live with
`/usr/bin/log stream` (`log show` crashes on this Mac).

- The release is published as a pre-release with the dmg, the pkg and `SHA256SUMS.txt`; the dmg checksum matches.
- macOS 13 runs the driver in its own process too, "Core Audio Driver (GhostBoxRevenant.driver)".

| Step | Result |
|---|---|
| 1. Install while music plays | Pass, twice. The installer stopped the previous driver process, replugged the Mbox and restarted Core Audio; the driver restarted IO after the Mbox returned. **Music did not pause on macOS 13** and kept playing through both installs (on macOS 27 it pauses itself). |
| 2. The panel connecting while music plays | Pass: the panel quit and reopened, the music kept reaching Out 1/2. |
| 3. Software replug while music plays | Pass, twice: the Mbox was back about 255 ms later and the music returned by itself (gap under a second). |
| 4. Update check | Pass: About shows 1.0.0-rc.3, Up to date; Setup > Advanced as expected. |
| 5. Playback timing | Pass: halio 0.000 % never rendered, 0 jumps, 0 overloads at 128 frames (30.3 ms round trip) and 384 frames (41.0 ms). |
| 6. Everyday use | **Two failures**, fixed for rc.4 (below). The DAW session, latency modes and guitar recording are still to do. |

Failures found during everyday use:

- **Changing the clock source during playback silenced the Mbox** until it was replugged (heard switching to the
  internal clock). It is the clock-selector behaviour described above, now on a deliberate change: rc.4 replugs the
  Mbox after a clock-source change, as it already did for effect presets.
- **The driver process crashed when the Mbox left the bus during playback** (`Core-Audio-Driver-Service` crash
  report, SIGSEGV in the OUT packing). Transfers that came back with "no device" were still handled, and the driver
  packed audio into buffers that were already gone. rc.4 stops handling transfers once the Mbox is gone.

Also seen: each replug logged about 20 "submit in failed" lines (gone in rc.4), and once a short unexplained silence
(17:37) with no driver or panel event, most likely a quiet passage.

