// halio: end-to-end test of the installed driver through coreaudiod. Opens the Mbox 3 with its own IOProc (no
// default-device change), plays a quiet tone on chosen outputs, records the inputs, and reports once a second:
// IOProc timing, sample-time continuity (HAL timeline jumps), overload notifications, input dropouts (runs of exact
// digital silence on all four inputs, which is what the driver returns for frames it does not have).
//
//   halio [--seconds S] [--buffer N] [--rate R] [--tone-db DB] [--tone-ch MASK] [--csv FILE] [--wav FILE] [--label T]
//         [--restore-rate R] [--restore-buffer N] [--stall-ms MS --stall-every S]   (stall: simulate a slow IOProc)
#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <unistd.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static double gTicksPerSec;
static double optSeconds = 10, optRate = 0, optToneDb = -40, optRestoreRate = 0, optStallMs = 0, optStallEvery = 0;
static UInt32 optBuffer = 0, optRestoreBuffer = 0;
static int optToneMask = 0x3;
static const char* optCsv = nullptr;
static const char* optWav = nullptr;
static const char* optLabel = "";
static const char* optUid = "Mbox3:0dba:5000";

static AudioObjectID gDev;
static double gRate;
static UInt32 gBuf;

// IOProc statistics
static std::atomic<UInt64> gCalls{0}, gJumps{0}, gZeroFrames{0}, gZeroRuns{0}, gInFrames{0}, gOverloads{0}, gLateCalls{0};
static std::atomic<UInt64> gMaxCallGapUs{0}, gMaxLatenessUs{0};
static std::atomic<double> gLastIn2Rms{0}, gMaxJump{0};
static double gExpectNext = -1, gPhase = 0, gOutMinusIn = 0;
static std::atomic<UInt64> gInOutSkew{0};
static int gJumpHist[4096];
static double gFirstOut = -1, gLastOut = 0;
static UInt64 gRendered = 0;
struct TraceRec { UInt64 call; double nowS, nowRate, outS, inS; UInt64 nowH; };
static TraceRec gTrace[20000];
static std::atomic<UInt32> gTraceN{0};
static const char* optTrace = nullptr;
static bool optInput = false;
static UInt64 gLastCallHost = 0;
static UInt64 gStallCounter = 0;
static bool gPrevZero = false;
static std::vector<float> gWavData;
static std::atomic<bool> gRecord{false};

static OSStatus ioProc(AudioObjectID, const AudioTimeStamp* now, const AudioBufferList* in, const AudioTimeStamp* inTime,
                       AudioBufferList* out, const AudioTimeStamp* outTime, void*) {
    UInt64 h = mach_absolute_time();
    if (optTrace) { UInt32 k = gTraceN; if (k < 20000) { gTrace[k] = {h, now->mSampleTime, now->mRateScalar, outTime->mSampleTime, inTime->mSampleTime, now->mHostTime}; gTraceN = k + 1; } }
    gCalls++;
    if (gLastCallHost) {
        UInt64 gap = (UInt64)((h - gLastCallHost) / gTicksPerSec * 1e6);
        if (gap > gMaxCallGapUs) gMaxCallGapUs = gap;
        if (gap > 2.0 * gBuf / gRate * 1e6) gLateCalls++;
    }
    gLastCallHost = h;
    // the IOProc runs after the cycle's wake-up time (now->mHostTime): how late
    if (now->mFlags & kAudioTimeStampHostTimeValid && h > now->mHostTime) {
        UInt64 late = (UInt64)((h - now->mHostTime) / gTicksPerSec * 1e6);
        if (late > gMaxLatenessUs) gMaxLatenessUs = late;
    }
    // continuity of the HAL's timeline: each cycle should start exactly one buffer after the previous one
    // output timeline (valid whether or not this IOProc takes input); input time is checked against it below
    double s = outTime->mSampleTime;
    if (optInput && fabs((outTime->mSampleTime - inTime->mSampleTime) - gOutMinusIn) > 0.5 && gExpectNext >= 0) gInOutSkew++;
    gOutMinusIn = outTime->mSampleTime - inTime->mSampleTime;
    if (gFirstOut < 0) gFirstOut = s;
    gLastOut = s; gRendered += gBuf;
    if (gExpectNext >= 0 && fabs(s - gExpectNext) > 0.5) {
        gJumps++;
        int jb = (int)llround(s - gExpectNext) + 2048;
        if (jb >= 0 && jb < 4096) gJumpHist[jb]++;
        double j = s - gExpectNext;
        if (fabs(j) > fabs(gMaxJump.load())) gMaxJump = j;
    }
    UInt32 frames = 0;
    if (in && in->mNumberBuffers > 0) {
        const AudioBuffer& b = in->mBuffers[0];
        UInt32 ch = b.mNumberChannels;
        frames = b.mDataByteSize / (ch * sizeof(float));
        const float* f = (const float*)b.mData;
        double s2 = 0;
        for (UInt32 i = 0; i < frames; i++) {
            bool z = true;
            for (UInt32 c = 0; c < ch; c++) if (f[i * ch + c] != 0) { z = false; break; }
            if (z) { gZeroFrames++; if (!gPrevZero) gZeroRuns++; }
            gPrevZero = z;
            if (ch > 1) s2 += (double)f[i * ch + 1] * f[i * ch + 1];
        }
        gInFrames += frames;
        gLastIn2Rms = frames ? sqrt(s2 / frames) : 0;
        if (gRecord && gWavData.size() + frames * ch < gWavData.capacity())
            gWavData.insert(gWavData.end(), f, f + frames * ch);
    }
    gExpectNext = s + gBuf;
    if (out && out->mNumberBuffers > 0) {
        AudioBuffer& b = out->mBuffers[0];
        UInt32 ch = b.mNumberChannels, n = b.mDataByteSize / (ch * sizeof(float));
        float* f = (float*)b.mData;
        double amp = pow(10.0, optToneDb / 20.0);
        for (UInt32 i = 0; i < n; i++) {
            float v = (float)(sin(gPhase) * amp);
            gPhase += 2 * M_PI * 1000.0 / gRate;
            if (gPhase > 2 * M_PI) gPhase -= 2 * M_PI;
            for (UInt32 c = 0; c < ch; c++) f[i * ch + c] = (optToneMask >> c) & 1 ? v : 0.f;
        }
    }
    if (optStallMs > 0 && optStallEvery > 0 && ++gStallCounter % (UInt64)(optStallEvery * gRate / gBuf) == 0) {
        UInt64 until = mach_absolute_time() + (UInt64)(optStallMs / 1000.0 * gTicksPerSec);
        while (mach_absolute_time() < until) {}
    }
    return noErr;
}

static OSStatus overloadListener(AudioObjectID, UInt32, const AudioObjectPropertyAddress*, void*) {
    gOverloads++;
    return noErr;
}

template <typename T> static OSStatus getp(AudioObjectID o, AudioObjectPropertySelector s, T& v, AudioObjectPropertyScope sc = kAudioObjectPropertyScopeGlobal) {
    AudioObjectPropertyAddress a = {s, sc, 0};
    UInt32 sz = sizeof(T);
    return AudioObjectGetPropertyData(o, &a, 0, nullptr, &sz, &v);
}
template <typename T> static OSStatus setp(AudioObjectID o, AudioObjectPropertySelector s, const T& v) {
    AudioObjectPropertyAddress a = {s, kAudioObjectPropertyScopeGlobal, 0};
    return AudioObjectSetPropertyData(o, &a, 0, nullptr, sizeof(T), &v);
}

static bool waitRate(double rate) {
    for (int i = 0; i < 50; i++) {
        Float64 r = 0;
        getp(gDev, kAudioDevicePropertyNominalSampleRate, r);
        if (r == rate) return true;
        usleep(100000);
    }
    return false;
}

static void writeWav(const char* path, const std::vector<float>& d, int ch, int rate) {
    FILE* f = fopen(path, "wb");
    if (!f) return;
    UInt32 dataBytes = (UInt32)(d.size() * 4), riff = 36 + dataBytes, fmtLen = 16, byteRate = rate * ch * 4;
    UInt16 fmt = 3, chn = ch, align = ch * 4, bits = 32;
    UInt32 r = rate;
    fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f); fwrite(&fmtLen, 4, 1, f);
    fwrite(&fmt, 2, 1, f); fwrite(&chn, 2, 1, f); fwrite(&r, 4, 1, f); fwrite(&byteRate, 4, 1, f); fwrite(&align, 2, 1, f);
    fwrite(&bits, 2, 1, f); fwrite("data", 1, 4, f); fwrite(&dataBytes, 4, 1, f); fwrite(d.data(), 4, d.size(), f);
    fclose(f);
}

int main(int argc, char** argv) {
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() { return i + 1 < argc ? argv[++i] : (char*)"0"; };
        if (a == "--seconds") optSeconds = atof(next());
        else if (a == "--rate") optRate = atof(next());
        else if (a == "--buffer") optBuffer = (UInt32)atoi(next());
        else if (a == "--tone-db") optToneDb = atof(next());
        else if (a == "--tone-ch") optToneMask = (int)strtol(next(), nullptr, 0);
        else if (a == "--csv") optCsv = next();
        else if (a == "--wav") optWav = next();
        else if (a == "--label") optLabel = next();
        else if (a == "--uid") optUid = next();
        else if (a == "--input") optInput = true;
        else if (a == "--trace") optTrace = next();
        else if (a == "--restore-rate") optRestoreRate = atof(next());
        else if (a == "--restore-buffer") optRestoreBuffer = (UInt32)atoi(next());
        else if (a == "--stall-ms") optStallMs = atof(next());
        else if (a == "--stall-every") optStallEvery = atof(next());
    }
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    gTicksPerSec = 1e9 * tb.denom / tb.numer;

    AudioObjectID uidDev = 0;
    CFStringRef uid = CFStringCreateWithCString(nullptr, optUid, kCFStringEncodingUTF8);
    AudioValueTranslation t = {&uid, sizeof uid, &uidDev, sizeof uidDev};
    AudioObjectPropertyAddress ta = {kAudioHardwarePropertyDeviceForUID, kAudioObjectPropertyScopeGlobal, 0};
    UInt32 tsz = sizeof t;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &ta, 0, nullptr, &tsz, &t) || !uidDev) { puts("device not found"); return 1; }
    gDev = uidDev;
    UInt32 alive = 0;
    getp(gDev, kAudioDevicePropertyDeviceIsAlive, alive);
    if (!alive) { puts("Mbox 3 not alive"); return 1; }

    if (optRate > 0) {
        OSStatus e = setp(gDev, kAudioDevicePropertyNominalSampleRate, (Float64)optRate);
        printf("set rate %.0f: %d, %s\n", optRate, (int)e, waitRate(optRate) ? "applied" : "NOT applied within 5 s");
    }
    if (optBuffer) {
        OSStatus e = setp(gDev, kAudioDevicePropertyBufferFrameSize, optBuffer);
        if (e) printf("set buffer %u: error %d\n", optBuffer, (int)e);
    }
    getp(gDev, kAudioDevicePropertyNominalSampleRate, gRate);
    getp(gDev, kAudioDevicePropertyBufferFrameSize, gBuf);
    UInt32 sIn = 0, sOut = 0, lIn = 0, lOut = 0;
    getp(gDev, kAudioDevicePropertySafetyOffset, sIn, kAudioObjectPropertyScopeInput);
    getp(gDev, kAudioDevicePropertySafetyOffset, sOut, kAudioObjectPropertyScopeOutput);
    getp(gDev, kAudioDevicePropertyLatency, lIn, kAudioObjectPropertyScopeInput);
    getp(gDev, kAudioDevicePropertyLatency, lOut, kAudioObjectPropertyScopeOutput);
    printf("# %s rate %.0f buffer %u (asked %u) safety in %u out %u latency in %u out %u -> round trip %.1f ms; tone %.0f dBFS mask 0x%x\n",
           optLabel, gRate, gBuf, optBuffer, sIn, sOut, lIn, lOut, (2.0 * gBuf + sIn + sOut + lIn + lOut) / gRate * 1000, optToneDb, optToneMask);

    AudioObjectPropertyAddress oa = {kAudioDeviceProcessorOverload, kAudioObjectPropertyScopeGlobal, 0};
    AudioObjectAddPropertyListener(gDev, &oa, overloadListener, nullptr);
    if (optWav) { gWavData.reserve((size_t)(gRate * 4 * std::min(optSeconds, 60.0))); gRecord = true; }

    AudioDeviceIOProcID pid = nullptr;
    if (AudioDeviceCreateIOProcID(gDev, ioProc, nullptr, &pid)) { puts("CreateIOProcID failed"); return 1; }
    if (!optInput) {
        // Output only: switch this IOProc's input streams off, so coreaudiod does not need microphone permission
        AudioObjectPropertyAddress ua = {kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput, 0};
        UInt32 sz = 0;
        if (AudioObjectGetPropertyDataSize(gDev, &ua, 0, nullptr, &sz) == noErr && sz) {
            std::vector<UInt8> b(sz);
            AudioHardwareIOProcStreamUsage* u = (AudioHardwareIOProcStreamUsage*)b.data();
            u->mIOProc = (void*)pid;
            if (AudioObjectGetPropertyData(gDev, &ua, 0, nullptr, &sz, u) == noErr) {
                for (UInt32 i = 0; i < u->mNumberStreams; i++) u->mStreamIsOn[i] = 0;
                OSStatus ue = AudioObjectSetPropertyData(gDev, &ua, 0, nullptr, sz, u);
                printf("input streams off for this IOProc: %d\n", (int)ue);
            }
        }
    }
    UInt64 t0 = mach_absolute_time();
    OSStatus se = AudioDeviceStart(gDev, pid);
    printf("AudioDeviceStart: %d (%.0f ms)\n", (int)se, (mach_absolute_time() - t0) / gTicksPerSec * 1000);
    if (se) return 1;

    FILE* csv = optCsv ? fopen(optCsv, "w") : nullptr;
    if (csv) fprintf(csv, "t,calls,jumps,max_jump,zero_frames,zero_runs,overloads,late_calls,max_gap_us,max_lateness_us,in2_rms,actual_rate\n");
    printf("  t  calls jumps maxJump | zeroFr runs | ovl lateCalls | maxGap(us) maxLate(us) | in2 dBFS | actualRate\n");
    t0 = mach_absolute_time();
    int sec = 0;
    while ((mach_absolute_time() - t0) / gTicksPerSec < optSeconds) {
        usleep(1000000);
        sec++;
        Float64 actual = 0;
        getp(gDev, kAudioDevicePropertyActualSampleRate, actual);
        double in2 = gLastIn2Rms.load();
        printf("%3d %6llu %5llu %7.0f | %6llu %4llu | %3llu %9llu | %10llu %11llu | %7.1f | %.3f\n", sec, gCalls.load(), gJumps.load(), gMaxJump.load(),
               gZeroFrames.load(), gZeroRuns.load(), gOverloads.load(), gLateCalls.load(), gMaxCallGapUs.load(), gMaxLatenessUs.load(),
               in2 > 0 ? 20 * log10(in2) : -999.0, actual);
        fflush(stdout);
        if (csv) {
            fprintf(csv, "%d,%llu,%llu,%.0f,%llu,%llu,%llu,%llu,%llu,%llu,%.6f,%.3f\n", sec, gCalls.load(), gJumps.load(), gMaxJump.load(),
                    gZeroFrames.load(), gZeroRuns.load(), gOverloads.load(), gLateCalls.load(), gMaxCallGapUs.load(), gMaxLatenessUs.load(), in2, actual);
            fflush(csv);
        }
        gMaxCallGapUs = 0; gMaxLatenessUs = 0;
    }
    AudioDeviceStop(gDev, pid);
    AudioDeviceDestroyIOProcID(gDev, pid);
    gRecord = false;
    printf("SUMMARY %s rate=%.0f buf=%u: calls=%llu jumps=%llu max_jump=%.0f zero_frames=%llu/%llu zero_runs=%llu overloads=%llu late_calls=%llu\n",
           optLabel, gRate, gBuf, gCalls.load(), gJumps.load(), gMaxJump.load(), gZeroFrames.load(), gInFrames.load(), gZeroRuns.load(),
           gOverloads.load(), gLateCalls.load());
    {
        double span = gLastOut + gBuf - gFirstOut;
        printf("TIMELINE span %.0f frames, rendered %llu frames -> %.3f%% of the output timeline never rendered\n", span,
               gRendered, span > 0 ? 100.0 * (span - (double)gRendered) / span : 0);
        printf("JUMPS (frames:count)");
        int shown = 0;
        for (int i = 0; i < 4096 && shown < 24; i++) if (gJumpHist[i]) { printf(" %+d:%d", i - 2048, gJumpHist[i]); shown++; }
        puts("");
    }
    if (optTrace) {
        FILE* tf = fopen(optTrace, "w");
        fprintf(tf, "call_host,now_sample,now_host,now_rate_scalar,out_sample,in_sample\n");
        for (UInt32 i = 0; i < gTraceN; i++)
            fprintf(tf, "%llu,%.3f,%llu,%.9f,%.3f,%.3f\n", gTrace[i].call, gTrace[i].nowS, gTrace[i].nowH, gTrace[i].nowRate, gTrace[i].outS, gTrace[i].inS);
        fclose(tf);
    }
    if (optWav) writeWav(optWav, gWavData, 4, (int)gRate);
    if (optRestoreBuffer) setp(gDev, kAudioDevicePropertyBufferFrameSize, optRestoreBuffer);
    if (optRestoreRate > 0 && optRestoreRate != gRate) {
        setp(gDev, kAudioDevicePropertyNominalSampleRate, (Float64)optRestoreRate);
        printf("restore rate %.0f: %s\n", optRestoreRate, waitRate(optRestoreRate) ? "ok" : "FAILED");
    }
    if (csv) fclose(csv);
    return 0;
}
