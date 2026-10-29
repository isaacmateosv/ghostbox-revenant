// ObjectModel: the Core Audio objects this driver publishes and their properties.
//   plug-in (kObjPlugIn) owns one device (kObjDevice), which owns an input and an output stream.
// The device object is static: it always exists and hot plug only flips DeviceIsAlive.

#pragma once

#include <CoreAudio/AudioServerPlugIn.h>

namespace mbox::model {

// Size (and data when outData != null) of a property, or kAudioHardwareUnknownPropertyError /
// kAudioHardwareBadObjectError.
OSStatus property(AudioObjectID obj, const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
                  const void* qualifier, UInt32 inDataSize, UInt32* outDataSize, void* outData);

bool isSettable(AudioObjectID obj, const AudioObjectPropertyAddress* address);
bool isStream(AudioObjectID obj);

AudioStreamBasicDescription streamFormat(Float64 rate);

// Tells the HAL that the Mbox appeared or disappeared (no-op before Initialize finished).
void notifyDeviceAliveChanged();

}  // namespace mbox::model
