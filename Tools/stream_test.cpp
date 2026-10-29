// Mbox 3 streaming probe: captures from the isochronous IN endpoint (interface 3 alt 1, EP 0x81,
// 4 ch x 24-bit) and optionally plays a test tone on the OUT endpoint (interface 2 alt 1, EP 0x01).
// Usage: stream_test [seconds] [--tone]
// Prints per-channel peak levels and the measured sample rate.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

typedef IOUSBInterfaceInterface942 Intf;
static const CFUUIDBytes kIntfID = CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID942);

static const int kChannels = 4, kBytesPerFrame = kChannels * 3;
static const int kMicroframes = 64;       // per transfer (8 ms)
static const int kInFlight = 4;
static const int kMaxPacket = 156;

struct Xfer {
    Intf** intf; UInt8 pipe; bool in;
    std::vector<UInt8> buf;
    IOUSBLowLatencyIsocFrame frames[kMicroframes];
};

static double gPeak[kChannels];
static long gFrames = 0, gPackets = 0, gErrors = 0;
static UInt64 gNextIn = 0, gNextOut = 0;
static bool gTone = false;
static double gPhase = 0;
static int gOutFramesQueue[1 << 16]; static unsigned gQHead = 0, gQTail = 0;  // implicit feedback sizes
static bool gRunning = true;

static int32_t s24(const UInt8* p) { int32_t v = p[0] | (p[1] << 8) | (p[2] << 16); return (v << 8) >> 8; }

static void submit(Xfer* x);

static void callback(void* refcon, IOReturn result, void* arg0) {
    Xfer* x = (Xfer*)refcon;
    if (result != kIOReturnSuccess && result != kIOReturnUnderrun) gErrors++;
    if (x->in) {
        for (int f = 0; f < kMicroframes; f++) {
            int n = x->frames[f].frActCount, frames = n / kBytesPerFrame;
            const UInt8* p = x->buf.data() + f * kMaxPacket;
            for (int i = 0; i < frames; i++)
                for (int c = 0; c < kChannels; c++) {
                    double v = fabs(s24(p + i * kBytesPerFrame + c * 3) / 8388608.0);
                    if (v > gPeak[c]) gPeak[c] = v;
                }
            gFrames += frames; gPackets++;
            gOutFramesQueue[gQHead++ & 0xffff] = frames;  // OUT mirrors the IN packet sizes
        }
    }
    if (gRunning) submit(x);
}

static void submit(Xfer* x) {
    IOReturn kr;
    if (x->in) {
        for (int f = 0; f < kMicroframes; f++) { x->frames[f].frReqCount = kMaxPacket; x->frames[f].frActCount = 0; x->frames[f].frStatus = 0; }
        kr = (*x->intf)->LowLatencyReadIsochPipeAsync(x->intf, x->pipe, x->buf.data(), gNextIn, kMicroframes, 1, x->frames, callback, x);
        gNextIn += kMicroframes / 8;
    } else {
        UInt8* p = x->buf.data();  // OUT packets are packed back to back
        for (int f = 0; f < kMicroframes; f++) {
            int frames = (gQTail != gQHead) ? gOutFramesQueue[gQTail++ & 0xffff] : 6;
            for (int i = 0; i < frames; i++) {
                int32_t s = gTone ? (int32_t)(sin(gPhase) * 0.0316 * 8388607) : 0;  // -30 dBFS 440 Hz
                gPhase += 2 * M_PI * 440.0 / 48000.0;
                for (int c = 0; c < kChannels; c++) { p[i*12+c*3] = s & 0xff; p[i*12+c*3+1] = (s >> 8) & 0xff; p[i*12+c*3+2] = (s >> 16) & 0xff; }
            }
            p += frames * kBytesPerFrame;
            x->frames[f].frReqCount = frames * kBytesPerFrame; x->frames[f].frActCount = 0; x->frames[f].frStatus = 0;
        }
        kr = (*x->intf)->LowLatencyWriteIsochPipeAsync(x->intf, x->pipe, x->buf.data(), gNextOut, kMicroframes, 1, x->frames, callback, x);
        gNextOut += kMicroframes / 8;
    }
    if (kr != kIOReturnSuccess) { fprintf(stderr, "submit (%s) failed: 0x%x\n", x->in ? "in" : "out", kr); gRunning = false; }
}

static Intf** openInterface(io_service_t dev, int number, int alt, UInt8 epAddr, UInt8* pipeOut) {
    IOUSBFindInterfaceRequest req = {kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare};
    IOCFPlugInInterface** pi; SInt32 score;
    IOUSBDeviceInterface320** d;
    IOCreatePlugInInterfaceForService(dev, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &pi, &score);
    (*pi)->QueryInterface(pi, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320), (LPVOID*)&d);
    io_iterator_t it; (*d)->CreateInterfaceIterator(d, &req, &it);
    io_service_t s; Intf** intf = nullptr;
    while ((s = IOIteratorNext(it))) {
        IOCFPlugInInterface** ipi;
        if (IOCreatePlugInInterfaceForService(s, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &ipi, &score) == 0) {
            Intf** cand; (*ipi)->QueryInterface(ipi, kIntfID, (LPVOID*)&cand);
            UInt8 num; (*cand)->GetInterfaceNumber(cand, &num);
            if (num == number) intf = cand; else (*cand)->Release(cand);
        }
        IOObjectRelease(s);
        if (intf) break;
    }
    if (!intf) { fprintf(stderr, "interface %d not found\n", number); return nullptr; }
    IOReturn kr = (*intf)->USBInterfaceOpen(intf);
    if (kr) { fprintf(stderr, "open interface %d failed: 0x%x\n", number, kr); return nullptr; }
    kr = (*intf)->SetAlternateInterface(intf, alt);
    if (kr) { fprintf(stderr, "set alt %d on interface %d failed: 0x%x\n", alt, number, kr); return nullptr; }
    UInt8 n; (*intf)->GetNumEndpoints(intf, &n);
    for (UInt8 p = 1; p <= n; p++) {
        UInt8 dir, num, type, interval; UInt16 mps;
        (*intf)->GetPipeProperties(intf, p, &dir, &num, &type, &mps, &interval);
        if (((dir == kUSBIn) ? 0x80 : 0) + num == epAddr) { *pipeOut = p; printf("interface %d alt %d: pipe %d ep 0x%02x maxpkt %d\n", number, alt, p, epAddr, mps); }
    }
    CFRunLoopSourceRef src; (*intf)->CreateInterfaceAsyncEventSource(intf, &src);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopDefaultMode);
    return intf;
}

int main(int argc, char** argv) {
    double seconds = argc > 1 ? atof(argv[1]) : 5;
    for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--tone")) gTone = true;
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    int vid = 0x0dba, pid = 0x5000;
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), CFNumberCreate(0, kCFNumberSInt32Type, &vid));
    CFDictionarySetValue(m, CFSTR(kUSBProductID), CFNumberCreate(0, kCFNumberSInt32Type, &pid));
    io_service_t dev = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!dev) { puts("Mbox 3 not found"); return 1; }

    UInt8 inPipe = 0, outPipe = 0;
    Intf** in = openInterface(dev, 3, 1, 0x81, &inPipe);
    if (!in || !inPipe) return 1;
    Intf** out = gTone ? openInterface(dev, 2, 1, 0x01, &outPipe) : nullptr;
    if (gTone && (!out || !outPipe)) return 1;

    AbsoluteTime at; UInt64 frame; (*in)->GetBusFrameNumber(in, &frame, &at);
    gNextIn = frame + 4; gNextOut = frame + 6;
    std::vector<Xfer> xin(kInFlight), xout(kInFlight);
    for (auto& x : xin) { x.intf = in; x.pipe = inPipe; x.in = true; x.buf.resize(kMicroframes * kMaxPacket); submit(&x); }
    if (out) for (auto& x : xout) { x.intf = out; x.pipe = outPipe; x.in = false; x.buf.resize(kMicroframes * kMaxPacket); submit(&x); }

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
    gRunning = false;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    (*in)->SetAlternateInterface(in, 0); (*in)->USBInterfaceClose(in);
    if (out) { (*out)->SetAlternateInterface(out, 0); (*out)->USBInterfaceClose(out); }

    printf("packets %ld, frames %ld -> %.1f Hz, transfer errors %ld\n", gPackets, gFrames, gFrames / seconds, gErrors);
    for (int c = 0; c < kChannels; c++)
        printf("  capture ch %d peak %.4f (%.1f dBFS)\n", c + 1, gPeak[c], gPeak[c] > 0 ? 20 * log10(gPeak[c]) : -999.0);
    return 0;
}
