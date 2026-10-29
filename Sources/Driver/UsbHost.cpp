#include "UsbHost.h"

#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <pthread.h>

#include "DriverState.h"
#include "HardwareClock.h"
#include "IsochStream.h"
#include "ObjectModel.h"

namespace mbox::usb {
namespace {

CFRunLoopRef gRunLoop = nullptr;
IONotificationPortRef gNotifyPort = nullptr;
io_service_t gService = IO_OBJECT_NULL;     // non-null while the Mbox is attached
IOUSBDeviceInterface320** gDevice = nullptr;

// The device object always exists; plugging the Mbox in or out only flips DeviceIsAlive.
// (Announcing device-list changes made coreaudiod's proxy-list reconcile spin forever at 100% CPU.)
void deviceAttached(void*, io_iterator_t it) {
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        if (gService) { IOObjectRelease(s); continue; }
        IOCFPlugInInterface** pi = nullptr;
        SInt32 score;
        IOUSBDeviceInterface320** dev = nullptr;
        if (IOCreatePlugInInterfaceForService(s, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &pi, &score) == 0 && pi) {
            (*pi)->QueryInterface(pi, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320), (LPVOID*)&dev);
            IODestroyPlugInInterface(pi);
        }
        if (!dev) {
            os_log_error(driverLog(), "cannot open Mbox 3 device user client");
            IOObjectRelease(s);
            continue;
        }
        gDevice = dev;
        gService = s;
        // First load: adopt the hardware rate (the HAL has not read it yet). Re-attach: the HAL and apps already
        // run at the nominal rate, so program the hardware to match. No lock: StartIO may wait on this thread.
        hw::enforce(!gState.hostReady);
        gState.devicePresent = true;
        os_log(driverLog(), "Mbox 3 attached (%.0f Hz)", gState.sampleRate.load());
        if (gState.ioClients > 0) stream::start();  // apps kept IO open across an unplug
        model::notifyDeviceAliveChanged();
    }
}

void deviceDetached(void*, io_iterator_t it) {
    io_service_t s;
    bool gone = false;
    while ((s = IOIteratorNext(it))) {
        if (gService && IOObjectIsEqualTo(s, gService)) gone = true;
        IOObjectRelease(s);
    }
    if (!gone) return;
    stream::stop();
    if (gDevice) { (*gDevice)->Release(gDevice); gDevice = nullptr; }
    IOObjectRelease(gService);
    gService = IO_OBJECT_NULL;
    gState.devicePresent = false;
    os_log(driverLog(), "Mbox 3 detached");
    model::notifyDeviceAliveChanged();
}

void addMatching(const io_name_t type, IOServiceMatchingCallback callback) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    SInt32 vid = MBOX_VENDOR_ID, pid = MBOX_PRODUCT_ID;
    CFNumberRef v = CFNumberCreate(nullptr, kCFNumberSInt32Type, &vid), p = CFNumberCreate(nullptr, kCFNumberSInt32Type, &pid);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), v);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), p);
    CFRelease(v);
    CFRelease(p);
    io_iterator_t it;
    IOServiceAddMatchingNotification(gNotifyPort, type, m, callback, nullptr, &it);  // consumes m
    callback(nullptr, it);  // handle devices already present and arm the notification
}

void* threadMain(void* ready) {
    pthread_setname_np("GhostBox Revenant USB");
    gRunLoop = CFRunLoopGetCurrent();
    CFRetain(gRunLoop);
    gNotifyPort = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(gRunLoop, IONotificationPortGetRunLoopSource(gNotifyPort), kCFRunLoopDefaultMode);
    addMatching(kIOFirstMatchNotification, deviceAttached);
    addMatching(kIOTerminatedNotification, deviceDetached);
    hw::startFollowingSpdif();
    dispatch_semaphore_signal((dispatch_semaphore_t)ready);
    CFRunLoopRun();
    return nullptr;
}

}  // namespace

void start() {
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    pthread_t t;
    pthread_create(&t, nullptr, threadMain, (void*)ready);
    pthread_detach(t);
    dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
}

CFRunLoopRef runLoop() { return gRunLoop; }

bool onThread() { return gRunLoop && CFRunLoopGetCurrent() == gRunLoop; }

void perform(void (^block)(void)) {
    if (onThread()) { block(); return; }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    CFRunLoopPerformBlock(gRunLoop, kCFRunLoopDefaultMode, ^{ block(); dispatch_semaphore_signal(done); });
    CFRunLoopWakeUp(gRunLoop);
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
}

void performAsync(void (^block)(void)) {
    CFRunLoopPerformBlock(gRunLoop, kCFRunLoopDefaultMode, block);
    CFRunLoopWakeUp(gRunLoop);
}

IOUSBDeviceInterface320** device() { return gDevice; }

IOReturn controlRequest(UInt8 type, UInt8 request, UInt16 value, UInt16 index, void* data, UInt16 length) {
    if (!gDevice) return kIOReturnNotAttached;
    IOUSBDevRequestTO r = {};
    r.bmRequestType = type; r.bRequest = request; r.wValue = value; r.wIndex = index;
    r.wLength = length; r.pData = data; r.noDataTimeout = 1000; r.completionTimeout = 1000;
    return (*gDevice)->DeviceRequestTO(gDevice, &r);
}

void setRealtimePriority() {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double msTicks = 1e6 * tb.denom / tb.numer;
    thread_time_constraint_policy_data_t pol;
    pol.period = (uint32_t)(msTicks);
    pol.computation = (uint32_t)(msTicks * 0.2);
    pol.constraint = (uint32_t)(msTicks * 0.6);
    pol.preemptible = 1;
    thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
                      (thread_policy_t)&pol, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

}  // namespace mbox::usb
