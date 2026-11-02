// ClockModel: maps device sample time to host time. Fed with the host time at which a sample position was
// completed on the bus (per-microframe USB timestamps of the IN stream); read by the HAL as zero timestamps.
// Thread safe: updated on the USB thread, read on the HAL's IO thread.

#pragma once

#include <CoreAudio/CoreAudioTypes.h>
#include <os/lock.h>

namespace mbox {

class ClockModel {
public:
    void setHostTicksPerSecond(double ticks) { hostTicksPerSecond_ = ticks; }

    // Startup estimate: sample 0 is now, at the nominal rate. Bumps the seed.
    void reset(UInt64 hostNow, Float64 sampleRate);
    // Sample `samplePos` completed at `hostTime`. The first update after reset/invalidate re-anchors (new seed);
    // later ones nudge the phase and track the true rate, rejecting outliers (late completions).
    void update(UInt64 samplePos, UInt64 hostTime, Float64 sampleRate);
    // Forget the anchor: the next update starts a new timeline (stream restarted or rate changed underneath).
    void invalidate();

    // Most recent period boundary at or before `hostNow`, as the HAL's GetZeroTimeStamp wants it. Boundaries come
    // from a published timeline, not straight from the model: once a boundary is returned its host time never
    // changes, and the next one is exactly `period` frames later. The HAL's raw IO clock re-anchors its timeline
    // (dropping output) whenever a zero timestamp is revised, and the model moves with every USB timestamp.
    void zeroTimeStamp(UInt64 hostNow, UInt32 period, Float64* sample, UInt64* host, UInt64* seed);
    Float64 sampleTimeAt(UInt64 hostNow) const;
    Float64 rateHz() const;
    UInt64 seed() const;

private:
    mutable os_unfair_lock lock_ = OS_UNFAIR_LOCK_INIT;
    double hostTicksPerSecond_ = 0;
    double anchorSample_ = 0, anchorHost_ = 0, ticksPerFrame_ = 0;
    double firstSample_ = -1, firstHost_ = 0;
    UInt64 seed_ = 1;
    UInt32 rejects_ = 0;  // consecutive out-of-lock timestamps
    // Published timeline: the current boundary and the length of the period that follows it (host ticks per frame)
    double pubSample_ = -1, pubHost_ = 0, pubTicksPerFrame_ = 0;
    UInt64 pubSeed_ = 0;

    double nominalTicksPerFrame(Float64 sampleRate) const { return hostTicksPerSecond_ / sampleRate; }
    double modelSampleAt(double host) const { return anchorSample_ + (host - anchorHost_) / ticksPerFrame_; }
    void anchor(double sample, double host, Float64 sampleRate);
};

}  // namespace mbox
