// MboxKit: control-path access to the Avid Mbox 3 (3rd generation, USB 0dba:5000), plus the Core Audio client
// calls for the Mbox 3 driver. C API, used by mbox3-ctl and the Swift app. The protocol itself (register map,
// units, meter layout) is documented in ../Shared/MboxProtocol.h.
//
//   MboxUSB.cpp        device lifetime and raw requests
//   MboxControl.cpp    registers, meters, mixer, effect, clock
//   MboxCoreAudio.cpp  the Core Audio side: driver presence, sample rate, latency mode

#ifndef MBOXKIT_H
#define MBOXKIT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "../Shared/MboxProtocol.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MboxDevice MboxDevice;

enum {
    MBOX_OK = 0,
    MBOX_ERR_NOT_FOUND = -1,
    MBOX_ERR_IO = -2,           // request failed (device gone, stalled, timed out)
    MBOX_ERR_ARG = -3,
    MBOX_ERR_UNSUPPORTED = -4,  // e.g. an older driver without latency modes
};

typedef struct {
    uint16_t bcdDevice;      // firmware, e.g. 0x0108
    uint32_t locationID;     // USB location, changes when moved to another port
} MboxInfo;

typedef struct {
    int16_t llm, mono, dim, tuner, ledDim, hold;   // -1 when the read failed
} MboxRegs;

// MARK: Device (MboxUSB.cpp)

// mbox_open returns NULL when no Mbox 3 is attached.
MboxDevice* mbox_open(void);
void mbox_close(MboxDevice* dev);
MboxInfo mbox_info(const MboxDevice* dev);

// Raw class/vendor request (bmRequestType MBOX_RT_SET or MBOX_RT_GET).
int mbox_request(MboxDevice* dev, uint8_t bRequest, uint8_t bmRequestType, uint16_t wValue, uint16_t wIndex,
                 void* data, uint16_t length, uint32_t* lengthDone);

// Software replug: the Mbox drops off the bus and re-enumerates.
int mbox_reenumerate(MboxDevice* dev);

// MARK: Controls (MboxControl.cpp)

int mbox_read_regs(MboxDevice* dev, MboxRegs* out);
int mbox_write_reg(MboxDevice* dev, uint8_t reg, uint8_t value);
int mbox_read_meters(MboxDevice* dev, uint16_t out[MBOX_METER_COUNT]);

// Mixer levels: 0 = muted, 100 = unity (0 dB), fractions allowed; the taper the panel faders use.
// mbox_level_to_db returns the gain the hardware receives (muted as -999). The pct versions take whole percents.
void mbox_level_to_gain(double level, uint8_t out[2]);
double mbox_level_to_db(double level);
int mbox_set_mix_level(MboxDevice* dev, uint16_t wIndex, uint16_t wValue, double level);
void mbox_pct_to_gain(int pct, uint8_t out[2]);
double mbox_pct_to_db(int pct);
int mbox_set_mix(MboxDevice* dev, uint16_t wIndex, uint16_t wValue, int pct);
int mbox_set_effect(MboxDevice* dev, int preset, int volume255, int duration65535, int feedback255);

int mbox_get_clock_source(MboxDevice* dev, int* source);
int mbox_set_clock_source(MboxDevice* dev, int source);       // waits briefly for S/PDIF lock
int mbox_spdif_valid(MboxDevice* dev, bool* valid);
int mbox_get_sample_rate(MboxDevice* dev, uint32_t* rate);    // rate of the selected clock
int mbox_set_internal_rate(MboxDevice* dev, uint32_t rate);

// Linux-reference defaults (48 kHz, internal clock, returns 1/2 to Out 1/2 and 3/4 to Out 3/4, effect off)
int mbox_setup_defaults(MboxDevice* dev);

// MARK: Core Audio (MboxCoreAudio.cpp), only meaningful with the Mbox 3 Core Audio driver installed

bool mbox_coreaudio_present(void);
int mbox_coreaudio_set_rate(double rate);
int mbox_coreaudio_get_rate(double* rate);
int mbox_coreaudio_get_latency_mode(int* mode);               // MBOX_LATENCY_*
int mbox_coreaudio_set_latency_mode(int mode);
int mbox_driver_version(char* out, size_t size);              // installed driver bundle version

#ifdef __cplusplus
}
#endif

#endif
