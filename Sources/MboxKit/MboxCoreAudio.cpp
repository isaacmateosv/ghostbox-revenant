// MboxKit Core Audio side: talks to the Mbox 3 driver through the HAL (never call these from inside the driver).

#include "MboxKit.h"

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cstdio>
#include <cstring>
#include <unistd.h>

static AudioObjectID coreAudioDevice(void) {
    CFStringRef uid = CFSTR(MBOX_DEVICE_UID);
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &size, &dev) != noErr)
        return kAudioObjectUnknown;
    return dev;
}

static AudioObjectPropertyAddress globalAddress(AudioObjectPropertySelector selector) {
    return {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}

// The installed driver bundle: the current name, or the one used before the project was renamed.
static const char* installedDriverPath(void) {
    if (access(MBOX_DRIVER_PATH, F_OK) == 0) return MBOX_DRIVER_PATH;
    if (access(MBOX_LEGACY_DRIVER_PATH, F_OK) == 0) return MBOX_LEGACY_DRIVER_PATH;
    return nullptr;
}

bool mbox_coreaudio_present(void) {
    return installedDriverPath() && coreAudioDevice() != kAudioObjectUnknown;
}

int mbox_coreaudio_set_rate(double rate) {
    AudioObjectID dev = coreAudioDevice();
    if (dev == kAudioObjectUnknown) return MBOX_ERR_NOT_FOUND;
    AudioObjectPropertyAddress a = globalAddress(kAudioDevicePropertyNominalSampleRate);
    return AudioObjectSetPropertyData(dev, &a, 0, nullptr, sizeof(rate), &rate) == noErr ? MBOX_OK : MBOX_ERR_IO;
}

int mbox_coreaudio_get_rate(double* rate) {
    AudioObjectID dev = coreAudioDevice();
    if (dev == kAudioObjectUnknown) return MBOX_ERR_NOT_FOUND;
    AudioObjectPropertyAddress a = globalAddress(kAudioDevicePropertyNominalSampleRate);
    Float64 r = 0;
    UInt32 size = sizeof(r);
    if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, &r) != noErr) return MBOX_ERR_IO;
    if (rate) *rate = r;
    return MBOX_OK;
}

// The latency mode is a CFNumber custom property. Its value changes only when someone sets it, which keeps Core
// Audio's property cache quiet (a self-changing custom property once pinned coreaudiod at 100% CPU).
int mbox_coreaudio_get_latency_mode(int* mode) {
    AudioObjectID dev = coreAudioDevice();
    if (dev == kAudioObjectUnknown) return MBOX_ERR_NOT_FOUND;
    AudioObjectPropertyAddress a = globalAddress(MBOX_LATENCY_SELECTOR);
    if (!AudioObjectHasProperty(dev, &a)) return MBOX_ERR_UNSUPPORTED;
    CFPropertyListRef value = nullptr;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, &value) != noErr || !value) return MBOX_ERR_IO;
    SInt32 m = -1;
    bool ok = CFGetTypeID(value) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, &m);
    CFRelease(value);
    if (!ok || m < 0 || m >= MBOX_LATENCY_MODES) return MBOX_ERR_IO;
    if (mode) *mode = m;
    return MBOX_OK;
}

int mbox_coreaudio_set_latency_mode(int mode) {
    if (mode < 0 || mode >= MBOX_LATENCY_MODES) return MBOX_ERR_ARG;
    AudioObjectID dev = coreAudioDevice();
    if (dev == kAudioObjectUnknown) return MBOX_ERR_NOT_FOUND;
    AudioObjectPropertyAddress a = globalAddress(MBOX_LATENCY_SELECTOR);
    if (!AudioObjectHasProperty(dev, &a)) return MBOX_ERR_UNSUPPORTED;
    SInt32 m = mode;
    CFNumberRef number = CFNumberCreate(nullptr, kCFNumberSInt32Type, &m);
    OSStatus err = AudioObjectSetPropertyData(dev, &a, 0, nullptr, sizeof(CFNumberRef), &number);
    CFRelease(number);
    return err == noErr ? MBOX_OK : MBOX_ERR_IO;
}

int mbox_driver_version(char* out, size_t size) {
    if (!out || !size) return MBOX_ERR_ARG;
    out[0] = 0;
    // Read Info.plist directly: CFBundle caches bundles per process and would miss a driver updated meanwhile
    const char* base = installedDriverPath();
    if (!base) return MBOX_ERR_NOT_FOUND;
    char plistPath[512];
    snprintf(plistPath, sizeof(plistPath), "%s/Contents/Info.plist", base);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, (const UInt8*)plistPath, (CFIndex)strlen(plistPath), false);
    CFReadStreamRef stream = url ? CFReadStreamCreateWithFile(nullptr, url) : nullptr;
    if (url) CFRelease(url);
    if (!stream) return MBOX_ERR_NOT_FOUND;
    int result = MBOX_ERR_NOT_FOUND;
    if (CFReadStreamOpen(stream)) {
        CFPropertyListRef plist = CFPropertyListCreateWithStream(nullptr, stream, 0, kCFPropertyListImmutable, nullptr, nullptr);
        if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
            CFTypeRef v = CFDictionaryGetValue((CFDictionaryRef)plist, CFSTR("CFBundleShortVersionString"));
            if (v && CFGetTypeID(v) == CFStringGetTypeID() && CFStringGetCString((CFStringRef)v, out, (CFIndex)size, kCFStringEncodingUTF8))
                result = MBOX_OK;
        }
        if (plist) CFRelease(plist);
        CFReadStreamClose(stream);
    }
    CFRelease(stream);
    return result;
}
