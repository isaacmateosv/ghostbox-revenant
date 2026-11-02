#include "ClockModel.h"

#include <algorithm>
#include <cmath>

namespace mbox {

namespace {
struct Locker {
    os_unfair_lock* lock;
    explicit Locker(os_unfair_lock* l) : lock(l) { os_unfair_lock_lock(lock); }
    ~Locker() { os_unfair_lock_unlock(lock); }
};
}  // namespace

void ClockModel::anchor(double sample, double host, Float64 sampleRate) {
    firstSample_ = sample; firstHost_ = host;
    anchorSample_ = sample; anchorHost_ = host;
    ticksPerFrame_ = nominalTicksPerFrame(sampleRate);
    seed_++;
    rejects_ = 0;
}

void ClockModel::reset(UInt64 hostNow, Float64 sampleRate) {
    Locker l(&lock_);
    anchorSample_ = 0;
    anchorHost_ = (double)hostNow;
    ticksPerFrame_ = nominalTicksPerFrame(sampleRate);
    firstSample_ = -1;
    seed_++;
}

void ClockModel::update(UInt64 samplePos, UInt64 hostTime, Float64 sampleRate) {
    Locker l(&lock_);
    double s = (double)samplePos, h = (double)hostTime;
    if (firstSample_ < 0) {
        // First real bus timestamp replaces the startup estimate: the new seed tells the HAL the timeline moved
        anchor(s, h, sampleRate);
        return;
    }
    double predicted = anchorHost_ + (s - anchorSample_) * ticksPerFrame_;
    double err = h - predicted;
    if (fabs(err) < hostTicksPerSecond_ * 0.002) {
        // In lock: nudge the phase gently
        anchorSample_ = s;
        anchorHost_ = predicted + err * 0.02;
        rejects_ = 0;
    } else if (++rejects_ > 100) {
        // ~100 ms out of lock (e.g. the hardware rate was changed underneath us): re-anchor
        anchor(s, h, sampleRate);
    }
    double span = s - firstSample_;
    if (span > sampleRate * 0.5) {
        double measured = (h - firstHost_) / span;
        double nominal = nominalTicksPerFrame(sampleRate);
        if (fabs(measured / nominal - 1.0) < 0.002) ticksPerFrame_ += (measured - ticksPerFrame_) * 0.01;
    }
}

void ClockModel::invalidate() {
    Locker l(&lock_);
    firstSample_ = -1;
}

void ClockModel::zeroTimeStamp(UInt64 hostNow, UInt32 period, Float64* sample, UInt64* host, UInt64* seed) {
    // Each period may run up to this much faster or slower than the model, to pull the published timeline toward it
    constexpr double kMaxSteer = 500e-6, kPhaseGain = 0.25;
    Locker l(&lock_);
    if (ticksPerFrame_ <= 0) { *sample = 0; *host = hostNow; *seed = seed_; return; }  // IO never started
    const double now = (double)hostNow;
    for (int pass = 0; pass < 2; pass++) {
        if (pubSeed_ != seed_ || pubSample_ < 0) {
            // New timeline (stream started or the model re-anchored): start at the model's most recent boundary
            double boundary = std::max(0.0, floor(modelSampleAt(now) / period) * period);
            pubSample_ = boundary;
            pubHost_ = anchorHost_ + (boundary - anchorSample_) * ticksPerFrame_;
            pubTicksPerFrame_ = ticksPerFrame_;
            pubSeed_ = seed_;
        }
        while (now >= pubHost_ + period * pubTicksPerFrame_) {
            pubHost_ += period * pubTicksPerFrame_;
            pubSample_ += period;
            // Frames the device is ahead of the published timeline at this boundary; take a quarter of them out over
            // the next period, within kMaxSteer, so consecutive boundaries stay smooth however jittery USB timestamps are
            double err = modelSampleAt(pubHost_) - pubSample_;
            if (fabs(err) > period * 0.5) { seed_++; break; }  // lost the device: start over and tell the HAL (new seed)
            double steer = std::clamp(kPhaseGain * err / period, -kMaxSteer, kMaxSteer);
            pubTicksPerFrame_ = ticksPerFrame_ * (1.0 - steer);
        }
        if (pubSeed_ == seed_) break;
    }
    *sample = pubSample_;
    *host = (UInt64)pubHost_;
    *seed = seed_;
}

Float64 ClockModel::sampleTimeAt(UInt64 hostNow) const {
    Locker l(&lock_);
    return ticksPerFrame_ > 0 ? anchorSample_ + ((double)hostNow - anchorHost_) / ticksPerFrame_ : 0;
}

Float64 ClockModel::rateHz() const {
    Locker l(&lock_);
    return ticksPerFrame_ > 0 ? hostTicksPerSecond_ / ticksPerFrame_ : 0;
}

UInt64 ClockModel::seed() const {
    Locker l(&lock_);
    return seed_;
}

}  // namespace mbox
