// HardwareClock: the Mbox's sample clock (rate, source, S/PDIF lock). USB thread only.
//
// Core Audio owns the sample rate while this driver is loaded. The driver programs the hardware to match it and
// never pushes hardware changes back to Core Audio (that raced with apps and looped forever), with one exception:
// on the S/PDIF clock the external source sets the rate, and the driver asks Core Audio to follow it.

#pragma once

#include <CoreAudio/CoreAudioTypes.h>

namespace mbox::hw {

Float64 readRate();               // rate of the selected clock, 0 when unknown
void writeRate(Float64 rate);     // internal clock
UInt8 clockSelector();            // MBOX_CLOCK_INTERNAL / MBOX_CLOCK_SPDIF, 0 when unknown
bool spdifClockValid();

// Called on attach (adoptRate = true only before the HAL has seen the device) and whenever the streamed rate
// drifts from the nominal rate. Leaves an invalid S/PDIF clock for the internal one.
void enforce(bool adoptRate);

// Once a second: notice the S/PDIF clock and ask Core Audio to follow the source's rate.
void startFollowingSpdif();

}  // namespace mbox::hw
