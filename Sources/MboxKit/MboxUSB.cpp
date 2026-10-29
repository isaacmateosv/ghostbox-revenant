// MboxKit device lifetime and raw requests over IOKit.

#include "MboxKit.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <cstdlib>

struct MboxDevice {
    IOUSBDeviceInterface320** intf;
    MboxInfo info;
};

MboxDevice* mbox_open(void) {
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    if (!match) return nullptr;
    SInt32 vid = MBOX_VENDOR_ID, pid = MBOX_PRODUCT_ID;
    CFNumberRef v = CFNumberCreate(nullptr, kCFNumberSInt32Type, &vid);
    CFNumberRef p = CFNumberCreate(nullptr, kCFNumberSInt32Type, &pid);
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), v);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), p);
    CFRelease(v);
    CFRelease(p);
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, match);  // consumes match
    if (!service) return nullptr;

    IOCFPlugInInterface** plugin = nullptr;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
                                                         &plugin, &score);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || !plugin) return nullptr;
    IOUSBDeviceInterface320** intf = nullptr;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320), (LPVOID*)&intf);
    IODestroyPlugInInterface(plugin);
    if (!intf) return nullptr;

    MboxDevice* dev = (MboxDevice*)calloc(1, sizeof(MboxDevice));
    dev->intf = intf;
    (*intf)->GetDeviceReleaseNumber(intf, &dev->info.bcdDevice);
    UInt32 location = 0;
    (*intf)->GetLocationID(intf, &location);
    dev->info.locationID = location;
    return dev;
}

void mbox_close(MboxDevice* dev) {
    if (!dev) return;
    if (dev->intf) (*dev->intf)->Release(dev->intf);
    free(dev);
}

MboxInfo mbox_info(const MboxDevice* dev) {
    MboxInfo none = {0, 0};
    return dev ? dev->info : none;
}

int mbox_request(MboxDevice* dev, uint8_t bRequest, uint8_t bmRequestType, uint16_t wValue, uint16_t wIndex,
                 void* data, uint16_t length, uint32_t* lengthDone) {
    if (!dev || !dev->intf) return MBOX_ERR_NOT_FOUND;
    IOUSBDevRequestTO req = {};
    req.bmRequestType = bmRequestType;
    req.bRequest = bRequest;
    req.wValue = wValue;
    req.wIndex = wIndex;
    req.wLength = length;
    req.pData = data;
    req.noDataTimeout = 1000;
    req.completionTimeout = 1000;
    // A stalled control request clears itself on the next SETUP packet; no reset needed.
    IOReturn kr = (*dev->intf)->DeviceRequestTO(dev->intf, &req);
    if (lengthDone) *lengthDone = req.wLenDone;
    return kr == kIOReturnSuccess ? MBOX_OK : MBOX_ERR_IO;
}

int mbox_reenumerate(MboxDevice* dev) {
    if (!dev || !dev->intf) return MBOX_ERR_NOT_FOUND;
    IOReturn open = (*dev->intf)->USBDeviceOpen(dev->intf);
    if (open != kIOReturnSuccess && open != kIOReturnExclusiveAccess) return MBOX_ERR_IO;
    IOReturn kr = (*dev->intf)->USBDeviceReEnumerate(dev->intf, 0);
    if (open == kIOReturnSuccess) (*dev->intf)->USBDeviceClose(dev->intf);
    return kr == kIOReturnSuccess ? MBOX_OK : MBOX_ERR_IO;
}
