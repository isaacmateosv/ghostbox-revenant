// gbharness: loads a GhostBoxRevenant.driver build in-process and drives it the way coreaudiod's IO thread does,
// then reports the driver's own glitch counters once a second. Test tool for the hackintosh run (not part of the
// project's regular tests). The installed driver must not be streaming (exclusive access to interfaces 2 and 3).
//
//   gbharness <path/to/GhostBoxRevenant.driver> [--seconds S] [--rate R] [--mode 0|1|2] [--buffer N]
//             [--compute PCT] [--tone-db DB] [--tone-ch MASK] [--csv FILE] [--restore-rate R] [--label TEXT]
//
// IO cycle (HAL convention, IOCycleUsage 1): the thread wakes at sample time T = n * buffer on the driver's zero
// timestamp timeline, reads input at T - buffer - inSafety, spends `compute`% of the buffer period "rendering",
// then writes output at T + buffer + outSafety.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <pthread.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static double gTicksPerSec;
static double secs(UInt64 ticks) { return ticks / gTicksPerSec; }

// ---- options
static double optSeconds = 10, optRate = 0, optCompute = 10, optToneDb = -40, optRestoreRate = 0;
static int optMode = -1, optToneMask = 0x3;
static UInt32 optBuffer = 512;
static const char* optCsv = nullptr;
static const char* optLabel = "";
static const char* optZts = nullptr;
struct ZRec { UInt64 call; double zs; UInt64 zh, seed; };
static ZRec gZ[200000];
static std::atomic<UInt32> gZN{0};


// ---- fake HAL host
static std::atomic<bool> gPending{false};
static std::atomic<UInt64> gPendingAction{0};
static std::atomic<int> gPropsChanged{0};
static OSStatus HostPropertiesChanged(AudioServerPlugInHostRef, AudioObjectID, UInt32, const AudioObjectPropertyAddress*) {
    gPropsChanged++;
    return noErr;
}
static OSStatus HostCopyFromStorage(AudioServerPlugInHostRef, CFStringRef key, CFPropertyListRef* out) {
    *out = nullptr;
    if (optMode >= 0 && CFStringCompare(key, CFSTR("latency_mode"), 0) == kCFCompareEqualTo) {
        SInt32 m = optMode;
        *out = CFNumberCreate(nullptr, kCFNumberSInt32Type, &m);
    }
    return noErr;
}
static OSStatus HostWriteToStorage(AudioServerPlugInHostRef, CFStringRef, CFPropertyListRef) { return noErr; }
static OSStatus HostDeleteFromStorage(AudioServerPlugInHostRef, CFStringRef) { return noErr; }
static OSStatus HostRequestConfigChange(AudioServerPlugInHostRef, AudioObjectID, UInt64 action, void*) {
    gPendingAction = action;
    gPending = true;
    return noErr;
}
static AudioServerPlugInHostInterface gHost = {HostPropertiesChanged, HostCopyFromStorage, HostWriteToStorage, HostDeleteFromStorage,
                                               HostRequestConfigChange};

static AudioServerPlugInDriverRef D;
static AudioObjectID gDev;
static CFBundleRef gBundle;

template <typename T> static T prop(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    T v{};
    AudioObjectPropertyAddress a = {sel, scope, 0};
    UInt32 got = 0;
    (*D)->GetPropertyData(D, obj, 0, &a, 0, nullptr, sizeof(T), &got, &v);
    return v;
}

static void applyPendingConfigChange() {
    if (!gPending.exchange(false)) return;
    OSStatus e = (*D)->PerformDeviceConfigurationChange(D, gDev, gPendingAction, nullptr);
    printf("config change %llu -> %d\n", gPendingAction.load(), (int)e);
}

// ---- driver test hooks
typedef void (*StatsFn)(SInt64*);
typedef void (*CountersFn)(UInt32*, UInt64*);
typedef const int* (*HistFn)();
typedef void (*ProbeFn)(double*);
static StatsFn gStatsFn;
static CountersFn gCountersFn;
static HistFn gHistFn;
static ProbeFn gProbeFn;

// ---- IO thread state (written by the IO thread, read by the reporter)
static std::atomic<bool> gRun{true};
static std::atomic<UInt64> gCycles{0}, gOverloads{0}, gSeedChanges{0}, gZeroInFrames{0}, gInFrames{0}, gZeroRuns{0};
static std::atomic<UInt64> gWakeLateMaxUs{0}, gWakeLateSumUs{0}, gWorstGapUs{0};
static std::atomic<double> gIn2Rms{0}, gIn1Rms{0};
static UInt32 gInSafety, gOutSafety;
static double gRate;

static void* ztsThread(void*) {
    while (gRun) {
        Float64 zs; UInt64 zh, seed;
        UInt64 c = mach_absolute_time();
        (*D)->GetZeroTimeStamp(D, gDev, 0, &zs, &zh, &seed);
        UInt32 k = gZN;
        if (k < 200000) { gZ[k] = {c, zs, zh, seed}; gZN = k + 1; }
        usleep(200);
    }
    return nullptr;
}

static void setRealtime(double periodSec, double computeFrac) {
    thread_time_constraint_policy_data_t pol;
    pol.period = (uint32_t)(periodSec * gTicksPerSec);
    pol.computation = (uint32_t)(std::max(computeFrac, 0.05) * periodSec * gTicksPerSec);
    pol.constraint = (uint32_t)(periodSec * gTicksPerSec);
    pol.preemptible = 1;
    thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&pol,
                      THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

static void* ioThread(void*) {
    const UInt32 buf = optBuffer;
    setRealtime(buf / gRate, optCompute / 100.0 + 0.05);
    std::vector<float> in(buf * 4), out(buf * 4);
    const double amp = pow(10.0, optToneDb / 20.0);
    double phase = 0;
    UInt64 lastSeed = 0;
    double next = -1;                 // sample time of the next cycle
    double zsPrev = -1, zhPrev = 0;   // previous distinct zero timestamp, for the rate estimate
    double ticksPerFrame = gTicksPerSec / gRate;
    bool prevEndedZero = false;
    UInt64 lastWake = 0;
    while (gRun) {
        Float64 zs; UInt64 zh, seed;
        (*D)->GetZeroTimeStamp(D, gDev, 0, &zs, &zh, &seed);
        if (seed != lastSeed) {
            if (lastSeed) gSeedChanges++;
            lastSeed = seed; next = -1; zsPrev = -1;
        }
        if (zs != zsPrev) {
            if (zsPrev >= 0 && zs > zsPrev) ticksPerFrame = ((double)zh - zhPrev) / (zs - zsPrev);
            zsPrev = zs; zhPrev = (double)zh;
        }
        UInt64 now = mach_absolute_time();
        double sNow = zs + ((double)now - (double)zh) / ticksPerFrame;
        if (next < 0) next = ceil(sNow / buf) * buf;
        if (sNow - next > buf) { gOverloads++; next = ceil(sNow / buf) * buf; }  // a whole buffer late: skip, like the HAL
        UInt64 wakeAt = (UInt64)((double)zh + (next - zs) * ticksPerFrame);
        if (wakeAt > now) { mach_wait_until(wakeAt); now = mach_absolute_time(); }
        UInt64 lateUs = now > wakeAt ? (UInt64)(secs(now - wakeAt) * 1e6) : 0;
        if (lateUs > gWakeLateMaxUs) gWakeLateMaxUs = lateUs;
        gWakeLateSumUs += lateUs;
        if (lastWake) { UInt64 gap = (UInt64)(secs(now - lastWake) * 1e6); if (gap > gWorstGapUs) gWorstGapUs = gap; }
        lastWake = now;

        AudioServerPlugInIOCycleInfo cyc = {};
        cyc.mIOCycleCounter = gCycles;
        cyc.mNominalIOBufferFrameSize = buf;
        cyc.mInputTime.mSampleTime = next - gInSafety - buf;
        cyc.mOutputTime.mSampleTime = next + buf + gOutSafety;
        cyc.mInputTime.mFlags = cyc.mOutputTime.mFlags = kAudioTimeStampSampleTimeValid;
        if (cyc.mInputTime.mSampleTime >= 0) {
            (*D)->DoIOOperation(D, gDev, 3, 0, kAudioServerPlugInIOOperationReadInput, buf, &cyc, in.data(), nullptr);
            UInt64 zeros = 0, runs = 0;
            double s1 = 0, s2 = 0;
            for (UInt32 i = 0; i < buf; i++) {
                const float* f = &in[i * 4];
                bool z = f[0] == 0 && f[1] == 0 && f[2] == 0 && f[3] == 0;
                if (z) { zeros++; if (!prevEndedZero) runs++; }
                prevEndedZero = z;
                s1 += (double)f[0] * f[0]; s2 += (double)f[1] * f[1];
            }
            gZeroInFrames += zeros; gZeroRuns += runs; gInFrames += buf;
            gIn1Rms = sqrt(s1 / buf); gIn2Rms = sqrt(s2 / buf);
        }
        // "render": busy for compute% of the buffer period, then the tone
        UInt64 busyUntil = mach_absolute_time() + (UInt64)(optCompute / 100.0 * buf / gRate * gTicksPerSec);
        while (mach_absolute_time() < busyUntil) {}
        for (UInt32 i = 0; i < buf; i++) {
            float s = (float)(sin(phase) * amp);
            phase += 2 * M_PI * 1000.0 / gRate;
            if (phase > 2 * M_PI) phase -= 2 * M_PI;
            for (int c = 0; c < 4; c++) out[i * 4 + c] = (optToneMask >> c) & 1 ? s : 0.f;
        }
        (*D)->DoIOOperation(D, gDev, 4, 0, kAudioServerPlugInIOOperationWriteMix, buf, &cyc, out.data(), nullptr);
        next += buf;
        gCycles++;
    }
    return nullptr;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: gbharness <driver bundle> [options]\n"); return 2; }
    for (int i = 2; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() { return i + 1 < argc ? argv[++i] : (char*)"0"; };
        if (a == "--seconds") optSeconds = atof(next());
        else if (a == "--rate") optRate = atof(next());
        else if (a == "--mode") optMode = atoi(next());
        else if (a == "--buffer") optBuffer = (UInt32)atoi(next());
        else if (a == "--compute") optCompute = atof(next());
        else if (a == "--tone-db") optToneDb = atof(next());
        else if (a == "--tone-ch") optToneMask = (int)strtol(next(), nullptr, 0);
        else if (a == "--csv") optCsv = next();
        else if (a == "--restore-rate") optRestoreRate = atof(next());
        else if (a == "--label") optLabel = next();
        else if (a == "--zts") optZts = next();
    }
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    gTicksPerSec = 1e9 * tb.denom / tb.numer;

    CFStringRef path = CFStringCreateWithCString(nullptr, argv[1], kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(nullptr, path, kCFURLPOSIXPathStyle, true);
    gBundle = CFBundleCreate(nullptr, url);
    if (!gBundle || !CFBundleLoadExecutable(gBundle)) { puts("cannot load driver bundle"); return 1; }
    auto create = (void* (*)(CFAllocatorRef, CFUUIDRef))CFBundleGetFunctionPointerForName(gBundle, CFSTR("Mbox3_Create"));
    gStatsFn = (StatsFn)CFBundleGetFunctionPointerForName(gBundle, CFSTR("Mbox3_Stats"));
    gCountersFn = (CountersFn)CFBundleGetFunctionPointerForName(gBundle, CFSTR("Mbox3_DebugCounters"));
    gHistFn = (HistFn)CFBundleGetFunctionPointerForName(gBundle, CFSTR("Mbox3_LeadHist"));
    gProbeFn = (ProbeFn)CFBundleGetFunctionPointerForName(gBundle, CFSTR("Mbox3_ClockProbe"));
    D = (AudioServerPlugInDriverRef)create(nullptr, kAudioServerPlugInTypeUUID);
    if ((*D)->Initialize(D, &gHost)) { puts("Initialize failed"); return 1; }
    AudioObjectID devs[4]; UInt32 n = 0;
    AudioObjectPropertyAddress la = {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, 0};
    (*D)->GetPropertyData(D, kAudioObjectPlugInObject, 0, &la, 0, nullptr, sizeof devs, &n, devs);
    if (!n) { puts("no device"); return 1; }
    gDev = devs[0];
    if (!prop<UInt32>(gDev, kAudioDevicePropertyDeviceIsAlive)) { puts("Mbox not attached"); return 1; }

    if (optRate > 0) {
        AudioObjectPropertyAddress ra = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0};
        Float64 r = optRate;
        OSStatus e = (*D)->SetPropertyData(D, gDev, 0, &ra, 0, nullptr, sizeof r, &r);
        if (e) printf("set rate %.0f -> %d\n", optRate, (int)e);
        applyPendingConfigChange();
    }
    gRate = prop<Float64>(gDev, kAudioDevicePropertyNominalSampleRate);
    gInSafety = prop<UInt32>(gDev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput);
    gOutSafety = prop<UInt32>(gDev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput);
    printf("# %s rate %.0f buffer %u mode %d safety in %u out %u compute %.0f%% tone %.0f dBFS mask 0x%x seconds %.0f\n", optLabel,
           gRate, optBuffer, optMode, gInSafety, gOutSafety, optCompute, optToneDb, optToneMask, optSeconds);
    fflush(stdout);

    if ((*D)->StartIO(D, gDev, 0)) { puts("StartIO failed (is the installed driver streaming?)"); return 1; }
    pthread_t io, zt;
    pthread_create(&io, nullptr, ioThread, nullptr);
    if (optZts) pthread_create(&zt, nullptr, ztsThread, nullptr);

    FILE* csv = optCsv ? fopen(optCsv, "w") : nullptr;
    if (csv) fprintf(csv, "t,cycles,overloads,seed_changes,in_late,out_late,out_resyncs,in_resyncs,submit_err,xfer_err,min_out_lead_us,max_cb_delay_us,"
                          "zero_in_frames,zero_runs,wake_late_max_us,worst_gap_us,in1_rms,in2_rms,model_rate,now_minus_captured,outpos_minus_now\n");
    SInt64 prev[10] = {0};
    UInt64 t0 = mach_absolute_time();
    int sec = 0;
    printf("  t  cyc ovl seed | inLate outLate oRsync iRsync subErr xfErr | minLead(us) maxCbDelay(us) | inZero runs | wakeLateMax gap(us) | in2 dBFS  rate\n");
    while (secs(mach_absolute_time() - t0) < optSeconds) {
        usleep(1000000);
        sec++;
        SInt64 s[10] = {0};
        if (gStatsFn) gStatsFn(s);
        double probe[4] = {0};
        if (gProbeFn) gProbeFn(probe);
        double in2 = gIn2Rms.load();
        printf("%3d %4llu %3llu %4llu | %6lld %7lld %6lld %6lld %6lld %5lld | %11lld %14lld | %6llu %4llu | %11llu %7llu | %7.1f %8.2f\n", sec,
               gCycles.load(), gOverloads.load(), gSeedChanges.load(), s[0] - prev[0], s[2] - prev[2], s[4] - prev[4], s[5] - prev[5],
               s[6] - prev[6], s[7] - prev[7], s[8], s[9], gZeroInFrames.load(), gZeroRuns.load(), gWakeLateMaxUs.load(),
               gWorstGapUs.load(), in2 > 0 ? 20 * log10(in2) : -999.0, probe[2]);
        fflush(stdout);
        if (csv) {
            fprintf(csv, "%d,%llu,%llu,%llu,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%llu,%llu,%llu,%llu,%.6f,%.6f,%.3f,%.1f,%.1f\n", sec,
                    gCycles.load(), gOverloads.load(), gSeedChanges.load(), s[0], s[2], s[4], s[5], s[6], s[7], s[8], s[9],
                    gZeroInFrames.load(), gZeroRuns.load(), gWakeLateMaxUs.load(), gWorstGapUs.load(), gIn1Rms.load(), in2, probe[2],
                    probe[0] - probe[1], probe[3] - probe[0]);
            fflush(csv);
        }
        memcpy(prev, s, sizeof prev);
        gWakeLateMaxUs = 0; gWorstGapUs = 0;
    }
    gRun = false;
    pthread_join(io, nullptr);
    if (optZts) {
        pthread_join(zt, nullptr);
        FILE* zf = fopen(optZts, "w");
        fprintf(zf, "call,zs,zh,seed\n");
        for (UInt32 i = 0; i < gZN; i++) fprintf(zf, "%llu,%.0f,%llu,%llu\n", gZ[i].call, gZ[i].zs, gZ[i].zh, gZ[i].seed);
        fclose(zf);
    }
    (*D)->StopIO(D, gDev, 0);

    SInt64 s[10] = {0};
    if (gStatsFn) gStatsFn(s);
    UInt32 c[6] = {0}; UInt64 nz = 0;
    if (gCountersFn) gCountersFn(c, &nz);
    printf("SUMMARY %s rate=%.0f buf=%u mode=%d compute=%.0f%%: cycles=%llu overloads=%llu seed_changes=%llu in_late=%lld/%lld out_late=%lld/%lld "
           "out_resyncs=%lld in_resyncs=%lld submit_err=%lld xfer_err=%lld min_out_lead_us=%lld max_cb_delay_us=%lld zero_in_frames=%llu "
           "zero_runs=%llu xfers_in=%u xfers_out=%u last_status=0x%x nonzero_out=%llu\n",
           optLabel, gRate, optBuffer, optMode, optCompute, gCycles.load(), gOverloads.load(), gSeedChanges.load(), s[0], s[1], s[2], s[3],
           s[4], s[5], s[6], s[7], s[8], s[9], gZeroInFrames.load(), gZeroRuns.load(), c[0], c[1], c[4], nz);
    if (gHistFn) {
        const int* h = gHistFn();
        printf("LEADHIST ok:");
        for (int i = 0; i < 8; i++) printf(" %d:%d", i, h[i]);
        printf(" rejected:");
        for (int i = 0; i < 8; i++) printf(" %d:%d", i, h[8 + i]);
        puts("");
    }
    if (optRestoreRate > 0 && optRestoreRate != gRate) {
        AudioObjectPropertyAddress ra = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0};
        Float64 r = optRestoreRate;
        (*D)->SetPropertyData(D, gDev, 0, &ra, 0, nullptr, sizeof r, &r);
        applyPendingConfigChange();
        printf("restored hardware rate %.0f\n", optRestoreRate);
    }
    if (csv) fclose(csv);
    return 0;
}
