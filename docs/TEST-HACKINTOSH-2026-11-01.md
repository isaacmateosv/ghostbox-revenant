# Test run: Intel hackintosh, 2026-11-01

A day of testing with a real Mbox 3 on an OpenCore laptop (MacBookPro15,2 SMBIOS, i7-8550U, **macOS 13.7.8
Ventura**), first unattended, then with the owner. It found and fixed the choppy playback. For what is still
pending overall, see [STATUS.md](STATUS.md).

## Fixed on this branch

| Problem | Cause | Fix | Verified through coreaudiod |
|---|---|---|---|
| Choppy playback | `GetZeroTimeStamp` revised boundaries it had already returned (the clock model moves with every USB timestamp: up to 86 µs). Core Audio's raw IO clock logged `Re-anchoring IO timeline. Sample time is not consecutive.` about 75 times a second and skipped output: 2.3–2.7 % of the frames at 384-frame buffers, a third at 128, up to three quarters at 96 kHz. BlackHole on the same Mac: 0 %. | Zero timestamps from a published timeline: never revised, exactly one period apart, steered toward the model within 500 ppm | 0 % lost at every buffer from 32 to 4096 frames and every rate; no re-anchors |
| Buffers capped at 384 frames | Core Audio derives the largest IO buffer from the zero timestamp period (1024) | Period = ring size (16384) | Buffer range 15–4096 at every rate and latency mode |
| Moving an FX send or effect knob silenced the Mbox | Writing the effect **preset** while audio streams silences the playback, monitor and FX outputs until the Mbox re-enumerates (any value; a stream restart does not help; right after an enumeration it is harmless). The panel re-sent the preset with every effect change and on every attach. | Send only changed effect controls; keep the preset of a Mbox that has been up for a while on attach; replug in software after a deliberate preset change | Knob moves and an app relaunch keep the sound; an effect type change recovers after about a second |

## How it was measured

- `Tools/halio`: opens the Mbox through Core Audio with its own IOProc (output only, so no microphone prompt), plays
  a quiet tone and reports the share of the output timeline never rendered, timeline jumps and overloads. Run it with
  `--uid BlackHole2ch_UID` for a control.
- `Tools/gbharness`: loads a driver build in-process with the HAL's IO-cycle convention and prints the driver's own
  counters (late frames, resyncs, OUT lead, USB completion delay) once a second. `--zts file.csv` records every zero
  timestamp. It cannot see the raw-clock problem above, because it does not reproduce Core Audio's consistency check.
- `Tools/carange`: the buffer range, safety offsets and zero timestamp period Core Audio derives for each latency
  mode and rate.
- The Mbox's own meter block (`mbox3-ctl meters`) shows what reaches the hardware (Software Returns, Out 1/2, FX).

## Other results

- Build, unit tests (now 659 checks), `dist` and artifact verification pass on Intel Ventura with Xcode 15.2.
- The driver loads and streams on macOS 13: the first Ventura data point.
- Software replug while idle and during playback: the driver detaches, re-attaches after about 250 ms and restarts
  streaming by itself; the panel reconnects and restores the mix.
- Local API: wrong Host or Origin → 403, non-JSON POST → 415, other methods → 405, path traversal → 404.
- In-process soak, 15 minutes under CPU, disk, app-launch and compile load at 128 frames: 0 late frames in 43 million,
  worst USB completion delay 2.1 ms.

## Still open

- **Phantom power**: switching +48 V on during playback made the Mbox ignore playback once (input kept working), with
  the Mbox behind two hubs in a bus-powered USB-C dongle. Retest on a direct port before blaming the software.
- The "Audio from the computer" status chip uses post-fader meters, so it reads "No audio" while the driver streams
  (muted, soloed-out or quiet returns). `Engine.swift`, `readMeters`.
- A sample-rate request that arrives while another is pending is dropped: `requestRate` compares against the current
  rate, not the pending one (44.1 → 48 kHz in quick succession stayed at 44.1).
- Streaming costs about 19 % of a core on this i7, 84 % of it kernel time (1 ms transfers each way and a bus-frame
  query per OUT top-up).
- On unplug, failed completions are resubmitted: about 64 "submit in failed" log lines in a millisecond.
- `submitIn` drops a transfer for good after two failed attempts, so repeated resyncs shrink the IN queue.
- The S/PDIF follow timer runs synchronous control requests on the streaming USB thread once a second.
- `mbox3-ctl status`, `latency` and `ca-rate` have no timeout when Core Audio client start-up hangs.
- HTTP server: malformed request lines and negative Content-Length keep the socket open; no 413; the Host check is a
  prefix match.

## Not the project's

On this hackintosh: the AppleALC input engines wedged after a wake, which hangs every new Core Audio client until a
reboot; `log show` and `logd` crash reading the log store; a kernel panic in `AppleEFINVRAM` (NVRAM write, CPU
unresponsive) at 19:21.
