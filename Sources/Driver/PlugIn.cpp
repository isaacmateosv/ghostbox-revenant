// Mbox 3 Core Audio driver (AudioServerPlugIn): the entry points the HAL calls.
//
// The Mbox 3 uses USB Audio Class 2 descriptors under vendor class codes, so Apple's USB audio driver ignores it.
// This plug-in streams directly over USB (IsochStream) and publishes one device with 4 inputs and 4 outputs.
// The device clock is the IN stream; zero timestamps come from per-microframe USB timestamps (ClockModel).
// Mixer, clock source and front-panel features stay with the GhostBox Revenant GUI app.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>

#include "DriverState.h"
#include "HardwareClock.h"
#include "IsochStream.h"
#include "ObjectModel.h"
#include "UsbHost.h"

using namespace mbox;

namespace {

std::atomic<UInt32> gRefCount{1};

HRESULT QueryInterface(void* self, REFIID iid, LPVOID* out);
ULONG AddRef(void*) { return ++gRefCount; }
ULONG Release(void*) { return gRefCount > 0 ? --gRefCount : 0; }

void restoreLatencyMode(AudioServerPlugInHostRef host) {
    CFPropertyListRef saved = nullptr;
    CFStringRef key = CFStringCreateWithCString(nullptr, kLatencyStorageKey, kCFStringEncodingUTF8);
    if (host->CopyFromStorage(host, key, &saved) == noErr && saved) {
        SInt32 mode = 0;
        if (CFGetTypeID(saved) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)saved, kCFNumberSInt32Type, &mode) &&
            mode >= 0 && mode < MBOX_LATENCY_MODES)
            gState.latencyMode = (UInt32)mode;
        CFRelease(saved);
    }
    CFRelease(key);
}

void storeLatencyMode(SInt32 mode) {
    CFStringRef key = CFStringCreateWithCString(nullptr, kLatencyStorageKey, kCFStringEncodingUTF8);
    CFNumberRef n = CFNumberCreate(nullptr, kCFNumberSInt32Type, &mode);
    gState.host->WriteToStorage(gState.host, key, n);
    CFRelease(n);
    CFRelease(key);
}

OSStatus Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef host) {
    gState.host = host;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    gState.hostTicksPerSecond = 1e9 * tb.denom / tb.numer;
    stream::deviceClock().setHostTicksPerSecond(gState.hostTicksPerSecond);
    usb::start();
    restoreLatencyMode(host);
    gState.hostReady = true;
    os_log(driverLog(), "Mbox 3 driver initialized, device %{public}s, latency mode %u",
           gState.devicePresent ? "present" : "absent", gState.latencyMode.load());
    return noErr;
}

OSStatus CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*) {
    return kAudioHardwareUnsupportedOperationError;
}
OSStatus DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID) { return kAudioHardwareUnsupportedOperationError; }
OSStatus AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*) { return noErr; }
OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*) { return noErr; }

// Runs with IO stopped; the HAL re-reads the device's properties afterwards.
OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID dev, UInt64 action, void*) {
    if (dev != kObjDevice) return kAudioHardwareBadObjectError;
    if (action >= kActionLatencyBase && action < kActionLatencyBase + MBOX_LATENCY_MODES) {
        SInt32 mode = (SInt32)(action - kActionLatencyBase);
        gState.latencyMode = (UInt32)mode;
        storeLatencyMode(mode);
        os_log(driverLog(), "latency mode set to %d", mode);
        return noErr;
    }
    Float64 rate = (Float64)action;
    if (!isSupportedRate(rate)) return kAudioHardwareIllegalOperationError;
    // Switch the hardware first, then publish the new rate. (Never poll the hardware rate and push it back to
    // Core Audio: that raced with apps setting the rate and made Core Audio reconfigure the device endlessly.)
    usb::perform(^{ if (hw::readRate() != rate) hw::writeRate(rate); });
    pthread_mutex_lock(&gState.ioMutex);
    gState.sampleRate = rate;
    pthread_mutex_unlock(&gState.ioMutex);
    os_log(driverLog(), "sample rate set to %.0f", rate);
    return noErr;
}
OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*) { return noErr; }

Boolean HasProperty(AudioServerPlugInDriverRef, AudioObjectID obj, pid_t, const AudioObjectPropertyAddress* a) {
    UInt32 size = 0;
    return model::property(obj, a, 0, nullptr, 0, &size, nullptr) == noErr;
}

OSStatus IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID obj, pid_t, const AudioObjectPropertyAddress* a, Boolean* out) {
    UInt32 size = 0;
    OSStatus err = model::property(obj, a, 0, nullptr, 0, &size, nullptr);
    if (err) return err;
    *out = model::isSettable(obj, a);
    return noErr;
}

OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID obj, pid_t, const AudioObjectPropertyAddress* a,
                             UInt32 qs, const void* q, UInt32* outSize) {
    return model::property(obj, a, qs, q, 0, outSize, nullptr);
}

OSStatus GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID obj, pid_t, const AudioObjectPropertyAddress* a,
                         UInt32 qs, const void* q, UInt32 inSize, UInt32* outSize, void* out) {
    return model::property(obj, a, qs, q, inSize, outSize, out);
}

OSStatus requestRate(Float64 rate) {
    if (rate == gState.sampleRate.load()) return noErr;
    // On S/PDIF clock the source decides the rate (Avid: "Request to set sample rate denied")
    if (gState.clockIsSpdif) return kAudioDeviceUnsupportedFormatError;
    gState.host->RequestDeviceConfigurationChange(gState.host, kObjDevice, (UInt64)rate, nullptr);
    return noErr;
}

OSStatus SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID obj, pid_t, const AudioObjectPropertyAddress* a,
                         UInt32, const void*, UInt32 inSize, const void* data) {
    if (obj == kObjDevice && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        Float64 rate = *(const Float64*)data;
        if (!isSupportedRate(rate)) return kAudioHardwareIllegalOperationError;
        return requestRate(rate);
    }
    if (obj == kObjDevice && a->mSelector == kLatencySelector) {
        if (inSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
        CFPropertyListRef v = *(const CFPropertyListRef*)data;
        SInt32 mode = -1;
        if (!v || CFGetTypeID(v) != CFNumberGetTypeID() || !CFNumberGetValue((CFNumberRef)v, kCFNumberSInt32Type, &mode) ||
            mode < 0 || mode >= MBOX_LATENCY_MODES)
            return kAudioHardwareIllegalOperationError;
        // Applied in PerformDeviceConfigurationChange, with IO stopped, so the HAL picks up the new safety offsets
        if ((UInt32)mode != gState.latencyMode.load())
            gState.host->RequestDeviceConfigurationChange(gState.host, kObjDevice, kActionLatencyBase + mode, nullptr);
        return noErr;
    }
    if (model::isStream(obj) && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription* f = (const AudioStreamBasicDescription*)data;
        AudioStreamBasicDescription ours = model::streamFormat(f->mSampleRate);
        if (f->mFormatID != ours.mFormatID || f->mChannelsPerFrame != kChannels || f->mBitsPerChannel != 32)
            return kAudioDeviceUnsupportedFormatError;
        return requestRate(f->mSampleRate);
    }
    return kAudioHardwareUnsupportedOperationError;
}

OSStatus StartIO(AudioServerPlugInDriverRef, AudioObjectID dev, UInt32) {
    if (dev != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gState.ioMutex);
    OSStatus err = noErr;
    if (gState.ioClients == 0) {
        __block bool ok = false;
        usb::perform(^{ ok = stream::start(); });
        if (!ok) err = kAudioHardwareNotRunningError;
    }
    if (!err) gState.ioClients++;
    pthread_mutex_unlock(&gState.ioMutex);
    return err;
}

OSStatus StopIO(AudioServerPlugInDriverRef, AudioObjectID dev, UInt32) {
    if (dev != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gState.ioMutex);
    if (gState.ioClients > 0 && --gState.ioClients == 0) usb::perform(^{ stream::stop(); });
    pthread_mutex_unlock(&gState.ioMutex);
    return noErr;
}

OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64* outSample, UInt64* outHost, UInt64* outSeed) {
    stream::deviceClock().zeroTimeStamp(mach_absolute_time(), kZeroTSPeriod, outSample, outHost, outSeed);
    return noErr;
}

OSStatus WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32 op, Boolean* will, Boolean* inPlace) {
    *will = (op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix);
    *inPlace = true;
    return noErr;
}
OSStatus BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*) { return noErr; }
OSStatus EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*) { return noErr; }

OSStatus DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32 op, UInt32 frames,
                       const AudioServerPlugInIOCycleInfo* cycle, void* main, void*) {
    float* buf = (float*)main;
    if (op == kAudioServerPlugInIOOperationReadInput)
        stream::readInput((SInt64)llround(cycle->mInputTime.mSampleTime), frames, buf);
    else if (op == kAudioServerPlugInIOOperationWriteMix)
        stream::writeOutput((SInt64)llround(cycle->mOutputTime.mSampleTime), frames, buf);
    return noErr;
}

AudioServerPlugInDriverInterface gInterface = {
    nullptr, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
    PerformDeviceConfigurationChange, AbortDeviceConfigurationChange, HasProperty, IsPropertySettable, GetPropertyDataSize,
    GetPropertyData, SetPropertyData, StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BeginIOOperation, DoIOOperation,
    EndIOOperation};
AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

HRESULT QueryInterface(void*, REFIID iid, LPVOID* out) {
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(nullptr, iid);
    bool ok = CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(req);
    if (!ok) { *out = nullptr; return E_NOINTERFACE; }
    ++gRefCount;
    *out = gDriverRef;
    return S_OK;
}

}  // namespace

// Factory named in Info.plist (CFPlugInFactories)
extern "C" __attribute__((visibility("default"))) void* Mbox3_Create(CFAllocatorRef, CFUUIDRef type) {
    return CFEqual(type, kAudioServerPlugInTypeUUID) ? gDriverRef : nullptr;
}
