// carange: for each latency mode and sample rate, set them on the Mbox through Core Audio and read back what the HAL
// derives: buffer frame size range, safety offsets, zero time stamp period. Restores the original rate and mode.
#include <CoreAudio/CoreAudio.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <unistd.h>
#include <cstdio>
#include <initializer_list>
template <typename T> static OSStatus getp(AudioObjectID o, AudioObjectPropertySelector s, T& v, AudioObjectPropertyScope sc = kAudioObjectPropertyScopeGlobal) {
    AudioObjectPropertyAddress a = {s, sc, 0}; UInt32 sz = sizeof(T); return AudioObjectGetPropertyData(o, &a, 0, nullptr, &sz, &v);
}
static SInt32 mode(AudioObjectID d) {
    CFPropertyListRef v = nullptr; SInt32 m = -1;
    if (getp(d, 'mbxl', v) == noErr && v) { CFNumberGetValue((CFNumberRef)v, kCFNumberSInt32Type, &m); CFRelease(v); }
    return m;
}
static bool setMode(AudioObjectID d, SInt32 m) {
    CFNumberRef n = CFNumberCreate(nullptr, kCFNumberSInt32Type, &m);
    AudioObjectPropertyAddress a = {'mbxl', kAudioObjectPropertyScopeGlobal, 0};
    AudioObjectSetPropertyData(d, &a, 0, nullptr, sizeof n, &n); CFRelease(n);
    for (int i = 0; i < 40; i++) { if (mode(d) == m) return true; usleep(100000); }
    return false;
}
static bool setRate(AudioObjectID d, Float64 r) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0};
    AudioObjectSetPropertyData(d, &a, 0, nullptr, sizeof r, &r);
    for (int i = 0; i < 40; i++) { Float64 x = 0; getp(d, kAudioDevicePropertyNominalSampleRate, x); if (x == r) return true; usleep(100000); }
    return false;
}
int main() {
    AudioObjectID d = 0; CFStringRef uid = CFSTR("Mbox3:0dba:5000");
    AudioValueTranslation t = {&uid, sizeof uid, &d, sizeof d};
    AudioObjectPropertyAddress ta = {kAudioHardwarePropertyDeviceForUID, kAudioObjectPropertyScopeGlobal, 0};
    UInt32 tsz = sizeof t; AudioObjectGetPropertyData(kAudioObjectSystemObject, &ta, 0, nullptr, &tsz, &t);
    if (!d) { puts("no Mbox"); return 1; }
    Float64 rate0 = 0; getp(d, kAudioDevicePropertyNominalSampleRate, rate0);
    SInt32 mode0 = mode(d);
    printf("original: rate %.0f mode %d\n", rate0, (int)mode0);
    const char* names[] = {"safe", "balanced", "low"};
    for (SInt32 m : {0, 1, 2}) {
        bool okm = setMode(d, m);
        for (Float64 r : {44100.0, 48000.0, 88200.0, 96000.0}) {
            bool okr = setRate(d, r);
            usleep(300000);
            AudioValueRange br = {}; UInt32 sIn = 0, sOut = 0, per = 0, buf = 0;
            getp(d, kAudioDevicePropertyBufferFrameSizeRange, br);
            getp(d, kAudioDevicePropertySafetyOffset, sIn, kAudioObjectPropertyScopeInput);
            getp(d, kAudioDevicePropertySafetyOffset, sOut, kAudioObjectPropertyScopeOutput);
            getp(d, kAudioDevicePropertyZeroTimeStampPeriod, per);
            getp(d, kAudioDevicePropertyBufferFrameSize, buf);
            printf("mode %-8s%s rate %6.0f%s: buffer range %4.0f..%4.0f (%.1f ms max) safety in %4u out %4u period %u current buffer %u\n",
                   names[m], okm ? "" : "(!)", r, okr ? "" : "(!)", br.mMinimum, br.mMaximum, br.mMaximum / r * 1000, sIn, sOut, per, buf);
        }
    }
    bool a = setRate(d, rate0), b = setMode(d, mode0);
    printf("restored: rate %.0f %s, mode %d %s\n", rate0, a ? "ok" : "FAILED", (int)mode0, b ? "ok" : "FAILED");
    return 0;
}
