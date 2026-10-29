#include "IsochStream.h"

#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <mach/mach_time.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>

#include "DriverState.h"
#include "HardwareClock.h"
#include "PacketCodec.h"
#include "UsbHost.h"

namespace mbox::stream {
namespace {

typedef IOUSBInterfaceInterface942 USBIntf;

struct Xfer {
    bool in;
    bool busy;     // OUT only: queued on the bus
    UInt64 frame;  // bus frame (ms) this transfer was scheduled for
    UInt8* buf;
    IOUSBLowLatencyIsocFrame* frames;
};

// USB thread state
USBIntf** gInIntf = nullptr;
USBIntf** gOutIntf = nullptr;
UInt8 gInPipe = 0, gOutPipe = 0;
Xfer gIn[kInXfers], gOut[kOutXfers];
UInt64 gNextInFrame = 0, gNextOutFrame = 0;
std::atomic<bool> gStreaming{false};
std::atomic<int> gPendingXfers{0};
UInt64 gOutPos = 0;                                // device time of the next OUT frame
UInt64 gLastInEndFrame = 0, gLastInEndPos = 0;     // bus frame after the newest IN transfer, and inPos there
bool gOutSynced = false;
UInt64 gLastOutQueuedFrame = 0;                    // frame numbers must keep increasing per pipe

// Audio rings (float, interleaved). Positions are device sample times.
float gInRing[kRingFrames * kChannels];
float gOutRing[kRingFrames * kChannels];
std::atomic<UInt64> gInPos{0};                     // frames captured so far
std::atomic<UInt64> gOutPosShared{0};              // gOutPos published for the IO thread

// Implicit feedback: frame counts of received IN packets, replayed on OUT
UInt8 gFeedback[kFeedbackSlots];
std::atomic<UInt32> gFbHead{0};
UInt32 gFbTail = 0;
double gFbAccum = 0;

// Rate watch window
UInt64 gRateWinStart = 0, gRateWinFrames = 0, gLastRateFix = 0;

ClockModel gClock;

// Statistics
std::atomic<UInt32> gInDone{0}, gOutDone{0}, gOutErrors{0}, gSubmitErrors{0}, gLastStatus{0};
std::atomic<UInt64> gOutNonZero{0};
std::atomic<UInt64> gInLateFrames{0}, gInReads{0}, gOutLateFrames{0}, gOutWrites{0};
std::atomic<UInt32> gOutResyncs{0}, gInResyncs{0}, gMinOutLeadUs{UINT32_MAX}, gMaxCallbackDelayUs{0};
int gLeadHist[16];

void submitIn(Xfer* x);
void pumpOut();

UInt64 busFrame() {
    AbsoluteTime at;
    UInt64 frame = 0;
    (*gInIntf)->GetBusFrameNumber(gInIntf, &frame, &at);
    return frame;
}

// If the hardware streams at another rate than Core Audio expects (someone changed it underneath us), restore it.
// The control request runs after this completion returns.
void watchRate(UInt64 frames) {
    UInt64 now = mach_absolute_time();
    if (!gRateWinStart) { gRateWinStart = now; gRateWinFrames = 0; return; }
    gRateWinFrames += frames;
    double secs = (double)(now - gRateWinStart) / gState.hostTicksPerSecond;
    if (secs < 1.0) return;
    double measured = gRateWinFrames / secs;
    gRateWinStart = now; gRateWinFrames = 0;
    if (fabs(measured / gState.sampleRate.load() - 1.0) < 0.02 || (double)(now - gLastRateFix) < 3 * gState.hostTicksPerSecond) return;
    gLastRateFix = now;
    usb::performAsync(^{
        hw::enforce(false);
        gClock.invalidate();  // re-anchor
    });
}

void inputDone(Xfer* x) {
    UInt64 pos = gInPos.load(std::memory_order_relaxed);
    const UInt64 startPos = pos;
    for (UInt32 f = 0; f < kMicroframesPerXfer; f++) {
        UInt32 frames = std::min(x->frames[f].frActCount / kBytesPerUSBFrame, kMaxPacket / kBytesPerUSBFrame);
        codec::unpackPacket(x->buf + f * kMaxPacket, frames, gInRing, pos);
        pos += frames;
        UInt32 h = gFbHead.load(std::memory_order_relaxed);
        gFeedback[h & (kFeedbackSlots - 1)] = (UInt8)frames;
        gFbHead.store(h + 1, std::memory_order_release);
    }
    gInPos.store(pos, std::memory_order_release);
    watchRate(pos - startPos);
    gLastInEndFrame = x->frame + kMicroframesPerXfer / 8;
    gLastInEndPos = pos;
    const IOUSBLowLatencyIsocFrame& last = x->frames[kMicroframesPerXfer - 1];
    UInt64 ts = *(const UInt64*)&last.frTimeStamp;
    if (ts) {
        gClock.update(pos, ts, gState.sampleRate.load());
        UInt64 now = mach_absolute_time();
        UInt32 delayUs = now > ts ? (UInt32)((now - ts) * 1e6 / gState.hostTicksPerSecond) : 0;
        if (delayUs > gMaxCallbackDelayUs) gMaxCallbackDelayUs = delayUs;
    }
    submitIn(x);
    pumpOut();
}

void xferDone(void* refcon, IOReturn result, void*) {
    Xfer* x = (Xfer*)refcon;
    gPendingXfers--;
    if (!x->in) x->busy = false;
    if (!gStreaming) return;
    (x->in ? gInDone : gOutDone)++;
    if (result != kIOReturnSuccess) { gLastStatus = result; if (!x->in) gOutErrors++; }
    if (x->in) inputDone(x);
    else pumpOut();  // OUT completions also top up the queue
}

void submitIn(Xfer* x) {
    for (int attempt = 0; attempt < 2 && gStreaming; attempt++) {
        for (UInt32 f = 0; f < kMicroframesPerXfer; f++) {
            x->frames[f].frReqCount = kMaxPacket; x->frames[f].frActCount = 0; x->frames[f].frStatus = 0;
        }
        x->frame = gNextInFrame;
        IOReturn kr = (*gInIntf)->LowLatencyReadIsochPipeAsync(gInIntf, gInPipe, x->buf, gNextInFrame, kMicroframesPerXfer, 1,
                                                               x->frames, xferDone, x);
        gNextInFrame += kMicroframesPerXfer / 8;
        if (kr == kIOReturnSuccess) { gPendingXfers++; return; }
        gSubmitErrors++; gLastStatus = kr;
        os_log_error(driverLog(), "submit in failed: 0x%x, resyncing", kr);
        gInResyncs++;
        gNextInFrame = busFrame() + 2;  // fell off the schedule: restart just ahead of the bus
        gClock.invalidate();
    }
}

UInt32 nextOutPacketFrames() {
    UInt32 head = gFbHead.load(std::memory_order_acquire);
    if (gFbTail != head && head - gFbTail < kFeedbackSlots) return gFeedback[gFbTail++ & (kFeedbackSlots - 1)];
    // No feedback yet: nominal pattern
    gFbAccum += gState.sampleRate.load() / 8000.0;
    UInt32 n = (UInt32)gFbAccum;
    gFbAccum -= n;
    return n;
}

// Isochronous packets are packed back to back in the transfer buffer: packet f starts right after the
// frReqCount bytes of packet f-1. (IN can use fixed kMaxPacket slots only because every IN request is kMaxPacket.)
void fillOut(Xfer* x) {
    UInt8* p = x->buf;
    UInt64 nonZero = 0;
    for (UInt32 f = 0; f < kMicroframesPerXfer; f++) {
        UInt32 frames = std::min(nextOutPacketFrames(), kMaxPacket / kBytesPerUSBFrame);
        nonZero += codec::packPacket(gOutRing, gOutPos, frames, p);
        p += frames * kBytesPerUSBFrame;
        gOutPos += frames;
        gOutPosShared.store(gOutPos, std::memory_order_release);
        x->frames[f].frReqCount = frames * kBytesPerUSBFrame; x->frames[f].frActCount = 0; x->frames[f].frStatus = 0;
    }
    if (nonZero) gOutNonZero += nonZero;
}

// Keep OUT scheduled up to the latency profile's lead ahead of the bus, never further (writes may complete early).
void pumpOut() {
    UInt64 cur = busFrame();
    if (gOutSynced) {
        UInt32 leadUs = gNextOutFrame > cur ? (UInt32)((gNextOutFrame - cur) * 1000) : 0;
        if (leadUs < gMinOutLeadUs) gMinOutLeadUs = leadUs;
    }
    if (!gOutSynced || gNextOutFrame <= cur + 1) {
        if (gOutSynced) gOutResyncs++;
        // (Re)start OUT safely ahead of the bus (never behind frames already queued; the controller rejects
        // frames that are too close), aligned to device time via the newest IN transfer
        gNextOutFrame = std::max(cur + 3, gOutSynced ? gLastOutQueuedFrame + 1 : 0);
        gOutPos = gLastInEndPos + (UInt64)llround((double)(gNextOutFrame - gLastInEndFrame) * gState.sampleRate.load() / 1000.0);
        gFbTail = gFbHead.load(std::memory_order_acquire);
        gOutSynced = true;
    }
    const UInt64 lead = latency().outLeadMs;
    for (UInt32 i = 0; i < kOutXfers && gNextOutFrame <= cur + lead; i++) {
        Xfer* x = &gOut[i];
        if (x->busy) continue;
        fillOut(x);
        x->frame = gNextOutFrame;
        IOReturn kr = (*gOutIntf)->LowLatencyWriteIsochPipeAsync(gOutIntf, gOutPipe, x->buf, gNextOutFrame, kMicroframesPerXfer, 1,
                                                                 x->frames, xferDone, x);
        gNextOutFrame += kMicroframesPerXfer / 8;
        int bucket = std::clamp((int)(x->frame - cur), 0, 7);
        if (kr == kIOReturnSuccess) { x->busy = true; gPendingXfers++; gLeadHist[bucket]++; gLastOutQueuedFrame = x->frame; }
        else { gSubmitErrors++; gLastStatus = kr; gOutSynced = false; gLeadHist[8 + bucket]++; break; }
    }
}

USBIntf** openInterface(UInt8 number, UInt8 alt, UInt8 endpoint, UInt8* pipeOut) {
    IOUSBDeviceInterface320** dev = usb::device();
    IOUSBFindInterfaceRequest req = {kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
                                     kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare};
    io_iterator_t it;
    if ((*dev)->CreateInterfaceIterator(dev, &req, &it) != kIOReturnSuccess) return nullptr;
    USBIntf** intf = nullptr;
    io_service_t s;
    while (!intf && (s = IOIteratorNext(it))) {
        IOCFPlugInInterface** pi = nullptr;
        SInt32 score;
        if (IOCreatePlugInInterfaceForService(s, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &pi, &score) == 0 && pi) {
            USBIntf** cand = nullptr;
            (*pi)->QueryInterface(pi, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID942), (LPVOID*)&cand);
            IODestroyPlugInInterface(pi);
            UInt8 num = 0xff;
            if (cand) (*cand)->GetInterfaceNumber(cand, &num);
            if (num == number) intf = cand; else if (cand) (*cand)->Release(cand);
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    if (!intf) { os_log_error(driverLog(), "interface %d not found", number); return nullptr; }
    IOReturn kr = (*intf)->USBInterfaceOpen(intf);
    // Pass through alt 0 first: if a previous host process died mid-stream the interface may still be at the
    // streaming alt, and re-selecting the same alt does not re-arm the Mbox's playback path.
    if (kr == kIOReturnSuccess) (*intf)->SetAlternateInterface(intf, 0);
    if (kr == kIOReturnSuccess) kr = (*intf)->SetAlternateInterface(intf, alt);
    if (kr != kIOReturnSuccess) {
        os_log_error(driverLog(), "open interface %d alt %d failed: 0x%x", number, alt, kr);
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        return nullptr;
    }
    UInt8 n = 0;
    *pipeOut = 0;
    (*intf)->GetNumEndpoints(intf, &n);
    for (UInt8 p = 1; p <= n; p++) {
        UInt8 dir, num, type, interval;
        UInt16 mps;
        (*intf)->GetPipeProperties(intf, p, &dir, &num, &type, &mps, &interval);
        if (((dir == kUSBIn) ? 0x80 : 0) + num == endpoint) *pipeOut = p;
    }
    CFRunLoopSourceRef src = nullptr;
    (*intf)->CreateInterfaceAsyncEventSource(intf, &src);
    if (src) CFRunLoopAddSource(usb::runLoop(), src, kCFRunLoopDefaultMode);
    return intf;
}

void closeInterface(USBIntf**& intf) {
    if (!intf) return;
    CFRunLoopSourceRef src = (*intf)->GetInterfaceAsyncEventSource(intf);
    if (src) CFRunLoopRemoveSource(usb::runLoop(), src, kCFRunLoopDefaultMode);
    (*intf)->SetAlternateInterface(intf, 0);
    (*intf)->USBInterfaceClose(intf);
    (*intf)->Release(intf);
    intf = nullptr;
}

void allocXfers(USBIntf** intf, Xfer* xs, UInt32 count, bool in) {
    for (UInt32 i = 0; i < count; i++) {
        Xfer& x = xs[i];
        x.in = in;
        if (x.buf) continue;
        void* b = nullptr;
        void* f = nullptr;
        (*intf)->LowLatencyCreateBuffer(intf, &b, kMicroframesPerXfer * kMaxPacket, in ? kUSBLowLatencyReadBuffer : kUSBLowLatencyWriteBuffer);
        (*intf)->LowLatencyCreateBuffer(intf, &f, kMicroframesPerXfer * sizeof(IOUSBLowLatencyIsocFrame), kUSBLowLatencyFrameListBuffer);
        x.buf = b ? (UInt8*)b : (UInt8*)calloc(kMicroframesPerXfer, kMaxPacket);
        x.frames = f ? (IOUSBLowLatencyIsocFrame*)f : (IOUSBLowLatencyIsocFrame*)calloc(kMicroframesPerXfer, sizeof(IOUSBLowLatencyIsocFrame));
    }
}

void forgetXfers(Xfer* xs, UInt32 count) {
    // Low-latency buffers are released with their interface; just forget the pointers
    for (UInt32 i = 0; i < count; i++) { xs[i].buf = nullptr; xs[i].frames = nullptr; }
}

void resetStatistics() {
    gInLateFrames = 0; gInReads = 0; gOutLateFrames = 0; gOutWrites = 0;
    gOutResyncs = 0; gInResyncs = 0; gMinOutLeadUs = UINT32_MAX; gMaxCallbackDelayUs = 0;
    gSubmitErrors = 0; gOutErrors = 0;
}

}  // namespace

ClockModel& deviceClock() { return gClock; }

void stop() {
    if (!gStreaming && !gInIntf && !gOutIntf) return;
    gStreaming = false;
    if (gInIntf && gInPipe) (*gInIntf)->AbortPipe(gInIntf, gInPipe);
    if (gOutIntf && gOutPipe) (*gOutIntf)->AbortPipe(gOutIntf, gOutPipe);
    // Let aborted completions drain
    for (int i = 0; i < 50 && gPendingXfers > 0; i++) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
    gPendingXfers = 0;
    closeInterface(gInIntf);
    closeInterface(gOutIntf);
    forgetXfers(gIn, kInXfers);
    forgetXfers(gOut, kOutXfers);
    os_log(driverLog(), "streaming stopped");
}

bool start() {
    if (!usb::device()) return false;
    if (gStreaming) return true;
    usb::setRealtimePriority();
    gInIntf = openInterface(MBOX_IF_CAPTURE, MBOX_ALT_STREAMING, MBOX_EP_CAPTURE, &gInPipe);
    gOutIntf = openInterface(MBOX_IF_PLAYBACK, MBOX_ALT_STREAMING, MBOX_EP_PLAYBACK, &gOutPipe);
    if (!gInIntf || !gOutIntf || !gInPipe || !gOutPipe) { stop(); return false; }
    allocXfers(gInIntf, gIn, kInXfers, true);
    allocXfers(gOutIntf, gOut, kOutXfers, false);

    memset(gInRing, 0, sizeof(gInRing));
    memset(gOutRing, 0, sizeof(gOutRing));
    gInPos = 0;
    gOutPosShared = 0;
    gRateWinStart = 0; gLastRateFix = 0;
    resetStatistics();
    gFbHead = 0; gFbTail = 0; gFbAccum = 0;
    // OUT frame n plays at device time n (aligned in pumpOut). OUT buffers are filled up to the profile's lead early;
    // the output safety offset makes the HAL write that far ahead.
    gOutPos = 0;
    gClock.reset(mach_absolute_time(), gState.sampleRate.load());

    gNextInFrame = busFrame() + 3;
    gLastInEndFrame = gNextInFrame; gLastInEndPos = 0;
    gOutSynced = false;
    for (UInt32 i = 0; i < kOutXfers; i++) gOut[i].busy = false;
    gStreaming = true;
    gPendingXfers = 0;
    for (UInt32 i = 0; i < kInXfers; i++) submitIn(&gIn[i]);  // OUT starts from the first IN completion
    os_log(driverLog(), "streaming started at %.0f Hz", gState.sampleRate.load());
    return true;
}

UInt64 readInput(SInt64 start, UInt32 frames, float* dst) {
    SInt64 have = (SInt64)gInPos.load(std::memory_order_acquire);
    UInt64 late = 0;
    for (UInt32 i = 0; i < frames; i++) {
        SInt64 t = start + i;
        if (t < 0 || t >= have || t < have - (SInt64)kRingFrames) {
            memset(dst + i * kChannels, 0, kChannels * sizeof(float));  // not captured (yet): silence, never stale audio
            late++;
        } else {
            memcpy(dst + i * kChannels, codec::ringFrame(gInRing, (UInt64)t), kChannels * sizeof(float));
        }
    }
    gInReads += frames;
    if (late) gInLateFrames += late;
    return late;
}

UInt64 writeOutput(SInt64 start, UInt32 frames, const float* src) {
    // Output sample times are device times; the USB thread sends ring frame n at device time n
    SInt64 sent = (SInt64)gOutPosShared.load(std::memory_order_acquire);
    UInt64 lost = start < sent ? (UInt64)std::min<SInt64>(sent - start, frames) : 0;
    if (lost) gOutLateFrames += lost;
    for (UInt32 i = 0; i < frames; i++)
        memcpy(codec::ringFrame(gOutRing, (UInt64)(start + i)), src + i * kChannels, kChannels * sizeof(float));
    gOutWrites += frames;
    return lost;
}

Stats stats() {
    Stats s;
    s.inLateFrames = gInLateFrames; s.inReads = gInReads; s.outLateFrames = gOutLateFrames; s.outWrites = gOutWrites;
    s.outResyncs = gOutResyncs; s.inResyncs = gInResyncs; s.submitErrors = gSubmitErrors; s.outErrors = gOutErrors;
    s.minOutLeadUs = gMinOutLeadUs; s.maxCallbackDelayUs = gMaxCallbackDelayUs;
    s.inDone = gInDone; s.outDone = gOutDone; s.lastStatus = gLastStatus;
    s.outPos = gOutPosShared.load(); s.inPos = gInPos.load(); s.outNonZeroSamples = gOutNonZero;
    return s;
}

const int* leadHistogram() { return gLeadHist; }

}  // namespace mbox::stream
