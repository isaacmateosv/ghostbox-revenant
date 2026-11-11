# The Mbox 3 USB protocol

What this project knows about how the Avid Mbox (3rd generation) talks over USB, verified on hardware (firmware
1.08) unless marked otherwise. The same facts are encoded once in
[`Sources/Shared/MboxProtocol.h`](../Sources/Shared/MboxProtocol.h), which the driver, the library, the CLI and
the app all share.

## Device

| | |
|---|---|
| USB ID | `0dba:5000` (Digidesign) |
| Speed | USB 2.0 high speed |
| Class | USB Audio Class 2 descriptors behind **vendor class codes (`0xFF`)**, so macOS's class driver ignores the device |
| Interface 0 | Firmware update: a DFU 1.1 runtime interface named "Mbox DFU" (detach timeout 2 s, 1024-byte transfers). **Never used**: GhostBox sends it nothing, because a bad firmware write would brick the unit |
| Interface 1 | Audio control: all the units below |
| Interface 2 | Playback: alt 1, endpoint `0x01`, isochronous OUT, 4 channels × 24-bit (Software Returns 1-4). Alt 2 declares a 2-channel mode (78-byte packets) that Avid's driver never selects; unused |
| Interface 3 | Capture: alt 1, endpoint `0x81`, isochronous IN, 4 channels × 24-bit (Input 1, Input 2, S/PDIF L, S/PDIF R) |
| Interface 4 | Class-compliant USB MIDI: ports **External** (the 5-pin DIN jacks) and **Control** (Avid's control port) |
| Max packet | 156 bytes (13 frames × 12 bytes, enough for 96 kHz) |
| Sample rates | 44.1, 48, 88.2, 96 kHz |

## Streaming

- **Implicit feedback**: each OUT packet carries as many frames as the matching IN packet. There is no feedback
  endpoint.
- OUT packets in a transfer are **packed back to back** (packet *n* starts right after packet *n−1*'s bytes).
  Fixed 156-byte slots produce garbled audio.
- Samples are 24-bit little-endian, interleaved, 4 channels.
- The host controller rejects isochronous frames scheduled too close to the current bus frame; keeping OUT 5-10
  ms ahead of the bus is reliable.
- Selecting the streaming alt setting again does not re-arm playback after a host process died mid-stream:
  select alt 0 first. After Core Audio is restarted mid-stream the device may ignore playback until it is
  re-enumerated (a software replug works).

## Control requests

All controls are class requests to interface 1, with `wIndex = unit << 8 | 1`:

| Direction | `bmRequestType` | `bRequest` |
|---|---|---|
| Set | `0x21` | `0x01` CUR (or `0x03` MEM for the extension unit) |
| Get | `0xA1` | `0x01` CUR (or `0x03` MEM), `0x02` RANGE |

### Units

| Unit | `wIndex` | What it is |
|---|---|---|
| `0x20` | `0x2001` | Extension unit: front-panel functions and meters (memory requests, `bRequest 0x03`) |
| `0x40` | `0x4001` | Monitor mixer (two stereo mixes) |
| `0x42` | `0x4201` | FX send mixer |
| `0x43` | `0x4301` | Effect unit (reverb / delay) |
| `0x80` | `0x8001` | Clock selector |
| `0x81` | `0x8101` | Internal clock |
| `0x82` | `0x8201` | S/PDIF clock |

### Extension unit registers (`wIndex 0x2001`, `bRequest 0x03`, `wValue` = register)

| Register | Meaning | Values |
|---|---|---|
| `0x00` | Host Control (Avid's older panel called it "Disable Host Control"; Pro Tools' Low Latency Monitoring) | Write **2**, as Avid's driver does at start-up: the hardware mixer feeds the inputs to the outputs. With 0 the mixer's hardware-input crosspoints are ignored and no input reaches Out 1/2 or the headphones (Nov 10, 2026: heard, and Out 1/2 on the meter block followed Input 1 only with 1 or 2). Reads back what was written. |
| `0x01` | Mono | 0/1 |
| `0x02` | Dim | 0/1 |
| `0x03` | Tuner mode (also: Dim + Mono pressed together) | 0/1 |
| `0x04` | Button LEDs dim instead of off | 0/1 |
| `0x05` | Soft-button hold time | `0x03` 250 ms, `0x05` 500 ms, `0x08` 750 ms, `0x0a` 1 s |
| `0x10` | Meter block (read) | 15 × uint16 LE, full scale 32767 |

Meter block words: 0-1 Input 1/2, 2-3 S/PDIF in L/R, 4-7 Software Returns 1-4, 8-9 Outputs 1/2, 10-11 Outputs
3/4, 12 FX input, 13-14 FX output L/R.

### Monitor mixer (`wIndex 0x4001`)

`wValue = 0x0100 | (input × 4 + output)`, data = gain as int16 little-endian in 1/256 dB (`0x8000` = off).

| Inputs | Outputs |
|---|---|
| 0-3 Software Returns 1-4, 4-7 Hardware inputs (In 1, In 2, S/PDIF L, S/PDIF R), 8 FX return | 0-1 Out 1/2 and headphones (the "Analog 1/2" mix), 2-3 Out 3/4 = S/PDIF out (the "S/PDIF L/R" mix) |

- The hardware steps in 0.25 dB; 0 dB is the maximum this project uses (RANGE reports no ranges).
- Mixer and FX-send gains are **write-only**: reading them returns 0. Software has to remember what it wrote.
- At power-up the mixer is silent; a default state (returns 1/2 to Out 1/2 and 3/4 to Out 3/4 at unity, inputs
  muted) gives sound. The Linux kernel's default setup and this project's `mbox_setup_defaults` write it.

### FX sends (`wIndex 0x4201`)

`wValue 0x0100-0x0103` Software Returns 1-4, `0x0104-0x0107` hardware inputs; gain encoded as in the mixer.

### Effect unit (`wIndex 0x4301`)

| `wValue` | Control | Size |
|---|---|---|
| `0x0200` | Preset: 0-5 reverbs (Room 1-3, Hall 1-2, Plate), 6 Delay, 7 Echo | 1 byte |
| `0x0300` | Return volume | 1 byte |
| `0x0400` | Duration | 2 bytes LE |
| `0x0500` | Feedback (Delay and Echo only) | 1 byte |

The descriptors declare it as a USB Audio Class 2 reverberation effect unit: `wValue` is the control selector × 256
(type `0x02`, level `0x03`, time `0x04`, feedback `0x05`); its enable control is read-only.

### Clock

| Request | Meaning |
|---|---|
| CUR `0x0100` @ `0x8001` | Clock source: 1 internal, 2 S/PDIF |
| CUR `0x0100` @ `0x8101` | Internal rate, 4 bytes LE (Hz) |
| CUR `0x0100` @ `0x8201` | S/PDIF rate |
| CUR `0x0200` @ `0x8201` | S/PDIF clock valid. Only meaningful while the S/PDIF clock is selected (reads 1 otherwise). |

The Mbox **powers up on the S/PDIF clock**; without an S/PDIF signal it does not stream. Switching to the internal
clock fixes that.

## What Avid's own driver sends

From Wireshark/USBPcap captures of Avid's Windows driver and control panel (two fresh plug-ins, then normal use),
decoded in November 2026:

1. `SET_CONFIGURATION 1`; interfaces 2, 3 and 4 to alt 0, then interfaces 2 and 3 to alt 1.
2. Clock selector to 1 (internal) and the internal rate, then GET clock valid and GET rate.
3. Every mixer crosspoint and FX send to `0x8000` (off), except Software Returns 1-4 to Outputs 1-4 at 0 dB.
4. Low Latency Monitoring register 2, Dim 0, Mono 0.
5. Effect preset 0, duration `0x3fff`, feedback `0x3f`, volume `0x3f`.
6. Hold time `0x05` (500 ms), button LEDs off.

Afterwards the panel reads Mono, Dim and Tuner every 250 ms and the meter block while it is shown. A sample-rate
change (made while idle) is: SET internal rate, GET valid, GET rate, SET clock selector 1. The first meter read
after power-up returns garbage.

GhostBox writes the same controls with the same request types. Its reads go a little further (all front-panel
registers, the S/PDIF clock), and, since rc.5, it writes 2 to the Host Control register like Avid's driver (up to rc.4 it wrote 0, which kept the inputs off the outputs).

## Tuner

While tuner mode is on, the Mbox measures pitch itself and sends it on the **Control** MIDI port as Polyphonic
Aftertouch: `0xAn note cents`, cents as a signed 7-bit value clamped to ±50. The front-panel LEDs show it too
(Input 1 red = flat, Input 2 red = sharp, both green = in tune). *Not yet confirmed on hardware:* whether the
note byte counts from A (0-11) or is a MIDI note number.

## Multi button

Sends a MIDI message on the Control port (learned by the app). *Not yet confirmed on hardware:* which message.

## Not controllable over USB

Phantom power (+48V), gain, the −20 dB pad, Soft Limit and the front/rear source switches are analog controls on
the unit. Neither this project nor Avid's own driver can switch or read them.
