// UsbHost: the driver's USB thread. Every USB call and callback happens on its run loop: hot-plug
// notifications, control requests, isochronous completions and the S/PDIF follow timer.

#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/usb/IOUSBLib.h>

namespace mbox::usb {

// Starts the thread, matches the Mbox (attach handling runs before this returns) and starts its timers.
void start();

// Runs `block` on the USB thread and waits for it (at most 3 s). Runs inline when already on the thread.
void perform(void (^block)(void));
// Queues `block` on the USB thread without waiting.
void performAsync(void (^block)(void));

CFRunLoopRef runLoop();
bool onThread();

// The attached Mbox (USB thread only), or null.
IOUSBDeviceInterface320** device();

// Class request on the control pipe (USB thread only).
IOReturn controlRequest(UInt8 type, UInt8 request, UInt16 value, UInt16 index, void* data, UInt16 length);

// Real-time scheduling for the calling thread (the USB thread while streaming).
void setRealtimePriority();

}  // namespace mbox::usb
