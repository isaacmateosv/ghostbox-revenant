// Loads build/GhostBoxRevenant.driver in-process and drives it like coreaudiod would:
// queries properties, starts IO, follows the zero timestamps, reads input, writes a -30 dBFS tone.
// Usage: driver_test [seconds]   (env BUFFER: frames per IO cycle, default 512)
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <cmath>
#include <cstdio>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <pthread.h>

static void setRealtime() {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double msTicks = 1e6 * tb.denom / tb.numer;
    thread_time_constraint_policy_data_t pol = {(uint32_t)msTicks, (uint32_t)(msTicks * 0.3), (uint32_t)(msTicks * 0.6), 1};
    thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&pol, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}
#include <vector>

static OSStatus PropertiesChanged(AudioServerPlugInHostRef, AudioObjectID obj, UInt32 n, const AudioObjectPropertyAddress* a) {
    printf("  host: PropertiesChanged obj %u (%u props)\n", obj, n);
    return noErr;
}
static OSStatus CopyFromStorage(AudioServerPlugInHostRef, CFStringRef, CFPropertyListRef* out) { *out = nullptr; return noErr; }
static OSStatus WriteToStorage(AudioServerPlugInHostRef, CFStringRef, CFPropertyListRef) { return noErr; }
static OSStatus DeleteFromStorage(AudioServerPlugInHostRef, CFStringRef) { return noErr; }
static UInt64 gPendingAction = 0;
static bool gHasPending = false;
static OSStatus RequestConfigChange(AudioServerPlugInHostRef, AudioObjectID, UInt64 action, void*) {
    gPendingAction = action; gHasPending = true; return noErr;
}
static AudioServerPlugInHostInterface gHost = {PropertiesChanged, CopyFromStorage, WriteToStorage, DeleteFromStorage, RequestConfigChange};

int main(int argc, char** argv) {
    double seconds = argc > 1 ? atof(argv[1]) : 3;
    CFURLRef url = CFURLCreateWithFileSystemPath(nullptr, CFSTR("build/GhostBoxRevenant.driver"), kCFURLPOSIXPathStyle, true);
    CFBundleRef b = CFBundleCreate(nullptr, url);
    if (!b || !CFBundleLoadExecutable(b)) { puts("cannot load bundle"); return 1; }
    auto create = (void* (*)(CFAllocatorRef, CFUUIDRef))CFBundleGetFunctionPointerForName(b, CFSTR("Mbox3_Create"));
    AudioServerPlugInDriverRef d = (AudioServerPlugInDriverRef)create(nullptr, kAudioServerPlugInTypeUUID);
    (*d)->Initialize(d, &gHost);

    auto get = [&](AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, void* out, UInt32 size, UInt32 elem = 0) {
        AudioObjectPropertyAddress a = {sel, scope, elem};
        UInt32 got = 0;
        OSStatus e = (*d)->GetPropertyData(d, obj, 0, &a, 0, nullptr, size, &got, out);
        return e;
    };
    AudioObjectID devs[4]; UInt32 n = 0;
    { AudioObjectPropertyAddress a = {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, 0};
      (*d)->GetPropertyData(d, kAudioObjectPlugInObject, 0, &a, 0, nullptr, sizeof(devs), &n, devs); }
    printf("devices: %u\n", n / 4);
    if (!n) return 1;
    AudioObjectID dev = devs[0];
    CFStringRef name = nullptr, uid = nullptr; Float64 rate = 0; UInt32 inSafety = 0, outSafety = 0, period = 0;
    get(dev, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &name, sizeof(name));
    get(dev, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, &uid, sizeof(uid));
    get(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate, sizeof(rate));
    get(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput, &inSafety, 4);
    get(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, &outSafety, 4);
    get(dev, kAudioDevicePropertyZeroTimeStampPeriod, kAudioObjectPropertyScopeGlobal, &period, 4);
    char nb[64], ub[64];
    CFStringGetCString(name, nb, 64, kCFStringEncodingUTF8); CFStringGetCString(uid, ub, 64, kCFStringEncodingUTF8);
    printf("device '%s' uid %s rate %.0f safety in %u out %u period %u\n", nb, ub, rate, inSafety, outSafety, period);
    for (UInt32 ch = 1; ch <= 4; ch++) {
        CFStringRef cn = nullptr; char c[64] = "";
        get(dev, kAudioObjectPropertyElementName, kAudioObjectPropertyScopeInput, &cn, sizeof(cn), ch);
        if (cn) { CFStringGetCString(cn, c, 64, kCFStringEncodingUTF8); CFRelease(cn); }
        printf("  in %u: %s\n", ch, c);
    }

    if (getenv("LATENCYTEST")) {
        // Like the HAL: set the custom property, then stop IO, perform the requested change, re-read offsets
        const char* names[3] = {"safe", "balanced", "low"};
        for (SInt32 mode : {1, 2, 0}) {
            AudioObjectPropertyAddress la = {'mbxl', kAudioObjectPropertyScopeGlobal, 0};
            CFNumberRef n = CFNumberCreate(nullptr, kCFNumberSInt32Type, &mode);
            OSStatus e = (*d)->SetPropertyData(d, dev, 0, &la, 0, nullptr, sizeof(CFNumberRef), &n);
            CFRelease(n);
            if (gHasPending) { (*d)->PerformDeviceConfigurationChange(d, dev, gPendingAction, nullptr); gHasPending = false; }
            UInt32 si = 0, so = 0; CFPropertyListRef cur = nullptr; SInt32 back = -1;
            get(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput, &si, 4);
            get(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, &so, 4);
            get(dev, 'mbxl', kAudioObjectPropertyScopeGlobal, &cur, sizeof(cur));
            if (cur) { CFNumberGetValue((CFNumberRef)cur, kCFNumberSInt32Type, &back); CFRelease(cur); }
            printf("mode %-8s set=%d readback=%d  safety in %u (%.1f ms) out %u (%.1f ms)\n", names[mode], (int)e, (int)back,
                   si, si * 1000.0 / rate, so, so * 1000.0 / rate);
        }
        if (getenv("LATENCYMODE")) {  // leave the driver in this mode for the streaming test below
            SInt32 mode = atoi(getenv("LATENCYMODE"));
            AudioObjectPropertyAddress la = {'mbxl', kAudioObjectPropertyScopeGlobal, 0};
            CFNumberRef n = CFNumberCreate(nullptr, kCFNumberSInt32Type, &mode);
            (*d)->SetPropertyData(d, dev, 0, &la, 0, nullptr, sizeof(CFNumberRef), &n);
            CFRelease(n);
            if (gHasPending) { (*d)->PerformDeviceConfigurationChange(d, dev, gPendingAction, nullptr); gHasPending = false; }
            get(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput, &inSafety, 4);
            get(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, &outSafety, 4);
            printf("streaming test in mode %s: safety in %u out %u\n", names[mode], inSafety, outSafety);
        } else {
            return 0;
        }
    }
    if ((*d)->StartIO(d, dev, 1)) { puts("StartIO failed"); return 1; }
    setRealtime();
    int overloads = 0;
    if (getenv("CLOCKPROBE")) {
        auto probe = (void (*)(double*))CFBundleGetFunctionPointerForName(b, CFSTR("Mbox3_ClockProbe"));
        for (int i = 0; i < 30; i++) { double v[4]; probe(v);
            printf("t=%.1fs now-captured %+.0f, outPos-now %+.0f frames\n", i * 0.1, v[0] - v[1], v[3] - v[0]);
            usleep(100000); }
        (*d)->StopIO(d, dev, 1); return 0;
    }
    const UInt32 buf = getenv("BUFFER") ? (UInt32)atoi(getenv("BUFFER")) : 512;
    printf("IO buffer %u frames\n", buf);
    std::vector<float> io(buf * 4);
    double peak[4] = {0}, phase = 0, lastTSHost = 0, lastTSSample = -1;
    int cycles = 0, tsJumps = 0;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double ticksPerSec = 1e9 * tb.denom / tb.numer;
    UInt64 end = mach_absolute_time() + (UInt64)(seconds * ticksPerSec);
    double nextCycle = -1;
    UInt64 lastSeed = 0;
    while (mach_absolute_time() < end) {
        Float64 zs; UInt64 zh, seed;
        (*d)->GetZeroTimeStamp(d, dev, 1, &zs, &zh, &seed);
        if (seed != lastSeed) { lastSeed = seed; nextCycle = -1; lastTSSample = -1; }  // timeline changed: resync like the HAL
        if (lastTSSample >= 0 && zs != lastTSSample) {
            double rateSeen = (zs - lastTSSample) / (((double)zh - lastTSHost) / ticksPerSec);
            if (fabs(rateSeen / rate - 1) > 0.01) tsJumps++;
        }
        if (zs != lastTSSample) { lastTSSample = zs; lastTSHost = (double)zh; }
        double now = zs + ((double)mach_absolute_time() - (double)zh) / ticksPerSec * rate;
        if (nextCycle < 0) nextCycle = now;
        if (now - nextCycle > buf) { overloads++; nextCycle = now; }  // fell a whole buffer behind: skip ahead like the HAL
        if (now >= nextCycle) {
            AudioServerPlugInIOCycleInfo cyc = {};
            cyc.mInputTime.mSampleTime = nextCycle - inSafety - buf;
            cyc.mOutputTime.mSampleTime = nextCycle + buf + outSafety;  // HAL convention: one buffer ahead + safety
            if (cyc.mInputTime.mSampleTime >= 0) {
                (*d)->DoIOOperation(d, dev, 3, 1, kAudioServerPlugInIOOperationReadInput, buf, &cyc, io.data(), nullptr);
                for (UInt32 i = 0; i < buf; i++) for (int c = 0; c < 4; c++) peak[c] = fmax(peak[c], fabs(io[i * 4 + c]));
            }
            for (UInt32 i = 0; i < buf; i++) {
                float s = (float)(sin(phase) * 0.0316); phase += 2 * M_PI * 440 / rate;
                for (int c = 0; c < 4; c++) io[i * 4 + c] = s;
            }
            (*d)->DoIOOperation(d, dev, 4, 1, kAudioServerPlugInIOOperationWriteMix, buf, &cyc, io.data(), nullptr);
            nextCycle += buf; cycles++;
        }
        usleep(250);
    }
    auto dbg = (void (*)(UInt32*, UInt64*))CFBundleGetFunctionPointerForName(b, CFSTR("Mbox3_DebugCounters"));
    if (dbg) { UInt32 c[6]; UInt64 nz; dbg(c, &nz);
        printf("xfers in %u out %u, out errors %u, submit errors %u, last status 0x%x, outPos %u, nonzero out samples %llu\n",
               c[0], c[1], c[2], c[3], c[4], c[5], nz); }
    auto hist = (const int* (*)())CFBundleGetFunctionPointerForName(b, CFSTR("Mbox3_LeadHist"));
    if (hist) { const int* h = hist(); printf("OUT lead (frames ahead of bus) ok:");
        for (int i = 0; i < 8; i++) printf(" %d:%d", i, h[i]); printf("  failed:");
        for (int i = 0; i < 8; i++) printf(" %d:%d", i, h[8 + i]); puts(""); }
    auto stats = (void (*)(SInt64*))CFBundleGetFunctionPointerForName(b, CFSTR("Mbox3_Stats"));
    if (stats) { SInt64 v[10]; stats(v);
        printf("stats: in late %lld/%lld, out late %lld/%lld, resyncs out %lld in %lld, submit err %lld, xfer err %lld, min out lead %lld us, max delay %lld us\n",
               v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9]); }
    (*d)->StopIO(d, dev, 1);
    printf("IO cycles %d (expected ~%.0f), harness overloads %d, zero-timestamp rate anomalies %d\n", cycles, seconds * rate / buf, overloads, tsJumps);
    for (int c = 0; c < 4; c++) printf("  input ch %d peak %.4f (%.1f dBFS)\n", c + 1, peak[c], peak[c] > 0 ? 20 * log10(peak[c]) : -999.0);
    return 0;
}
