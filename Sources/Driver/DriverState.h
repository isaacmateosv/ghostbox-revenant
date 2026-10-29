// Driver-wide state shared by the plug-in interface, the object model, the USB thread and the stream.

#pragma once

#include <os/log.h>
#include <pthread.h>
#include <atomic>

#include "DriverConfig.h"

namespace mbox {

struct DriverState {
    AudioServerPlugInHostRef host = nullptr;
    std::atomic<bool> hostReady{false};        // Initialize finished: the HAL has seen the device
    std::atomic<Float64> sampleRate{48000};    // nominal rate, owned by Core Audio
    std::atomic<UInt32> latencyMode{MBOX_LATENCY_SAFE};
    std::atomic<bool> devicePresent{false};    // the Mbox is attached
    std::atomic<bool> clockIsSpdif{false};     // the S/PDIF clock is selected, so the source sets the rate
    std::atomic<UInt32> ioClients{0};          // StartIO count, changed under ioMutex
    pthread_mutex_t ioMutex = PTHREAD_MUTEX_INITIALIZER;
    double hostTicksPerSecond = 0;
};

extern DriverState gState;

os_log_t driverLog();

inline const LatencyProfile& latency() {
    UInt32 m = gState.latencyMode.load();
    return kLatencyProfiles[m < MBOX_LATENCY_MODES ? m : MBOX_LATENCY_SAFE];
}

inline UInt32 inputSafetyOffset() { return (UInt32)(gState.sampleRate.load() / 1000.0 * latency().inSafetyMs); }
inline UInt32 outputSafetyOffset() {
    return (UInt32)(gState.sampleRate.load() / 1000.0 * (latency().outLeadMs + latency().outMarginMs));
}

}  // namespace mbox
