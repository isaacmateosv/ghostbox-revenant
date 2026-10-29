// MboxProtocol: the Avid Mbox 3 USB protocol, shared by the Core Audio driver, MboxKit, mbox3-ctl and the app.
// Plain C so the driver (C++), the tools and Swift (through the bridging header) all read the same definitions.
//
// USB 0dba:5000, high speed. USB Audio Class 2 descriptors under vendor class codes, so Apple's driver ignores it.
//   Playback: interface 2 alt 1, EP 0x01 isochronous OUT, 4 ch x 24-bit (Software Returns 1-4),
//             implicit feedback: each OUT packet carries as many frames as the matching IN packet
//   Capture:  interface 3 alt 1, EP 0x81 isochronous IN, 4 ch x 24-bit (In 1, In 2, S/PDIF L, S/PDIF R)
//   Interface 4: class-compliant USB MIDI, ports "External" (5-pin DIN) and "Control" (Avid control port)
//
// Control path: class requests to interface 1, wIndex = unit << 8 | 1 (confirmed against Avid's 1.2.13 daemon):
//   Extension unit 0x20, memory requests (bRequest 0x03):
//     0x00 Low Latency Monitoring  0x01 Mono  0x02 Dim  0x03 Tuner  0x04 Dim button LEDs instead of off
//     0x05 Long-press time (3/5/8/10 = 250/500/750/1000 ms)  0x10 Meter block (15 x uint16 LE, full scale 32767)
//   Mixer unit 0x40: wValue 0x01NN, NN = input * 4 + output. Inputs 0-3 software returns, 4-7 hardware inputs,
//     8 FX return; outputs 0-1 Out 1/2 (and headphones), 2-3 Out 3/4 (S/PDIF out). Gain: int16, 1/256 dB.
//   FX send mixer 0x42: wValue 0x0100-0x0103 software returns, 0x0104-0x0107 hardware inputs
//   Effect unit 0x43: wValue 0x0200 preset, 0x0300 volume, 0x0400 duration (16-bit), 0x0500 feedback
//   Clock selector 0x80 (1 internal, 2 S/PDIF), internal clock 0x81, S/PDIF clock 0x82:
//     rate = CUR 0x0100 (4 bytes LE), clock valid = CUR 0x0200
// While tuner mode is on, pitch arrives as MIDI Poly Aftertouch (0xAn note cents) on the Control port.
// Phantom power, gain, pad, Soft Limit and the front/rear source switches are analog front-panel controls
// with no USB access (Avid's driver has none either).

#ifndef MBOX_PROTOCOL_H
#define MBOX_PROTOCOL_H

#include <stdint.h>

#define MBOX_VENDOR_ID 0x0dba
#define MBOX_PRODUCT_ID 0x5000
#define MBOX_DEVICE_UID "Mbox3:0dba:5000"
#define MBOX_MODEL_UID "Mbox3"
#define MBOX_DRIVER_PATH "/Library/Audio/Plug-Ins/HAL/GhostBoxRevenant.driver"
#define MBOX_LEGACY_DRIVER_PATH "/Library/Audio/Plug-Ins/HAL/Mbox3.driver"  // installed by builds before the rename
#ifndef GHOSTBOX_APP_ID
#define GHOSTBOX_APP_ID "io.github.ghostbox-revenant"  // build.sh passes the real bundle ID
#endif
#define MBOX_CONTROL_APP_ID GHOSTBOX_APP_ID           // the app Audio MIDI Setup opens for this device
#define MBOX_LATENCY_SELECTOR 0x6d62786cu  // 'mbxl', the driver's latency-mode custom property

enum { MBOX_LATENCY_SAFE = 0, MBOX_LATENCY_BALANCED = 1, MBOX_LATENCY_LOW = 2, MBOX_LATENCY_MODES = 3 };

// Streaming interfaces and endpoints
enum { MBOX_IF_PLAYBACK = 2, MBOX_IF_CAPTURE = 3, MBOX_ALT_STREAMING = 1 };
enum { MBOX_EP_PLAYBACK = 0x01, MBOX_EP_CAPTURE = 0x81 };

// Requests
enum { MBOX_REQ_CUR = 0x01, MBOX_REQ_RANGE = 0x02, MBOX_REQ_MEM = 0x03 };
enum { MBOX_RT_SET = 0x21, MBOX_RT_GET = 0xA1 };

// Units (wIndex)
enum {
    MBOX_UNIT_EXTENSION = 0x2001, MBOX_UNIT_MIXER = 0x4001, MBOX_UNIT_FX_SENDS = 0x4201, MBOX_UNIT_EFFECT = 0x4301,
    MBOX_UNIT_CLOCK_SELECTOR = 0x8001, MBOX_UNIT_CLOCK_INTERNAL = 0x8101, MBOX_UNIT_CLOCK_SPDIF = 0x8201,
};

// Clock controls (wValue)
enum { MBOX_CLOCK_CTL_RATE = 0x0100, MBOX_CLOCK_CTL_VALID = 0x0200, MBOX_CLOCK_CTL_SELECTOR = 0x0100 };
enum { MBOX_CLOCK_INTERNAL = 1, MBOX_CLOCK_SPDIF = 2 };

// Effect unit controls (wValue)
enum { MBOX_EFFECT_PRESET = 0x0200, MBOX_EFFECT_VOLUME = 0x0300, MBOX_EFFECT_DURATION = 0x0400, MBOX_EFFECT_FEEDBACK = 0x0500 };
enum { MBOX_EFFECT_DELAY = 6, MBOX_EFFECT_ECHO = 7 };  // presets 0-5 are reverbs; feedback applies to 6 and 7

// Extension unit registers (wValue of memory requests)
enum {
    MBOX_REG_LLM = 0x00, MBOX_REG_MONO = 0x01, MBOX_REG_DIM = 0x02, MBOX_REG_TUNER = 0x03,
    MBOX_REG_LED_DIM = 0x04, MBOX_REG_HOLD = 0x05, MBOX_REG_METERS = 0x10,
};

// Long-press time codes for MBOX_REG_HOLD
enum { MBOX_HOLD_250MS = 0x03, MBOX_HOLD_500MS = 0x05, MBOX_HOLD_750MS = 0x08, MBOX_HOLD_1000MS = 0x0a };

// Meter block word indices
enum {
    MBOX_METER_IN1 = 0, MBOX_METER_IN2 = 1, MBOX_METER_SPDIF_L = 2, MBOX_METER_SPDIF_R = 3,
    MBOX_METER_SW1 = 4, MBOX_METER_SW2 = 5, MBOX_METER_SW3 = 6, MBOX_METER_SW4 = 7,
    MBOX_METER_OUT1 = 8, MBOX_METER_OUT2 = 9, MBOX_METER_OUT3 = 10, MBOX_METER_OUT4 = 11,
    MBOX_METER_FX_IN = 12, MBOX_METER_FX_L = 13, MBOX_METER_FX_R = 14,
    MBOX_METER_COUNT = 15,
};
#define MBOX_METER_FULL_SCALE 32767

// Mixer addressing
enum { MBOX_MIX_IN_SOFTWARE = 0, MBOX_MIX_IN_HARDWARE = 4, MBOX_MIX_IN_FX_RETURN = 8 };
enum { MBOX_MIX_OUT_ANALOG = 0, MBOX_MIX_OUT_SPDIF = 2 };  // first output of each stereo pair

static inline uint16_t mbox_mixer_control(int input, int output) { return (uint16_t)(0x0100 | (input * 4 + output)); }
static inline uint16_t mbox_fx_send_control(int hardware, int channel) { return (uint16_t)(0x0100 | ((hardware ? 4 : 0) + channel)); }

#endif
