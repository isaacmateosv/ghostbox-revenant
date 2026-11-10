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
