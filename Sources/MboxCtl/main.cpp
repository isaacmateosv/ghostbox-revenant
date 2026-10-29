// mbox3-ctl: command-line access to the Mbox 3 control path (diagnostics, scripting, installer).
// Every command prints one JSON line. Run without arguments for usage.

#include "../MboxKit/MboxKit.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static const char* kUsage =
    "usage: mbox3-ctl <command> [args]\n"
    "  status                         connection, firmware, clock, rate, driver\n"
    "  meters | regs                  meter block / front-panel registers\n"
    "  init                           reset the hardware to defaults\n"
    "  mono|dim|tuner|led-dim <0|1>   front-panel functions\n"
    "  hold-duration <code>           long-press time (3=250ms 5=500ms 8=750ms 10=1s)\n"
    "  llm <0|1>                      Low Latency Monitoring state\n"
    "  clock-source <internal|spdif>  clock selector only\n"
    "  clock <internal|spdif> [rate]  selector plus internal rate\n"
    "  sample-rate <rate>             internal clock rate (44100/48000/88200/96000)\n"
    "  ca-rate <rate>                 set the rate through Core Audio (driver installed)\n"
    "  latency [safe|balanced|low]    show or set the driver latency mode\n"
    "  batch <wIndex:wValue:pct>...   mixer crosspoints, pct 0..100\n"
    "  dsp <preset> <vol> <dur> <fb>  effect unit (0-255, 0-65535, 0-255)\n"
    "  get <bRequest> <wValue> <wIndex> <len>   read-only register probe\n"
    "  reenumerate                    software replug\n";

static const char* kLatencyNames[MBOX_LATENCY_MODES] = {"safe", "balanced", "low"};

static int finish(const char* cmd, int r) {
    printf("{\"ok\":%s,\"cmd\":\"%s\",\"status\":%d}\n", r == MBOX_OK ? "true" : "false", cmd, r);
    return r == MBOX_OK ? 0 : 1;
}

static long num(const char* s) { return strtol(s, nullptr, 0); }

static bool isSpdif(const char* arg) { return !strcmp(arg, "spdif") || !strcmp(arg, "2"); }

// Commands that only talk to Core Audio (work without opening the USB device)
static int coreAudioCommand(const std::string& cmd, int argc, char** argv) {
    if (cmd == "ca-rate") {
        if (argc < 3) { fputs(kUsage, stderr); return 2; }
        return finish("ca-rate", mbox_coreaudio_set_rate(atof(argv[2])));
    }
    // latency
    if (argc >= 3) {
        int mode = -1;
        for (int i = 0; i < MBOX_LATENCY_MODES; i++) if (!strcmp(argv[2], kLatencyNames[i])) mode = i;
        if (mode < 0) { fputs(kUsage, stderr); return 2; }
        return finish("latency", mbox_coreaudio_set_latency_mode(mode));
    }
    int mode = 0;
    int r = mbox_coreaudio_get_latency_mode(&mode);
    if (r != MBOX_OK) return finish("latency", r);
    printf("{\"ok\":true,\"latency\":\"%s\"}\n", kLatencyNames[mode]);
    return 0;
}

static int printStatus(MboxDevice* dev) {
    int source = 0, mode = -1;
    uint32_t rate = 0;
    char version[32] = "";
    mbox_get_clock_source(dev, &source);
    mbox_get_sample_rate(dev, &rate);
    bool coreAudio = mbox_coreaudio_present();
    if (coreAudio) mbox_coreaudio_get_latency_mode(&mode);
    mbox_driver_version(version, sizeof(version));
    MboxInfo info = mbox_info(dev);
    printf("{\"ok\":true,\"connected\":true,\"vid\":\"0x%04x\",\"pid\":\"0x%04x\",\"bcdDevice\":\"0x%x\","
           "\"locationID\":\"0x%x\",\"clockSource\":%d,\"sampleRate\":%u,\"coreAudio\":%s,\"driverVersion\":\"%s\","
           "\"latency\":\"%s\"}\n",
           MBOX_VENDOR_ID, MBOX_PRODUCT_ID, info.bcdDevice, info.locationID, source, rate, coreAudio ? "true" : "false",
           version, mode >= 0 ? kLatencyNames[mode] : "");
    return 0;
}

static int printMeters(MboxDevice* dev) {
    uint16_t m[MBOX_METER_COUNT] = {0};
    int r = mbox_read_meters(dev, m);
    printf("{\"ok\":%s,\"bytes\":%d,\"raw\":[", r == MBOX_OK ? "true" : "false", r == MBOX_OK ? MBOX_METER_COUNT * 2 : 0);
    for (int i = 0; i < MBOX_METER_COUNT; i++) printf("%u%s", m[i], i + 1 < MBOX_METER_COUNT ? "," : "");
    printf("]}\n");
    return r == MBOX_OK ? 0 : 1;
}

static int printRegs(MboxDevice* dev) {
    MboxRegs g;
    int r = mbox_read_regs(dev, &g);
    // "host_ctrl" kept as an alias of "llm" for older scripts
    printf("{\"ok\":%s,\"llm\":%d,\"host_ctrl\":%d,\"mono\":%d,\"dim\":%d,\"tuner\":%d,\"led_dim\":%d,\"hold\":%d}\n",
           r == MBOX_OK ? "true" : "false", g.llm, g.llm, g.mono, g.dim, g.tuner, g.ledDim, g.hold);
    return r == MBOX_OK ? 0 : 1;
}

static int probe(MboxDevice* dev, char** argv) {
    uint8_t buf[64] = {0};
    uint32_t done = 0;
    uint16_t len = (uint16_t)(num(argv[5]) > 64 ? 64 : num(argv[5]));
    int r = mbox_request(dev, (uint8_t)num(argv[2]), MBOX_RT_GET, (uint16_t)num(argv[3]), (uint16_t)num(argv[4]), buf, len, &done);
    printf("{\"ok\":%s,\"bytes\":%u,\"data\":[", r == MBOX_OK ? "true" : "false", done);
    for (uint32_t i = 0; i < done; i++) printf("%d%s", buf[i], i + 1 < done ? "," : "");
    printf("]}\n");
    return r == MBOX_OK ? 0 : 1;
}

static const int kUnknownCommand = -1000;

// Commands that change the hardware; return an MBOX_* result, or kUnknownCommand
static int writeCommand(MboxDevice* dev, const std::string& cmd, int argc, char** argv) {
    if (cmd == "init") return mbox_setup_defaults(dev);
    if (cmd == "reenumerate") return mbox_reenumerate(dev);
    if (argc < 3) return kUnknownCommand;
    if (cmd == "mono" || cmd == "dim" || cmd == "tuner" || cmd == "led-dim" || cmd == "llm") {
        uint8_t reg = cmd == "mono" ? MBOX_REG_MONO : cmd == "dim" ? MBOX_REG_DIM : cmd == "tuner" ? MBOX_REG_TUNER
                    : cmd == "led-dim" ? MBOX_REG_LED_DIM : MBOX_REG_LLM;
        return mbox_write_reg(dev, reg, num(argv[2]) ? 1 : 0);
    }
    if (cmd == "hold-duration") return mbox_write_reg(dev, MBOX_REG_HOLD, (uint8_t)num(argv[2]));
    if (cmd == "clock-source") return mbox_set_clock_source(dev, isSpdif(argv[2]) ? MBOX_CLOCK_SPDIF : MBOX_CLOCK_INTERNAL);
    if (cmd == "clock") {
        bool spdif = isSpdif(argv[2]);
        int r = mbox_set_clock_source(dev, spdif ? MBOX_CLOCK_SPDIF : MBOX_CLOCK_INTERNAL);
        if (r == MBOX_OK && !spdif) r = mbox_set_internal_rate(dev, argc >= 4 ? (uint32_t)num(argv[3]) : 48000);
        return r;
    }
    if (cmd == "sample-rate") return mbox_set_internal_rate(dev, (uint32_t)num(argv[2]));
    if (cmd == "batch") {
        int r = MBOX_OK;
        for (int i = 2; i < argc; i++) {
            int idx = 0, val = 0, pct = 0;
            if (sscanf(argv[i], "%i:%i:%d", &idx, &val, &pct) != 3) continue;
            r |= mbox_set_mix(dev, (uint16_t)idx, (uint16_t)val, pct);
        }
        return r;
    }
    if (cmd == "dsp" && argc >= 6)
        return mbox_set_effect(dev, (int)num(argv[2]), (int)num(argv[3]), (int)num(argv[4]), (int)num(argv[5]));
    return kUnknownCommand;
}

int main(int argc, char** argv) {
    std::string cmd = argc > 1 ? argv[1] : "status";
    if (cmd == "-h" || cmd == "--help" || cmd == "help") { fputs(kUsage, stdout); return 0; }
    if (cmd == "ca-rate" || cmd == "latency") return coreAudioCommand(cmd, argc, argv);

    MboxDevice* dev = mbox_open();
    if (!dev) {
        printf("{\"ok\":false,\"connected\":false,\"error\":\"Avid Mbox 3 not connected\"}\n");
        return 1;
    }
    int exitCode;
    if (cmd == "status") exitCode = printStatus(dev);
    else if (cmd == "meters") exitCode = printMeters(dev);
    else if (cmd == "regs") exitCode = printRegs(dev);
    else if (cmd == "get" && argc >= 6) exitCode = probe(dev, argv);
    else {
        int r = writeCommand(dev, cmd, argc, argv);
        if (r == kUnknownCommand) { fputs(kUsage, stderr); exitCode = 2; }
        else exitCode = finish(cmd.c_str(), r);
    }
    mbox_close(dev);
    return exitCode;
}
