// Test hooks for Tools/driver_test, which loads the driver in-process. Not used by the HAL.

#include <mach/mach_time.h>

#include "IsochStream.h"

using namespace mbox;

#define EXPORT extern "C" __attribute__((visibility("default")))

// [0] clock model's "now", [1] frames captured, [2] model rate (Hz), [3] device time of the next OUT frame
EXPORT void Mbox3_ClockProbe(double out[4]) {
    const ClockModel& clock = stream::deviceClock();
    stream::Stats s = stream::stats();
    out[0] = clock.sampleTimeAt(mach_absolute_time());
    out[1] = (double)s.inPos;
    out[2] = clock.rateHz();
    out[3] = (double)s.outPos;
}

EXPORT void Mbox3_Stats(SInt64 out[10]) {
    stream::Stats s = stream::stats();
    out[0] = s.inLateFrames; out[1] = s.inReads; out[2] = s.outLateFrames; out[3] = s.outWrites;
    out[4] = s.outResyncs; out[5] = s.inResyncs; out[6] = s.submitErrors; out[7] = s.outErrors;
    out[8] = s.minOutLeadUs == UINT32_MAX ? -1 : (SInt64)s.minOutLeadUs; out[9] = s.maxCallbackDelayUs;
}

EXPORT const int* Mbox3_LeadHist() { return stream::leadHistogram(); }

EXPORT void Mbox3_DebugCounters(UInt32 out[6], UInt64* nonZero) {
    stream::Stats s = stream::stats();
    out[0] = s.inDone; out[1] = s.outDone; out[2] = s.outErrors; out[3] = s.submitErrors; out[4] = s.lastStatus;
    out[5] = (UInt32)s.outPos;
    *nonZero = s.outNonZeroSamples;
}
