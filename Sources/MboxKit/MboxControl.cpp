// MboxKit controls: front-panel registers, meters, mixer, effect and clock. See ../Shared/MboxProtocol.h.

#include "MboxKit.h"

#include <unistd.h>
#include <cmath>

static int setCur(MboxDevice* dev, uint16_t wValue, uint16_t wIndex, void* data, uint16_t len) {
    return mbox_request(dev, MBOX_REQ_CUR, MBOX_RT_SET, wValue, wIndex, data, len, nullptr);
}

static int getCur(MboxDevice* dev, uint16_t wValue, uint16_t wIndex, void* data, uint16_t len) {
    uint32_t done = 0;
    int r = mbox_request(dev, MBOX_REQ_CUR, MBOX_RT_GET, wValue, wIndex, data, len, &done);
    return (r == MBOX_OK && done == len) ? MBOX_OK : MBOX_ERR_IO;
}

// MARK: - Registers and meters

int mbox_read_regs(MboxDevice* dev, MboxRegs* out) {
    if (!out) return MBOX_ERR_ARG;
    int16_t* fields[6] = {&out->llm, &out->mono, &out->dim, &out->tuner, &out->ledDim, &out->hold};
    int failures = 0;
    for (uint16_t reg = 0; reg < 6; reg++) {
        uint8_t v = 0;
        uint32_t done = 0;
        if (mbox_request(dev, MBOX_REQ_MEM, MBOX_RT_GET, reg, MBOX_UNIT_EXTENSION, &v, 1, &done) == MBOX_OK && done == 1) {
            *fields[reg] = v;
        } else {
            *fields[reg] = -1;
            failures++;
        }
    }
    return failures == 6 ? MBOX_ERR_IO : MBOX_OK;
}

int mbox_write_reg(MboxDevice* dev, uint8_t reg, uint8_t value) {
    return mbox_request(dev, MBOX_REQ_MEM, MBOX_RT_SET, reg, MBOX_UNIT_EXTENSION, &value, 1, nullptr);
}

int mbox_read_meters(MboxDevice* dev, uint16_t out[MBOX_METER_COUNT]) {
    uint8_t buf[MBOX_METER_COUNT * 2] = {0};
    uint32_t done = 0;
    int r = mbox_request(dev, MBOX_REQ_MEM, MBOX_RT_GET, MBOX_REG_METERS, MBOX_UNIT_EXTENSION, buf, sizeof(buf), &done);
    if (r != MBOX_OK || done != sizeof(buf)) return MBOX_ERR_IO;
    for (int i = 0; i < MBOX_METER_COUNT; i++) out[i] = (uint16_t)(buf[i * 2] | (buf[i * 2 + 1] << 8));
    return MBOX_OK;
}

// MARK: - Mixer and effect

// Panel fader taper: level 0 mutes, 100 is unity, 15-100 follows 20*log10(level/100), below 15 a fade linear in
// dB from -60 dB that meets the log curve at 15 (-16.5 dB). Levels may be fractional. Gains are UAC 1/256 dB steps
// quantised to 0.25 dB (the hardware's resolution), floor -60 dB. Mirrored by Sources/UI/js/gain.js.
static const double kKneeLevel = 15.0, kKneeDb = -16.478;  // 20*log10(0.15)

static int32_t levelToRaw(double level) {
    if (!(level > 0)) return INT16_MIN;
    if (level >= 100) return 0;
    double db = level < kKneeLevel ? -60.0 + (level / kKneeLevel) * (60.0 + kKneeDb) : 20.0 * std::log10(level / 100.0);
    int32_t raw = (int32_t)std::lround(db * 256.0);
    raw = (raw / 64) * 64;
    if (raw < -15360) raw = -15360;
    if (raw > 0) raw = 0;
    return raw;
}

void mbox_level_to_gain(double level, uint8_t out[2]) {
    uint16_t u = (uint16_t)(int16_t)levelToRaw(level);
    out[0] = (uint8_t)(u & 0xFF);
    out[1] = (uint8_t)(u >> 8);
}

double mbox_level_to_db(double level) {
    int32_t raw = levelToRaw(level);
    return raw == INT16_MIN ? -999.0 : raw / 256.0;
}

int mbox_set_mix_level(MboxDevice* dev, uint16_t wIndex, uint16_t wValue, double level) {
    uint8_t gain[2];
    mbox_level_to_gain(level, gain);
    return setCur(dev, wValue, wIndex, gain, 2);
}

void mbox_pct_to_gain(int pct, uint8_t out[2]) { mbox_level_to_gain(pct, out); }
double mbox_pct_to_db(int pct) { return mbox_level_to_db(pct); }
int mbox_set_mix(MboxDevice* dev, uint16_t wIndex, uint16_t wValue, int pct) { return mbox_set_mix_level(dev, wIndex, wValue, pct); }

int mbox_set_effect(MboxDevice* dev, int preset, int volume255, int duration65535, int feedback255) {
    uint8_t p = (uint8_t)preset, vol = (uint8_t)volume255, fb = (uint8_t)feedback255;
    uint8_t dur[2] = {(uint8_t)(duration65535 & 0xFF), (uint8_t)((duration65535 >> 8) & 0xFF)};
    int r = setCur(dev, MBOX_EFFECT_PRESET, MBOX_UNIT_EFFECT, &p, 1);
    r |= setCur(dev, MBOX_EFFECT_VOLUME, MBOX_UNIT_EFFECT, &vol, 1);
    r |= setCur(dev, MBOX_EFFECT_DURATION, MBOX_UNIT_EFFECT, dur, 2);
    r |= setCur(dev, MBOX_EFFECT_FEEDBACK, MBOX_UNIT_EFFECT, &fb, 1);
    return r ? MBOX_ERR_IO : MBOX_OK;
}

// MARK: - Clock

int mbox_get_clock_source(MboxDevice* dev, int* source) {
    uint8_t sel = 0;
    if (getCur(dev, MBOX_CLOCK_CTL_SELECTOR, MBOX_UNIT_CLOCK_SELECTOR, &sel, 1) != MBOX_OK) return MBOX_ERR_IO;
    if (source) *source = sel;
    return MBOX_OK;
}

int mbox_spdif_valid(MboxDevice* dev, bool* valid) {
    uint8_t v = 0;
    if (getCur(dev, MBOX_CLOCK_CTL_VALID, MBOX_UNIT_CLOCK_SPDIF, &v, 1) != MBOX_OK) return MBOX_ERR_IO;
    if (valid) *valid = v != 0;
    return MBOX_OK;
}

int mbox_set_clock_source(MboxDevice* dev, int source) {
    if (source != MBOX_CLOCK_INTERNAL && source != MBOX_CLOCK_SPDIF) return MBOX_ERR_ARG;
    uint8_t sel = (uint8_t)source;
    int r = setCur(dev, MBOX_CLOCK_CTL_SELECTOR, MBOX_UNIT_CLOCK_SELECTOR, &sel, 1);
    if (r == MBOX_OK && source == MBOX_CLOCK_SPDIF) {
        for (int i = 0; i < 64; i++) {  // up to ~320 ms for the receiver to lock
            bool valid = false;
            if (mbox_spdif_valid(dev, &valid) == MBOX_OK && valid) break;
            usleep(5000);
        }
    }
    return r;
}

int mbox_get_sample_rate(MboxDevice* dev, uint32_t* rate) {
    int source = MBOX_CLOCK_INTERNAL;
    mbox_get_clock_source(dev, &source);
    uint8_t b[4] = {0};
    uint16_t unit = source == MBOX_CLOCK_SPDIF ? MBOX_UNIT_CLOCK_SPDIF : MBOX_UNIT_CLOCK_INTERNAL;
    if (getCur(dev, MBOX_CLOCK_CTL_RATE, unit, b, 4) != MBOX_OK) return MBOX_ERR_IO;
    if (rate) *rate = (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
    return MBOX_OK;
}

int mbox_set_internal_rate(MboxDevice* dev, uint32_t rate) {
    if (rate != 44100 && rate != 48000 && rate != 88200 && rate != 96000) return MBOX_ERR_ARG;
    uint8_t b[4] = {(uint8_t)rate, (uint8_t)(rate >> 8), (uint8_t)(rate >> 16), 0};
    return setCur(dev, MBOX_CLOCK_CTL_RATE, MBOX_UNIT_CLOCK_INTERNAL, b, 4);
}

// MARK: - Defaults

int mbox_setup_defaults(MboxDevice* dev) {
    int r = MBOX_OK;
    r |= mbox_write_reg(dev, MBOX_REG_TUNER, 0);
    r |= mbox_set_clock_source(dev, MBOX_CLOCK_INTERNAL);
    r |= mbox_set_internal_rate(dev, 48000);
    r |= mbox_write_reg(dev, MBOX_REG_LLM, 0);
    for (int in = 0; in < 4; in++) {
        for (int out = 0; out < 4; out++) {
            // Hardware inputs muted; returns 1/2 -> Out 1/2 and 3/4 -> Out 3/4 at unity
            r |= mbox_set_mix(dev, MBOX_UNIT_MIXER, mbox_mixer_control(MBOX_MIX_IN_HARDWARE + in, out), 0);
            r |= mbox_set_mix(dev, MBOX_UNIT_MIXER, mbox_mixer_control(MBOX_MIX_IN_SOFTWARE + in, out), in == out ? 100 : 0);
        }
        r |= mbox_set_mix(dev, MBOX_UNIT_MIXER, mbox_mixer_control(MBOX_MIX_IN_FX_RETURN, in), 0);
        r |= mbox_set_mix(dev, MBOX_UNIT_FX_SENDS, mbox_fx_send_control(0, in), 0);
        r |= mbox_set_mix(dev, MBOX_UNIT_FX_SENDS, mbox_fx_send_control(1, in), 0);
    }
    r |= mbox_write_reg(dev, MBOX_REG_DIM, 0);
    r |= mbox_write_reg(dev, MBOX_REG_MONO, 0);
    r |= mbox_write_reg(dev, MBOX_REG_HOLD, MBOX_HOLD_500MS);
    r |= mbox_write_reg(dev, MBOX_REG_LED_DIM, 1);
    r |= mbox_set_effect(dev, 0, 0, 0, 0);
    return r ? MBOX_ERR_IO : MBOX_OK;
}
