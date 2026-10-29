#include "HardwareClock.h"

#include <dispatch/dispatch.h>

#include "DriverState.h"
#include "UsbHost.h"

namespace mbox::hw {
namespace {

IOReturn getCur(UInt16 control, UInt16 unit, void* data, UInt16 length) {
    return usb::controlRequest(MBOX_RT_GET, MBOX_REQ_CUR, control, unit, data, length);
}

IOReturn setCur(UInt16 control, UInt16 unit, void* data, UInt16 length) {
    return usb::controlRequest(MBOX_RT_SET, MBOX_REQ_CUR, control, unit, data, length);
}

Float64 gLastSpdifRequest = 0;

void requestConfigChangeAsync(UInt64 action) {
    // Never call into the host from the USB thread: PerformDeviceConfigurationChange waits on this thread
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (gState.host) gState.host->RequestDeviceConfigurationChange(gState.host, kObjDevice, action, nullptr);
    });
}

void followSpdif(CFRunLoopTimerRef, void*) {
    if (!usb::device() || !gState.hostReady) return;
    bool spdif = clockSelector() == MBOX_CLOCK_SPDIF;
    gState.clockIsSpdif = spdif;
    if (!spdif || !spdifClockValid()) { gLastSpdifRequest = 0; return; }
    Float64 ext = readRate();
    if (ext > 0 && ext != gState.sampleRate.load() && ext != gLastSpdifRequest) {
        gLastSpdifRequest = ext;
        os_log(driverLog(), "S/PDIF source runs at %.0f Hz, following it", ext);
        requestConfigChangeAsync((UInt64)ext);
    }
}

}  // namespace

UInt8 clockSelector() {
    UInt8 c = 0;
    return getCur(MBOX_CLOCK_CTL_SELECTOR, MBOX_UNIT_CLOCK_SELECTOR, &c, 1) == kIOReturnSuccess ? c : 0;
}

bool spdifClockValid() {
    UInt8 v = 0;
    return getCur(MBOX_CLOCK_CTL_VALID, MBOX_UNIT_CLOCK_SPDIF, &v, 1) == kIOReturnSuccess && v;
}

Float64 readRate() {
    UInt8 clk = clockSelector();
    UInt8 b[4] = {0};
    UInt16 unit = clk == MBOX_CLOCK_SPDIF ? MBOX_UNIT_CLOCK_SPDIF : MBOX_UNIT_CLOCK_INTERNAL;
    if (getCur(MBOX_CLOCK_CTL_RATE, unit, b, 4) != kIOReturnSuccess) return 0;
    UInt32 rate = b[0] | (b[1] << 8) | (b[2] << 16) | ((UInt32)b[3] << 24);
    return isSupportedRate(rate) ? rate : 0;
}

void writeRate(Float64 rate) {
    UInt32 r = (UInt32)rate;
    UInt8 b[4] = {(UInt8)r, (UInt8)(r >> 8), (UInt8)(r >> 16), 0};
    setCur(MBOX_CLOCK_CTL_RATE, MBOX_UNIT_CLOCK_INTERNAL, b, 4);
}

void enforce(bool adoptRate) {
    if (clockSelector() == MBOX_CLOCK_SPDIF && !spdifClockValid()) {
        // The Mbox 3 powers up on S/PDIF; without an S/PDIF signal it disables streaming entirely
        os_log(driverLog(), "S/PDIF clock selected but not valid, switching to the internal clock");
        UInt8 internal = MBOX_CLOCK_INTERNAL;
        setCur(MBOX_CLOCK_CTL_SELECTOR, MBOX_UNIT_CLOCK_SELECTOR, &internal, 1);
    }
    Float64 hwRate = readRate(), nominal = gState.sampleRate.load();
    if (adoptRate) {
        if (hwRate > 0) gState.sampleRate = hwRate;
    } else if (hwRate != nominal && clockSelector() == MBOX_CLOCK_INTERNAL) {
        os_log(driverLog(), "hardware rate %.0f differs from Core Audio's %.0f, restoring", hwRate, nominal);
        writeRate(nominal);
    }
}

void startFollowingSpdif() {
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(nullptr, CFAbsoluteTimeGetCurrent() + 1, 1.0, 0, 0, followSpdif, nullptr);
    CFRunLoopAddTimer(usb::runLoop(), timer, kCFRunLoopDefaultMode);
}

}  // namespace mbox::hw
