// Mbox 3 Core Audio driver: compile-time configuration shared by all driver modules.
//
// Modules (all run inside the HAL's driver process):
//   PlugIn.cpp         AudioServerPlugIn entry points: lifecycle, config changes, IO
//   ObjectModel.cpp    the Core Audio objects (plug-in, device, two streams) and their properties
//   UsbHost.cpp        the USB thread: hot plug, control requests, run loop
//   HardwareClock.cpp  the Mbox's clock: rate, source, S/PDIF following
//   IsochStream.cpp    isochronous streaming and the audio rings
//   ClockModel.cpp     sample time <-> host time from USB timestamps (zero timestamps)
//   PacketCodec.h      24-bit packet packing (pure, unit tested)
//   DebugExports.cpp   counters for Tools/driver_test

#pragma once

#include <CoreAudio/AudioServerPlugIn.h>

#include "../Shared/MboxProtocol.h"

#ifndef GHOSTBOX_DRIVER_ID
#define GHOSTBOX_DRIVER_ID "io.github.ghostbox-revenant.driver"  // build.sh passes the real bundle ID
#endif

namespace mbox {

enum : AudioObjectID { kObjPlugIn = kAudioObjectPlugInObject, kObjDevice = 2, kObjStreamIn = 3, kObjStreamOut = 4 };

constexpr UInt32 kChannels = 4, kBytesPerUSBFrame = kChannels * 3;
constexpr UInt32 kMaxPacket = 156;               // 13 frames x 12 bytes (enough for 96 kHz)
constexpr UInt32 kMicroframesPerXfer = 8;        // 1 ms per transfer
// USB completions usually arrive within 0.5 ms but are sometimes held back by the USB stack for up to ~5 ms
// (measured; real-time priority does not help), so every queue and safety offset must ride out such stalls.
// Under load they can stall for more than 16 ms (seen while Safari launched), so IN keeps 32 ms queued: IN depth
// adds no latency, and a schedule that falls behind the bus costs a resync.
constexpr UInt32 kInXfers = 32, kOutXfers = 16;  // transfers in flight (1 ms each)
constexpr UInt32 kRingFrames = 16384;            // power of two
constexpr UInt32 kZeroTSPeriod = 1024;
constexpr UInt32 kFeedbackSlots = 4096;          // power of two

constexpr Float64 kRates[] = {44100, 48000, 88200, 96000};
constexpr UInt32 kRateCount = sizeof(kRates) / sizeof(kRates[0]);

inline bool isSupportedRate(Float64 rate) {
    for (Float64 r : kRates) if (r == rate) return true;
    return false;
}

// Latency modes, chosen in GhostBox Revenant GUI (custom property 'mbxl', kept in the HAL's plug-in storage).
// inSafety: input data can lag the bus by the worst completion stall (7.3 ms seen); outLead: OUT is scheduled
// this far ahead of the bus; outMargin: extra output safety beyond the lead.
struct LatencyProfile { UInt32 inSafetyMs, outLeadMs, outMarginMs; };
constexpr LatencyProfile kLatencyProfiles[MBOX_LATENCY_MODES] = {{10, 10, 3}, {6, 7, 2}, {4, 5, 1}};  // safe, balanced, low
constexpr AudioObjectPropertySelector kLatencySelector = MBOX_LATENCY_SELECTOR;
constexpr UInt64 kActionLatencyBase = 0x4C00;  // config-change actions below any sample rate select a latency mode
constexpr const char* kLatencyStorageKey = "latency_mode";

constexpr const char* kInNames[kChannels] = {"Input 1", "Input 2", "S/PDIF L", "S/PDIF R"};
constexpr const char* kOutNames[kChannels] = {"Software Return 1", "Software Return 2", "Software Return 3", "Software Return 4"};

}  // namespace mbox
