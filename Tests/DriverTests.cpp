// Unit tests for the parts of the driver and MboxKit that need no hardware: the clock model, the 24-bit packet
// codec, the mixer gain taper and mixer addressing. Run with ./build.sh test.

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "../Sources/Driver/ClockModel.h"
#include "../Sources/Driver/PacketCodec.h"
#include "../Sources/MboxKit/MboxKit.h"

using namespace mbox;

static int gChecks = 0, gFailures = 0;

#define CHECK(cond) do { gChecks++; if (!(cond)) { gFailures++; printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define CHECK_NEAR(a, b, tol) do { gChecks++; double _a = (a), _b = (b); if (!(fabs(_a - _b) <= (tol))) { gFailures++; \
    printf("  FAIL %s:%d  %s = %.6f, expected %.6f +- %g\n", __FILE__, __LINE__, #a, _a, _b, (double)(tol)); } } while (0)

static void testSampleCodec() {
    UInt8 b[3];
    codec::encodeS24(1.0f, b);   CHECK(codec::decodeS24(b) == 8388607);
    codec::encodeS24(-1.0f, b);  CHECK(codec::decodeS24(b) == -8388607);
    codec::encodeS24(4.0f, b);   CHECK(codec::decodeS24(b) == 8388607);   // clamped
    codec::encodeS24(-4.0f, b);  CHECK(codec::decodeS24(b) == -8388607);
    codec::encodeS24(NAN, b);    CHECK(codec::decodeS24(b) == 0);         // NaN plays silence, not a click
    codec::encodeS24(0.5f, b);   CHECK(abs(codec::decodeS24(b) - 4194304) <= 1);
    const UInt8 minusOne[3] = {0xff, 0xff, 0xff}, minFull[3] = {0x00, 0x00, 0x80}, maxFull[3] = {0xff, 0xff, 0x7f};
    CHECK(codec::decodeS24(minusOne) == -1);
    CHECK(codec::decodeS24(minFull) == -8388608);
    CHECK(codec::decodeS24(maxFull) == 8388607);
}

static void testPacketRoundTrip() {
    std::vector<float> out(kRingFrames * kChannels, 0.f), in(kRingFrames * kChannels, 0.f);
    const UInt64 pos = kRingFrames - 2;  // straddles the ring wrap
    const UInt32 frames = 5;
    for (UInt32 i = 0; i < frames; i++)
        for (UInt32 c = 0; c < kChannels; c++) codec::ringFrame(out.data(), pos + i)[c] = (float)(i * kChannels + c) / 64.f - 0.3f;
    UInt8 packet[frames * kBytesPerUSBFrame];
    UInt32 nonZero = codec::packPacket(out.data(), pos, frames, packet);
    CHECK(nonZero == frames * kChannels);
    bool consumed = true;
    for (UInt32 i = 0; i < frames; i++)
        for (UInt32 c = 0; c < kChannels; c++) consumed &= codec::ringFrame(out.data(), pos + i)[c] == 0.f;
    CHECK(consumed);  // sent frames are zeroed: silence if the HAL stops writing
    codec::unpackPacket(packet, frames, in.data(), pos);
    double worst = 0;
    for (UInt32 i = 0; i < frames; i++)
        for (UInt32 c = 0; c < kChannels; c++)
            worst = fmax(worst, fabs(codec::ringFrame(in.data(), pos + i)[c] - ((float)(i * kChannels + c) / 64.f - 0.3f)));
    CHECK(worst < 2.0 / 8388607.0);
}

static void testClockModel() {
    const double ticksPerSecond = 24e6, rate = 48000, ticksPerFrame = ticksPerSecond / rate;
    const double drift = 50e-6;  // the Mbox runs 50 ppm fast against the host clock
    auto hostAt = [&](UInt64 pos) { return 5e6 + pos * ticksPerFrame * (1 - drift); };

    ClockModel clock;
    clock.setHostTicksPerSecond(ticksPerSecond);
    Float64 s; UInt64 h, seed;
    clock.zeroTimeStamp(123, kZeroTSPeriod, &s, &h, &seed);
    CHECK(s == 0 && h == 123);  // before IO starts: harmless values, no division by zero

    clock.reset(1000000, rate);
    const UInt64 seed0 = clock.seed();
    for (UInt64 ms = 1; ms <= 3000; ms++) clock.update(ms * 48, (UInt64)hostAt(ms * 48), rate);
    CHECK(clock.seed() == seed0 + 1);                            // the first bus timestamp re-anchors once
    CHECK_NEAR(clock.rateHz(), rate / (1 - drift), 0.2);           // tracks the true rate

    const UInt64 now = (UInt64)hostAt(3000 * 48) + 1000;
    clock.zeroTimeStamp(now, kZeroTSPeriod, &s, &h, &seed);
    CHECK(fmod(s, kZeroTSPeriod) == 0);
    CHECK(s <= clock.sampleTimeAt(now) && s > clock.sampleTimeAt(now) - kZeroTSPeriod);
    CHECK_NEAR(clock.sampleTimeAt(h), s, 1.0);
    CHECK_NEAR(clock.sampleTimeAt((UInt64)hostAt(3000 * 48)), 3000 * 48, 2.0);

    // A completion held back 3 ms by the USB stack is rejected
    const double before = clock.sampleTimeAt(now);
    clock.update(3001 * 48, (UInt64)(hostAt(3001 * 48) + 0.003 * ticksPerSecond), rate);
    CHECK_NEAR(clock.sampleTimeAt(now), before, 0.5);
    CHECK(clock.seed() == seed0 + 1);

    // More than 100 consecutive out-of-lock timestamps (rate changed underneath) start a new timeline
    for (UInt64 i = 0; i < 102; i++) clock.update((3002 + i) * 48, (UInt64)(hostAt(3002 * 48) + 0.5 * ticksPerSecond + i * 24000), rate);
    CHECK(clock.seed() == seed0 + 2);

    clock.invalidate();
    clock.update(4000 * 48, (UInt64)hostAt(4000 * 48), rate);
    CHECK(clock.seed() == seed0 + 3);
}

static void testGainTaper() {
    uint8_t g[2];
    mbox_pct_to_gain(0, g);    CHECK(g[0] == 0x00 && g[1] == 0x80);  // muted
    mbox_pct_to_gain(100, g);  CHECK(g[0] == 0x00 && g[1] == 0x00);  // unity
    mbox_pct_to_gain(150, g);  CHECK(g[0] == 0x00 && g[1] == 0x00);  // never above unity
    CHECK_NEAR(mbox_pct_to_db(50), -6.0, 0.01);
    CHECK_NEAR(mbox_pct_to_db(10), -30.75, 0.01);                     // the low segment, linear in dB
    CHECK(fabs(mbox_pct_to_db(15) - mbox_pct_to_db(14)) < 3.5);       // no jump where the segments meet
    CHECK(mbox_pct_to_db(0) < -900);
    bool monotonic = true;
    for (int p = 1; p < 100; p++) monotonic &= mbox_pct_to_db(p + 1) >= mbox_pct_to_db(p);
    CHECK(monotonic);
    CHECK(mbox_pct_to_db(1) >= -60.0);
    // Fractional levels keep the low segment fine-grained (whole percents step 2.9 dB there)
    CHECK_NEAR(mbox_level_to_db(13.79), -20.0, 0.3);
    CHECK_NEAR(mbox_level_to_db(50.0), mbox_pct_to_db(50), 1e-9);
    CHECK(mbox_level_to_db(-1) < -900 && mbox_level_to_db(NAN) < -900);
}

static void testAddressing() {
    CHECK(mbox_mixer_control(MBOX_MIX_IN_HARDWARE + 0, MBOX_MIX_OUT_ANALOG) == 0x0110);
    CHECK(mbox_mixer_control(MBOX_MIX_IN_HARDWARE + 1, MBOX_MIX_OUT_SPDIF + 1) == 0x0117);
    CHECK(mbox_mixer_control(MBOX_MIX_IN_SOFTWARE + 3, MBOX_MIX_OUT_ANALOG + 1) == 0x010d);
    CHECK(mbox_mixer_control(MBOX_MIX_IN_FX_RETURN, MBOX_MIX_OUT_SPDIF) == 0x0122);
    CHECK(mbox_fx_send_control(0, 2) == 0x0102);
    CHECK(mbox_fx_send_control(1, 2) == 0x0106);
}

int main(int argc, char** argv) {
    if (argc > 1 && !strcmp(argv[1], "--taper-table")) {
        // The hardware taper in quarter-percent steps, for Tests/PanelTests.js, which checks the panel's mirror of it
        printf("[");
        for (int q = 0; q <= 400; q++) {
            double db = mbox_level_to_db(q / 4.0);
            if (db < -900) printf("null"); else printf("%.6f", db);
            printf(q < 400 ? "," : "]\n");
        }
        return 0;
    }
    struct { const char* name; void (*run)(); } tests[] = {
        {"sample codec", testSampleCodec}, {"packet round trip", testPacketRoundTrip}, {"clock model", testClockModel},
        {"gain taper", testGainTaper}, {"mixer addressing", testAddressing},
    };
    for (auto& t : tests) {
        int before = gFailures;
        t.run();
        printf("%s %s\n", gFailures == before ? "ok  " : "FAIL", t.name);
    }
    printf("driver tests: %d checks, %d failed\n", gChecks, gFailures);
    return gFailures ? 1 : 0;
}
