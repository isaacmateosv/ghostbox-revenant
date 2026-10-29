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
| Interface 1 | Audio control: all the units below |
| Interface 2 | Playback: alt 1, endpoint `0x01`, isochronous OUT, 4 channels × 24-bit (Software Returns 1-4) |
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
| `0x00` | Low Latency Monitoring (a Pro Tools mode) | 0/1. Keep 0: Avid documents inputs muting in this mode. |
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

### Clock

| Request | Meaning |
|---|---|
| CUR `0x0100` @ `0x8001` | Clock source: 1 internal, 2 S/PDIF |
| CUR `0x0100` @ `0x8101` | Internal rate, 4 bytes LE (Hz) |
| CUR `0x0100` @ `0x8201` | S/PDIF rate |
| CUR `0x0200` @ `0x8201` | S/PDIF clock valid. Only meaningful while the S/PDIF clock is selected (reads 1 otherwise). |

The Mbox **powers up on the S/PDIF clock**; without an S/PDIF signal it does not stream. Switching to the internal
clock fixes that.

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
