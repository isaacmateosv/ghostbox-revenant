// IsochStream: isochronous USB streaming and the audio rings.
//
// IN completes in real time (after its frames happen on the bus), so it paces everything: it fills the input
// ring, feeds the clock model, records implicit-feedback packet sizes and tops up OUT. OUT packets carry as many
// frames as the matching IN packets and are scheduled a latency-profile lead ahead of the bus.
// Ring positions are device sample times: the HAL reads input frame n and writes output frame n at sample time n.

#pragma once

#include <CoreAudio/CoreAudioTypes.h>

#include "ClockModel.h"

namespace mbox::stream {

// USB thread only.
bool start();
void stop();

// HAL IO thread: copy `frames` frames at device time `start`. Return the frames that were not there (input:
// not captured yet or overwritten, so silence; output: already sent, so lost).
UInt64 readInput(SInt64 start, UInt32 frames, float* dst);
UInt64 writeOutput(SInt64 start, UInt32 frames, const float* src);

ClockModel& deviceClock();

// Statistics for Tools/driver_test (never published through Core Audio: a constantly changing custom property
// made Core Audio's property cache re-notify every client in a loop and pinned coreaudiod at 100% CPU).
struct Stats {
    UInt64 inLateFrames, inReads, outLateFrames, outWrites;
    UInt32 outResyncs, inResyncs, submitErrors, outErrors, minOutLeadUs, maxCallbackDelayUs;
    UInt32 inDone, outDone, lastStatus;
    UInt64 outPos, inPos, outNonZeroSamples;
};
Stats stats();
const int* leadHistogram();  // [0..7] OUT leads (ms) accepted, [8..15] rejected

}  // namespace mbox::stream
