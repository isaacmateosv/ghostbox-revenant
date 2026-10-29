#include "ObjectModel.h"

#include <algorithm>
#include <cstring>

#include "DriverState.h"

namespace mbox::model {
namespace {

bool isDevice(AudioObjectID id) { return id == kObjDevice; }

// kAudioObjectPropertyOwnedObjects may carry a qualifier: a list of AudioClassIDs to filter by
bool classRequested(AudioClassID cls, UInt32 qualSize, const void* qual) {
    if (!qual || qualSize < sizeof(AudioClassID)) return true;
    const AudioClassID* q = (const AudioClassID*)qual;
    for (UInt32 i = 0; i < qualSize / sizeof(AudioClassID); i++)
        if (q[i] == cls || q[i] == kAudioObjectClassID) return true;
    return false;
}

// Writes a fixed-size value, or only its size when out is null (HasProperty / GetPropertyDataSize).
template <typename T>
OSStatus value(T v, UInt32 inDataSize, UInt32* outDataSize, void* out) {
    *outDataSize = sizeof(T);
    if (!out) return noErr;
    if (inDataSize < sizeof(T)) return kAudioHardwareBadPropertySizeError;
    *(T*)out = v;
    return noErr;
}

// Array of `count` items produced by `item(i)`, truncated to the caller's buffer.
template <typename T, typename F>
OSStatus array(UInt32 count, UInt32 inDataSize, UInt32* outDataSize, void* out, F item) {
    *outDataSize = count * sizeof(T);
    if (!out) return noErr;
    count = std::min(count, inDataSize / (UInt32)sizeof(T));
    for (UInt32 i = 0; i < count; i++) ((T*)out)[i] = item(i);
    *outDataSize = count * sizeof(T);
    return noErr;
}

// CFString properties: the caller releases what it gets (CFSTR constants ignore the release).
OSStatus string(CFStringRef s, UInt32 inDataSize, UInt32* outDataSize, void* out) { return value(s, inDataSize, outDataSize, out); }

OSStatus plugInProperty(const AudioObjectPropertyAddress* a, UInt32 qs, const void* q, UInt32 in, UInt32* outSize, void* out) {
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: return value<AudioClassID>(kAudioObjectClassID, in, outSize, out);
        case kAudioObjectPropertyClass: return value<AudioClassID>(kAudioPlugInClassID, in, outSize, out);
        case kAudioObjectPropertyOwner: return value<AudioObjectID>(kAudioObjectUnknown, in, outSize, out);
        case kAudioObjectPropertyManufacturer: return string(CFSTR("GhostBox Revenant"), in, outSize, out);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            bool wanted = a->mSelector == kAudioPlugInPropertyDeviceList || classRequested(kAudioDeviceClassID, qs, q);
            return array<AudioObjectID>(wanted ? 1 : 0, in, outSize, out, [](UInt32) { return (AudioObjectID)kObjDevice; });
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID dev = kAudioObjectUnknown;
            if (q && qs == sizeof(CFStringRef) &&
                CFStringCompare(*(CFStringRef*)q, CFSTR(MBOX_DEVICE_UID), 0) == kCFCompareEqualTo) dev = kObjDevice;
            return value<AudioObjectID>(dev, in, outSize, out);
        }
        case kAudioPlugInPropertyResourceBundle: return string(CFSTR(""), in, outSize, out);
    }
    return kAudioHardwareUnknownPropertyError;
}

OSStatus deviceProperty(const AudioObjectPropertyAddress* a, UInt32 qs, const void* q, UInt32 in, UInt32* outSize, void* out) {
    const Float64 rate = gState.sampleRate.load();
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: return value<AudioClassID>(kAudioObjectClassID, in, outSize, out);
        case kAudioObjectPropertyClass: return value<AudioClassID>(kAudioDeviceClassID, in, outSize, out);
        case kAudioObjectPropertyOwner: return value<AudioObjectID>(kObjPlugIn, in, outSize, out);
        case kAudioObjectPropertyName: return string(CFSTR("Mbox 3"), in, outSize, out);
        case kAudioObjectPropertyManufacturer: return string(CFSTR("Avid"), in, outSize, out);
        case kAudioDevicePropertyDeviceUID: return string(CFSTR(MBOX_DEVICE_UID), in, outSize, out);
        case kAudioDevicePropertyModelUID: return string(CFSTR(MBOX_MODEL_UID), in, outSize, out);
        case kAudioDevicePropertyConfigurationApplication: return string(CFSTR(MBOX_CONTROL_APP_ID), in, outSize, out);
        case kAudioDevicePropertyTransportType: return value<UInt32>(kAudioDeviceTransportTypeUSB, in, outSize, out);
        case kAudioDevicePropertyClockDomain: return value<UInt32>(0, in, outSize, out);
        case kAudioDevicePropertyDeviceIsAlive: return value<UInt32>(gState.devicePresent ? 1 : 0, in, outSize, out);
        case kAudioDevicePropertyDeviceIsRunning: return value<UInt32>(gState.ioClients > 0 ? 1 : 0, in, outSize, out);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: return value<UInt32>(1, in, outSize, out);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: return value<UInt32>(1, in, outSize, out);
        case kAudioDevicePropertyIsHidden: return value<UInt32>(0, in, outSize, out);
        case kAudioDevicePropertyLatency: return value<UInt32>((UInt32)(rate / 1000.0), in, outSize, out);
        case kAudioDevicePropertySafetyOffset:
            return value<UInt32>(a->mScope == kAudioObjectPropertyScopeInput ? inputSafetyOffset() : outputSafetyOffset(), in, outSize, out);
        case kAudioDevicePropertyNominalSampleRate: return value<Float64>(rate, in, outSize, out);
        case kAudioDevicePropertyZeroTimeStampPeriod: return value<UInt32>(kZeroTSPeriod, in, outSize, out);
        case kAudioDevicePropertyRelatedDevices: return value<AudioObjectID>(kObjDevice, in, outSize, out);
        case kAudioDevicePropertyPreferredChannelsForStereo:
            return array<UInt32>(2, in, outSize, out, [](UInt32 i) { return i + 1; });
        case kAudioDevicePropertyAvailableNominalSampleRates:
            return array<AudioValueRange>(kRateCount, in, outSize, out, [](UInt32 i) { return AudioValueRange{kRates[i], kRates[i]}; });
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            AudioObjectID ids[2];
            UInt32 n = 0;
            bool wanted = a->mSelector == kAudioDevicePropertyStreams || classRequested(kAudioStreamClassID, qs, q);
            if (wanted && a->mScope != kAudioObjectPropertyScopeOutput) ids[n++] = kObjStreamIn;
            if (wanted && a->mScope != kAudioObjectPropertyScopeInput) ids[n++] = kObjStreamOut;
            return array<AudioObjectID>(n, in, outSize, out, [&](UInt32 i) { return ids[i]; });
        }
        case kAudioObjectPropertyControlList: *outSize = 0; return noErr;
        case kAudioObjectPropertyCustomPropertyInfoList: {
            AudioServerPlugInCustomPropertyInfo info = {kLatencySelector, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                                                        kAudioServerPlugInCustomPropertyDataTypeNone};
            return value(info, in, outSize, out);
        }
        case kLatencySelector: {
            // Changes only when the user picks another mode (a value that changed on every read once made
            // Core Audio's property cache re-notify every client in a loop). The caller releases the number.
            *outSize = sizeof(CFPropertyListRef);
            if (!out) return noErr;
            if (in < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
            SInt32 mode = (SInt32)gState.latencyMode.load();
            *(CFPropertyListRef*)out = CFNumberCreate(nullptr, kCFNumberSInt32Type, &mode);
            return noErr;
        }
        case kAudioObjectPropertyElementName: {
            UInt32 ch = a->mElement;
            if (ch < 1 || ch > kChannels) return kAudioHardwareUnknownPropertyError;
            *outSize = sizeof(CFStringRef);
            if (!out) return noErr;
            if (in < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            const char* name = a->mScope == kAudioObjectPropertyScopeInput ? kInNames[ch - 1] : kOutNames[ch - 1];
            *(CFStringRef*)out = CFStringCreateWithCString(nullptr, name, kCFStringEncodingUTF8);
            return noErr;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

OSStatus streamProperty(bool input, const AudioObjectPropertyAddress* a, UInt32 in, UInt32* outSize, void* out) {
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: return value<AudioClassID>(kAudioObjectClassID, in, outSize, out);
        case kAudioObjectPropertyClass: return value<AudioClassID>(kAudioStreamClassID, in, outSize, out);
        case kAudioObjectPropertyOwner: return value<AudioObjectID>(kObjDevice, in, outSize, out);
        case kAudioObjectPropertyOwnedObjects: *outSize = 0; return noErr;
        case kAudioObjectPropertyName: return string(input ? CFSTR("Mbox 3 Inputs") : CFSTR("Mbox 3 Returns"), in, outSize, out);
        case kAudioStreamPropertyIsActive: return value<UInt32>(1, in, outSize, out);
        case kAudioStreamPropertyDirection: return value<UInt32>(input ? 1 : 0, in, outSize, out);
        case kAudioStreamPropertyTerminalType:
            return value<UInt32>(input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker, in, outSize, out);
        case kAudioStreamPropertyStartingChannel: return value<UInt32>(1, in, outSize, out);
        case kAudioStreamPropertyLatency: return value<UInt32>(0, in, outSize, out);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: return value(streamFormat(gState.sampleRate.load()), in, outSize, out);
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return array<AudioStreamRangedDescription>(kRateCount, in, outSize, out, [](UInt32 i) {
                AudioStreamRangedDescription d;
                d.mFormat = streamFormat(kRates[i]);
                d.mSampleRateRange = {kRates[i], kRates[i]};
                return d;
            });
    }
    return kAudioHardwareUnknownPropertyError;
}

}  // namespace

bool isStream(AudioObjectID id) { return id == kObjStreamIn || id == kObjStreamOut; }

AudioStreamBasicDescription streamFormat(Float64 rate) {
    AudioStreamBasicDescription f = {};
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = f.mBytesPerFrame = kChannels * sizeof(Float32);
    f.mFramesPerPacket = 1;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

OSStatus property(AudioObjectID obj, const AudioObjectPropertyAddress* a, UInt32 qs, const void* q,
                  UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (obj == kObjPlugIn) return plugInProperty(a, qs, q, inDataSize, outDataSize, outData);
    if (isDevice(obj)) return deviceProperty(a, qs, q, inDataSize, outDataSize, outData);
    if (isStream(obj)) return streamProperty(obj == kObjStreamIn, a, inDataSize, outDataSize, outData);
    return kAudioHardwareBadObjectError;
}

bool isSettable(AudioObjectID obj, const AudioObjectPropertyAddress* a) {
    if (isDevice(obj)) return a->mSelector == kAudioDevicePropertyNominalSampleRate || a->mSelector == kLatencySelector;
    if (isStream(obj)) return a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat;
    return false;
}

void notifyDeviceAliveChanged() {
    if (!gState.host || !gState.hostReady) return;
    AudioObjectPropertyAddress a = {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    gState.host->PropertiesChanged(gState.host, kObjDevice, 1, &a);
}

}  // namespace mbox::model
