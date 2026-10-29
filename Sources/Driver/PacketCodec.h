// PacketCodec: 24-bit little-endian USB audio frames <-> the driver's interleaved float rings.
// Pure functions (no USB, no globals) so they can be unit tested; see Tests/DriverTests.cpp.

#pragma once

#include <cmath>
#include <cstdint>

#include "DriverConfig.h"

namespace mbox::codec {

constexpr float kFromS24 = 1.0f / 8388608.0f;

inline int32_t decodeS24(const UInt8* p) {
    uint32_t v = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16);
    return (int32_t)(v << 8) >> 8;  // sign-extend bit 23
}

// Clamps to full scale; NaN becomes silence instead of a full-scale click.
inline void encodeS24(float v, UInt8* q) {
    if (!(v >= -1.f && v <= 1.f)) v = v > 1.f ? 1.f : (v < -1.f ? -1.f : 0.f);
    int32_t s = (int32_t)lrintf(v * 8388607.0f);
    q[0] = (UInt8)(s & 0xff); q[1] = (UInt8)((s >> 8) & 0xff); q[2] = (UInt8)((s >> 16) & 0xff);
}

inline float* ringFrame(float* ring, UInt64 pos) { return ring + (pos & (kRingFrames - 1)) * kChannels; }

// One IN packet (`frames` frames of kChannels x 24-bit) into the ring at `pos`.
inline void unpackPacket(const UInt8* src, UInt32 frames, float* ring, UInt64 pos) {
    for (UInt32 i = 0; i < frames; i++) {
        float* dst = ringFrame(ring, pos + i);
        const UInt8* p = src + i * kBytesPerUSBFrame;
        for (UInt32 c = 0; c < kChannels; c++) dst[c] = (float)decodeS24(p + c * 3) * kFromS24;
    }
}

// One OUT packet from the ring at `pos` into `dst`. Consumed ring frames are zeroed, so the hardware plays
// silence if the HAL stops writing. Returns the number of non-zero samples (a debug statistic).
inline UInt32 packPacket(float* ring, UInt64 pos, UInt32 frames, UInt8* dst) {
    UInt32 nonZero = 0;
    for (UInt32 i = 0; i < frames; i++) {
        float* src = ringFrame(ring, pos + i);
        UInt8* q = dst + i * kBytesPerUSBFrame;
        for (UInt32 c = 0; c < kChannels; c++) {
            float v = src[c];
            src[c] = 0;
            nonZero += (v != 0);
            encodeS24(v, q + c * 3);
        }
    }
    return nonZero;
}

}  // namespace mbox::codec
