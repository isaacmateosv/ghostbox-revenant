#include <iostream>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>
#include <cmath>
#include <algorithm>
#include <cstdlib>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreAudio/CoreAudio.h>

#define AVID_VENDOR_ID   0x0dba
#define MBOX3_PRODUCT_ID 0x5000

IOUSBDeviceInterface320** findMboxDevice(UInt16* outBcdDevice = nullptr) {
    CFMutableDictionaryRef matchingDict = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matchingDict) return nullptr;

    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iter) != KERN_SUCCESS)
        return nullptr;

    io_service_t device;
    IOUSBDeviceInterface320** dev = nullptr;

    while ((device = IOIteratorNext(iter))) {
        IOCFPlugInInterface** plugIn = nullptr;
        SInt32 score;
        kern_return_t kr = IOCreatePlugInInterfaceForService(
            device, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugIn, &score);
        IOObjectRelease(device);
        if (kr != kIOReturnSuccess || !plugIn) continue;

        IOUSBDeviceInterface320** candidate = nullptr;
        (*plugIn)->QueryInterface(plugIn, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320), (LPVOID*)&candidate);
        (*plugIn)->Release(plugIn);
        if (!candidate) continue;

        UInt16 vid = 0, pid = 0, bcd = 0;
        (*candidate)->GetDeviceVendor(candidate, &vid);
        (*candidate)->GetDeviceProduct(candidate, &pid);
        (*candidate)->GetDeviceReleaseNumber(candidate, &bcd);

        if (vid == AVID_VENDOR_ID && pid == MBOX3_PRODUCT_ID) {
            if (outBcdDevice) *outBcdDevice = bcd;
            dev = candidate;
            break;
        }
        (*candidate)->Release(candidate);
    }
    IOObjectRelease(iter);
    return dev;
}

IOReturn mboxMsg(IOUSBDeviceInterface320** dev, UInt8 bRequest, UInt8 bmRequestType,
                 UInt16 wValue, UInt16 wIndex, void* data, UInt16 wLength, UInt32* outLenDone = nullptr) {
    IOUSBDevRequestTO req;
    req.bmRequestType = bmRequestType;
    req.bRequest = bRequest;
    req.wValue = wValue;
    req.wIndex = wIndex;
    req.wLength = wLength;
    req.pData = data;
    req.wLenDone = 0;
    req.noDataTimeout = 2000;
    req.completionTimeout = 2000;
    // A stalled control request clears itself on the next SETUP packet; no reset needed.
    IOReturn kr = (*dev)->DeviceRequestTO(dev, &req);
    if (outLenDone) *outLenDone = req.wLenDone;
    return kr;
}

void pctToMboxVol(int pct, UInt8 out[2]) {
    if (pct <= 0) {
        out[0] = 0x00;
        out[1] = 0x80;
        return;
    }
    if (pct >= 100) {
        out[0] = 0x00;
        out[1] = 0x00;
        return;
    }
    double norm = pct / 100.0;
    double db = 20.0 * std::log10(norm);
    if (pct < 15) {
        db = -60.0 + (pct / 15.0) * 25.0;
    }
    int32_t raw = static_cast<int32_t>(std::round(db * 256.0));
    raw = (raw / 64) * 64;
    if (raw < -15360) raw = -15360;
    if (raw > 0) raw = 0;
    uint16_t uval = static_cast<uint16_t>(static_cast<int16_t>(raw));
    out[0] = static_cast<UInt8>(uval & 0xFF);
    out[1] = static_cast<UInt8>((uval >> 8) & 0xFF);
}

IOReturn initializeMboxRate(IOUSBDeviceInterface320** dev, uint32_t sampleRate, bool spdifClock) {
    if (sampleRate != 44100 && sampleRate != 48000 && sampleRate != 88200 && sampleRate != 96000) {
        sampleRate = 48000;
    }
    UInt8 clkOut = spdifClock ? 0x02 : 0x01;
    IOReturn kr = mboxMsg(dev, 0x01, 0x21, 0x0100, 0x8001, &clkOut, 1);
    UInt8 clkIn = 0;
    mboxMsg(dev, 0x01, 0xA1, 0x0100, 0x8001, &clkIn, 1);

    if (spdifClock) {
        for (int i = 0; i < 64; i++) {
            UInt8 valid = 0;
            UInt32 done = 0;
            if (mboxMsg(dev, 0x01, 0xA1, 0x0200, 0x8201, &valid, 1, &done) == kIOReturnSuccess && done == 1 && valid != 0) {
                break;
            }
            usleep(5000);
        }
    } else {
        UInt8 rateBytes[4] = {
            static_cast<UInt8>(sampleRate & 0xFF),
            static_cast<UInt8>((sampleRate >> 8) & 0xFF),
            static_cast<UInt8>((sampleRate >> 16) & 0xFF),
            0x00
        };
        kr |= mboxMsg(dev, 0x01, 0x21, 0x0100, 0x8101, rateBytes, 4);
    }
    UInt8 readRate[4] = {0};
    UInt16 rateIdx = spdifClock ? 0x8201 : 0x8101;
    mboxMsg(dev, 0x01, 0xA1, 0x0100, rateIdx, readRate, 4);
    return kr;
}

void setupDefaults(IOUSBDeviceInterface320** dev) {
    UInt8 b1[1];
    UInt8 mute[2]  = {0x00, 0x80};
    UInt8 unity[2] = {0x00, 0x00};

    b1[0] = 0x00;
    mboxMsg(dev, 0x01, 0x21, 0x0003, 0x2001, b1, 1);
    initializeMboxRate(dev, 48000, false);
    b1[0] = 0x02;
    mboxMsg(dev, 0x03, 0x21, 0x0000, 0x2001, b1, 1);

    for (UInt16 wv = 0x0110; wv <= 0x011f; wv++) {
        mboxMsg(dev, 0x01, 0x21, wv, 0x4001, mute, 2);
    }
    for (UInt16 wv = 0x0100; wv <= 0x010f; wv++) {
        bool isUnity = (wv == 0x0100 || wv == 0x0105 || wv == 0x010a || wv == 0x010f);
        mboxMsg(dev, 0x01, 0x21, wv, 0x4001, isUnity ? unity : mute, 2);
    }
    for (UInt16 wv = 0x0120; wv <= 0x0123; wv++) {
        mboxMsg(dev, 0x01, 0x21, wv, 0x4001, mute, 2);
    }
    for (UInt16 wv = 0x0100; wv <= 0x0107; wv++) {
        mboxMsg(dev, 0x01, 0x21, wv, 0x4201, mute, 2);
    }

    b1[0] = 0x00;
    mboxMsg(dev, 0x03, 0x21, 0x0002, 0x2001, b1, 1);
    mboxMsg(dev, 0x03, 0x21, 0x0001, 0x2001, b1, 1);
    b1[0] = 0x05;
    mboxMsg(dev, 0x03, 0x21, 0x0005, 0x2001, b1, 1);
    b1[0] = 0x01;
    mboxMsg(dev, 0x03, 0x21, 0x0004, 0x2001, b1, 1);

    b1[0] = 0x00;
    UInt8 zero2[2] = {0x00, 0x00};
    mboxMsg(dev, 0x01, 0x21, 0x0200, 0x4301, b1, 1);
    mboxMsg(dev, 0x01, 0x21, 0x0400, 0x4301, zero2, 2);
    mboxMsg(dev, 0x01, 0x21, 0x0500, 0x4301, b1, 1);
    mboxMsg(dev, 0x01, 0x21, 0x0300, 0x4301, b1, 1);
}

// With the Mbox 3 Core Audio driver installed, Core Audio owns the sample rate: set it like Audio MIDI Setup
// does and let the driver program the hardware.
static int setCoreAudioRate(Float64 rate) {
    CFStringRef uid = CFSTR("Mbox3:0dba:5000");
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    AudioObjectPropertyAddress tr = {kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    OSStatus err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &tr, sizeof(uid), &uid, &size, &dev);
    if (err || dev == kAudioObjectUnknown) {
        std::cout << "{\"ok\":false,\"cmd\":\"ca-rate\",\"error\":\"Mbox 3 not available in Core Audio\"}\n";
        return 1;
    }
    AudioObjectPropertyAddress ra = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    err = AudioObjectSetPropertyData(dev, &ra, 0, nullptr, sizeof(rate), &rate);
    std::cout << "{\"ok\":" << (err == noErr ? "true" : "false") << ",\"cmd\":\"ca-rate\",\"rate\":" << rate
              << ",\"status\":" << err << "}\n";
    return err == noErr ? 0 : 1;
}

int main(int argc, char* argv[]) {
    if (argc >= 3 && std::string(argv[1]) == "ca-rate") return setCoreAudioRate(std::stod(argv[2]));

    UInt16 bcdDevice = 0;
    IOUSBDeviceInterface320** dev = findMboxDevice(&bcdDevice);
    if (!dev) {
        std::cout << "{\"ok\":false,\"connected\":false,\"error\":\"Avid Mbox 3 not connected\"}\n";
        return 1;
    }

    if (argc < 2 || std::string(argv[1]) == "status") {
        UInt8 clkIn = 0;
        mboxMsg(dev, 0x01, 0xA1, 0x0100, 0x8001, &clkIn, 1);
        UInt8 rateBuf[4] = {0};
        mboxMsg(dev, 0x01, 0xA1, 0x0100, (clkIn == 2) ? 0x8201 : 0x8101, rateBuf, 4);
        uint32_t rate = rateBuf[0] | (rateBuf[1] << 8) | (rateBuf[2] << 16);
        (*dev)->Release(dev);
        std::cout << "{\"ok\":true,\"connected\":true,\"vid\":\"0x0dba\",\"pid\":\"0x5000\",\"bcdDevice\":\"0x"
                  << std::hex << bcdDevice << std::dec << "\",\"clockSource\":" << (int)clkIn
                  << ",\"sampleRate\":" << rate << "}\n";
        return 0;
    }

    std::string cmd = argv[1];
    IOReturn kr = kIOReturnSuccess;

    if (cmd == "init") {
        setupDefaults(dev);
    } else if (cmd == "meters") {
        UInt8 buf[30] = {0};
        UInt32 done = 0;
        kr = mboxMsg(dev, 0x03, 0xA1, 0x0010, 0x2001, buf, 30, &done);
        std::cout << "{\"ok\":" << ((kr == kIOReturnSuccess && done == 30) ? "true" : "false")
                  << ",\"bytes\":" << done << ",\"raw\":[";
        for (int i = 0; i < 15; i++) {
            uint16_t v = buf[i * 2] | (static_cast<uint16_t>(buf[i * 2 + 1]) << 8);
            std::cout << v << (i < 14 ? "," : "");
        }
        std::cout << "]}\n";
        (*dev)->Release(dev);
        return (kr == kIOReturnSuccess && done == 30) ? 0 : 1;
    } else if (cmd == "regs") {
        // Soft-button / panel state registers at 0x2001, offsets 0..5
        const char* names[6] = {"host_ctrl", "mono", "dim", "tuner", "led_dim", "hold"};
        std::cout << "{\"ok\":true";
        for (UInt16 i = 0; i < 6; i++) {
            UInt8 v = 0;
            UInt32 done = 0;
            IOReturn r = mboxMsg(dev, 0x03, 0xA1, i, 0x2001, &v, 1, &done);
            std::cout << ",\"" << names[i] << "\":";
            if (r == kIOReturnSuccess && done == 1) std::cout << (int)v; else std::cout << "null";
        }
        std::cout << "}\n";
        (*dev)->Release(dev);
        return 0;
    } else if (cmd == "get" && argc >= 6) {
        // Read-only register probe: get <bRequest> <wValue> <wIndex> <len>
        UInt8 bReq = static_cast<UInt8>(std::stoul(argv[2], nullptr, 0));
        UInt16 wValue = static_cast<UInt16>(std::stoul(argv[3], nullptr, 0));
        UInt16 wIndex = static_cast<UInt16>(std::stoul(argv[4], nullptr, 0));
        UInt16 len = static_cast<UInt16>(std::min(64UL, std::stoul(argv[5], nullptr, 0)));
        UInt8 buf[64] = {0};
        UInt32 done = 0;
        kr = mboxMsg(dev, bReq, 0xA1, wValue, wIndex, buf, len, &done);
        std::cout << "{\"ok\":" << (kr == kIOReturnSuccess ? "true" : "false")
                  << ",\"status\":\"0x" << std::hex << kr << std::dec << "\",\"bytes\":" << done << ",\"data\":[";
        for (UInt32 i = 0; i < done; i++) std::cout << (int)buf[i] << (i + 1 < done ? "," : "");
        std::cout << "]}\n";
        (*dev)->Release(dev);
        return kr == kIOReturnSuccess ? 0 : 1;
    } else if (cmd == "sample-rate" && argc >= 3) {
        uint32_t sr = static_cast<uint32_t>(std::stoul(argv[2]));
        bool spdif = (argc >= 4 && std::string(argv[3]) == "spdif");
        kr = initializeMboxRate(dev, sr, spdif);
    } else if (cmd == "reenumerate") {
        // Software replug: the Mbox drops off the bus and comes back, like pulling the USB cable
        kr = (*dev)->USBDeviceOpen(dev);
        if (kr == kIOReturnSuccess || kr == kIOReturnExclusiveAccess) {
            IOReturn r = (*dev)->USBDeviceReEnumerate(dev, 0);
            if (kr == kIOReturnSuccess) (*dev)->USBDeviceClose(dev);
            kr = r;
        }
    } else if (cmd == "clock-source" && argc >= 3) {
        // Selector only; the rate stays as it is (Core Audio owns it when the driver is installed)
        bool spdif = (std::string(argv[2]) == "spdif" || std::string(argv[2]) == "2");
        UInt8 sel = spdif ? 0x02 : 0x01;
        kr = mboxMsg(dev, 0x01, 0x21, 0x0100, 0x8001, &sel, 1);
        if (spdif) {
            for (int i = 0; i < 64; i++) {
                UInt8 valid = 0; UInt32 done = 0;
                if (mboxMsg(dev, 0x01, 0xA1, 0x0200, 0x8201, &valid, 1, &done) == kIOReturnSuccess && done == 1 && valid) break;
                usleep(5000);
            }
        }
    } else if (cmd == "clock" && argc >= 3) {
        bool spdif = (std::string(argv[2]) == "spdif" || std::string(argv[2]) == "2");
        uint32_t sr = (argc >= 4) ? static_cast<uint32_t>(std::stoul(argv[3])) : 48000;
        kr = initializeMboxRate(dev, sr, spdif);
    } else if (cmd == "batch" && argc >= 3) {
        UInt8 gate = 0x02;
        mboxMsg(dev, 0x03, 0x21, 0x0000, 0x2001, &gate, 1);
        for (int i = 2; i < argc; i++) {
            std::string item(argv[i]);
            size_t p1 = item.find(':');
            size_t p2 = item.find(':', p1 + 1);
            if (p1 == std::string::npos || p2 == std::string::npos) continue;
            UInt16 wIndex = static_cast<UInt16>(std::stoul(item.substr(0, p1), nullptr, 0));
            UInt16 wValue = static_cast<UInt16>(std::stoul(item.substr(p1 + 1, p2 - p1 - 1), nullptr, 0));
            int pct = std::stoi(item.substr(p2 + 1));
            UInt8 buf[2];
            pctToMboxVol(pct, buf);
            kr |= mboxMsg(dev, 0x01, 0x21, wValue, wIndex, buf, 2);
        }
    } else if (cmd == "tuner" && argc >= 3) {
        UInt8 v = std::stoi(argv[2]) ? 0x01 : 0x00;
        kr = mboxMsg(dev, 0x01, 0x21, 0x0003, 0x2001, &v, 1);
    } else if (cmd == "mono" && argc >= 3) {
        UInt8 v = std::stoi(argv[2]) ? 0x01 : 0x00;
        kr = mboxMsg(dev, 0x03, 0x21, 0x0001, 0x2001, &v, 1);
    } else if (cmd == "dim" && argc >= 3) {
        UInt8 v = std::stoi(argv[2]) ? 0x01 : 0x00;
        kr = mboxMsg(dev, 0x03, 0x21, 0x0002, 0x2001, &v, 1);
    } else if (cmd == "host-ctrl" && argc >= 3) {
        UInt8 v = static_cast<UInt8>(std::stoi(argv[2], nullptr, 0));
        kr = mboxMsg(dev, 0x03, 0x21, 0x0000, 0x2001, &v, 1);
    } else if (cmd == "led-dim" && argc >= 3) {
        UInt8 v = std::stoi(argv[2]) ? 0x01 : 0x00;
        kr = mboxMsg(dev, 0x03, 0x21, 0x0004, 0x2001, &v, 1);
    } else if (cmd == "hold-duration" && argc >= 3) {
        UInt8 v = static_cast<UInt8>(std::stoi(argv[2], nullptr, 0));
        kr = mboxMsg(dev, 0x03, 0x21, 0x0005, 0x2001, &v, 1);
    } else if (cmd == "hw-in" && argc >= 5) {
        int ch = std::stoi(argv[2]);
        bool right = (std::string(argv[3]) == "R" || std::string(argv[3]) == "r" || std::string(argv[3]) == "1");
        int pct = std::stoi(argv[4]);
        bool spdifBus = (argc >= 6 && std::string(argv[5]) == "spdif");
        UInt16 base = spdifBus ? 0x0112 : 0x0110;
        UInt16 wValue = base + ((ch - 1) * 4) + (right ? 1 : 0);
        UInt8 buf[2];
        pctToMboxVol(pct, buf);
        kr = mboxMsg(dev, 0x01, 0x21, wValue, 0x4001, buf, 2);
    } else if (cmd == "sw-ret" && argc >= 5) {
        int ch = std::stoi(argv[2]);
        bool right = (std::string(argv[3]) == "R" || std::string(argv[3]) == "r" || std::string(argv[3]) == "1");
        int pct = std::stoi(argv[4]);
        bool spdifBus = (argc >= 6 && std::string(argv[5]) == "spdif");
        UInt16 base = spdifBus ? 0x0102 : 0x0100;
        UInt16 wValue = base + ((ch - 1) * 4) + (right ? 1 : 0);
        UInt8 buf[2];
        pctToMboxVol(pct, buf);
        kr = mboxMsg(dev, 0x01, 0x21, wValue, 0x4001, buf, 2);
    } else if (cmd == "fx-send" && argc >= 5) {
        bool isHw = (std::string(argv[2]) == "hw");
        int ch = std::stoi(argv[3]);
        int pct = std::stoi(argv[4]);
        UInt16 wValue = (isHw ? 0x0104 : 0x0100) + (ch - 1);
        UInt8 buf[2];
        pctToMboxVol(pct, buf);
        kr = mboxMsg(dev, 0x01, 0x21, wValue, 0x4201, buf, 2);
    } else if (cmd == "fx-ret" && argc >= 4) {
        bool right = (std::string(argv[2]) == "R" || std::string(argv[2]) == "r" || std::string(argv[2]) == "1");
        int pct = std::stoi(argv[3]);
        bool spdifBus = (argc >= 5 && std::string(argv[4]) == "spdif");
        UInt16 base = spdifBus ? 0x0122 : 0x0120;
        UInt16 wValue = base + (right ? 1 : 0);
        UInt8 buf[2];
        pctToMboxVol(pct, buf);
        kr = mboxMsg(dev, 0x01, 0x21, wValue, 0x4001, buf, 2);
    } else if (cmd == "dsp" && argc >= 6) {
        UInt8 preset = static_cast<UInt8>(std::stoi(argv[2]));
        UInt8 vol    = static_cast<UInt8>(std::stoi(argv[3]));
        uint16_t dur = static_cast<uint16_t>(std::stoi(argv[4]));
        UInt8 fb     = static_cast<UInt8>(std::stoi(argv[5]));
        UInt8 durBuf[2] = { static_cast<UInt8>(dur & 0xFF), static_cast<UInt8>((dur >> 8) & 0xFF) };

        kr  = mboxMsg(dev, 0x01, 0x21, 0x0200, 0x4301, &preset, 1);
        kr |= mboxMsg(dev, 0x01, 0x21, 0x0300, 0x4301, &vol, 1);
        kr |= mboxMsg(dev, 0x01, 0x21, 0x0400, 0x4301, durBuf, 2);
        kr |= mboxMsg(dev, 0x01, 0x21, 0x0500, 0x4301, &fb, 1);
    } else {
        kr = kIOReturnBadArgument;
    }

    (*dev)->Release(dev);
    std::cout << "{\"ok\":" << (kr == kIOReturnSuccess ? "true" : "false")
              << ",\"cmd\":\"" << cmd << "\",\"status\":\"0x" << std::hex << kr << std::dec << "\"}\n";
    return kr == kIOReturnSuccess ? 0 : 1;
}
