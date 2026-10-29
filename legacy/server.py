import http.server
import json
import subprocess
import os
import threading
import time
import random
import math
import copy
import atexit
import signal
import sys

# The Mac app sets these; start.sh runs with the defaults from this folder
PORT = int(os.environ.get("MBOX3_PORT", "8080"))
BINARY = os.environ.get("MBOX3_CTL", "./mbox3-ctl")
PRESETS_DIR = "./presets"
USB_LOCK = threading.Lock()

if not os.path.exists(PRESETS_DIR):
    os.makedirs(PRESETS_DIR)

def default_mix_bus(is_spdif=False):
    return {
        "hw": [
            {"label": "Input 1 (Mic/DI)", "fader": 0, "pan": -50, "mute": False, "solo": False},
            {"label": "Input 2 (Mic/DI)", "fader": 0, "pan": 50,  "mute": False, "solo": False},
            {"label": "S/PDIF In L",      "fader": 0, "pan": -50, "mute": False, "solo": False},
            {"label": "S/PDIF In R",      "fader": 0, "pan": 50,  "mute": False, "solo": False},
        ],
        "sw": [
            {"label": "DAW Ret 1", "fader": 0 if is_spdif else 85, "pan": -50, "mute": False, "solo": False},
            {"label": "DAW Ret 2", "fader": 0 if is_spdif else 85, "pan": 50,  "mute": False, "solo": False},
            {"label": "DAW Ret 3", "fader": 85 if is_spdif else 0, "pan": -50, "mute": False, "solo": False},
            {"label": "DAW Ret 4", "fader": 85 if is_spdif else 0, "pan": 50,  "mute": False, "solo": False},
        ],
        "links": {"hw12": True, "hw34": True, "sw12": True, "sw34": True, "fxret": True, "master": True},
        "fx_ret": {"l": 0, "r": 0, "mute_l": False, "mute_r": False, "solo_l": False, "solo_r": False},
        "master": {"fader": 85, "balance": 0, "width": 100, "mute_l": False, "mute_r": False, "swap": False}
    }

STATE = {
    "connected": True,
    "streaming": False,
    "firmware": "1.04 (0x0108)",
    "package": "1.0.10",
    "layout": "horizontal", # horizontal | horizontal_meters | vertical | vertical_meters
    "active_mix": "analog", # analog (Out 1/2) | spdif (Out 3/4)
    "tuner": False,
    "mono": False,
    "dim": False,
    "phantom_48v": False,
    "front_panel": {
        "in1_gain": 50, "in1_pad": False, "in1_soft_limit": False, "in1_source": "rear",
        "in2_gain": 50, "in2_pad": False, "in2_soft_limit": False, "in2_source": "rear",
        "hp_vol": 75, "mon_vol": 80
    },
    "setup": {
        "disable_host_control": False,
        "clock_source": "internal", # internal | spdif
        "sample_rate": 48000,
        "buffer_size": 256,
        "hold_duration": 500, # 250 | 500 | 750 | 1000
        "dim_leds_off_state": False,
        "hold_clip_indicators": True,
        "load_latency_clock": False,
        "meter_mode": "post", # pre | post
        "fx_send_mode": "post" # pre | post
    },
    "multi_button": {
        "press_release": "Start/Stop Record",
        "press_hold": "Add Selected Track",
        "hold_duration": 500,
        "last_triggered": "None",
        "tap_bpm": 120.0
    },
    "midi_ams": {
        "device_name": "JP-8000",
        "manufacturer": "Roland",
        "model": "JP-8000",
        "tx_channels": list(range(1, 17)),
        "rx_channels": list(range(1, 17)),
        "beat_clock": False,
        "mtc": False,
        "general_midi": False,
        "mmc": False,
        "sysex_id": "17"
    },
    "fx_sends": {
        "hw": [0, 0, 0, 0],
        "sw": [0, 0, 0, 0]
    },
    "dsp": {
        "effect": 0, # 0:Room1, 1:Room2, 2:Room3, 3:Hall1, 4:Hall2, 5:Plate, 6:Delay, 7:Echo
        "duration": 50,
        "feedback": 40,
        "volume": 0
    },
    "mixes": {
        "analog": default_mix_bus(False),
        "spdif": default_mix_bus(True)
    },
    "clips": {"hw": [False] * 4, "sw": [False] * 4, "out12": [False] * 2, "out34": [False] * 2, "fx": [False] * 2},
    "meters": {
        "hw": [0.0, 0.0, 0.0, 0.0],
        "sw": [0.0, 0.0, 0.0, 0.0],
        "fx": [0.0, 0.0],
        "out12": [0.0, 0.0],
        "out34": [0.0, 0.0]
    }
}

READ_CMDS = {"status", "meters", "regs", "get"}
LAST_WRITE = [0.0]

def run_ctl(args):
    if str(args[0]) not in READ_CMDS:
        LAST_WRITE[0] = time.time()
    with USB_LOCK:
        try:
            res = subprocess.run([BINARY] + [str(a) for a in args], capture_output=True, text=True, timeout=1.5)
            if res.stdout:
                return json.loads(res.stdout.strip().splitlines()[-1])
        except Exception as e:
            return {"ok": False, "error": str(e)}
        return {"ok": True}

def fader_to_pct(fader_val):
    return max(0, min(100, int(round((fader_val / 85.0) * 100.0))))

def compute_bus_batch_pairs(bus_name):
    bus = STATE["mixes"][bus_name]
    master = bus["master"]
    any_solo = any(c["solo"] for c in bus["hw"] + bus["sw"]) or bus["fx_ret"]["solo_l"] or bus["fx_ret"]["solo_r"]
    is_spdif = (bus_name == "spdif")

    m_scale = (master["fader"] / 85.0)
    bal = master["balance"] / 50.0
    bal_l = 1.0 if bal <= 0 else (1.0 - bal)
    bal_r = 1.0 if bal >= 0 else (1.0 + bal)
    width = master["width"] / 100.0

    def compute_lr(fader, pan, muted, soloed):
        if muted or (any_solo and not soloed) or fader <= 0 or master["fader"] <= 0:
            return 0, 0
        base = fader_to_pct(fader) * m_scale
        p_eff = (pan / 50.0) * width
        l_gain = base * (1.0 if p_eff <= 0 else (1.0 - p_eff)) * bal_l
        r_gain = base * (1.0 if p_eff >= 0 else (1.0 + p_eff)) * bal_r
        if master["swap"]:
            l_gain, r_gain = r_gain, l_gain
        if master["mute_l"]:
            l_gain = 0
        if master["mute_r"]:
            r_gain = 0
        return max(0, min(100, int(round(l_gain)))), max(0, min(100, int(round(r_gain))))

    pairs = []
    hw_base = 0x0112 if is_spdif else 0x0110
    for idx, ch in enumerate(bus["hw"]):
        l_pct, r_pct = compute_lr(ch["fader"], ch["pan"], ch["mute"], ch["solo"])
        wv_l = hw_base + (idx * 4)
        pairs.append(f"0x4001:{hex(wv_l)}:{l_pct}")
        pairs.append(f"0x4001:{hex(wv_l + 1)}:{r_pct}")

    sw_base = 0x0102 if is_spdif else 0x0100
    for idx, ch in enumerate(bus["sw"]):
        l_pct, r_pct = compute_lr(ch["fader"], ch["pan"], ch["mute"], ch["solo"])
        wv_l = sw_base + (idx * 4)
        pairs.append(f"0x4001:{hex(wv_l)}:{l_pct}")
        pairs.append(f"0x4001:{hex(wv_l + 1)}:{r_pct}")

    fxr = bus["fx_ret"]
    fxl, _ = compute_lr(fxr["l"], -50, fxr["mute_l"], fxr["solo_l"] or not any_solo)
    _, fxr_val = compute_lr(fxr["r"], 50, fxr["mute_r"], fxr["solo_r"] or not any_solo)
    fx_base = 0x0122 if is_spdif else 0x0120
    pairs.append(f"0x4001:{hex(fx_base)}:{fxl}")
    pairs.append(f"0x4001:{hex(fx_base + 1)}:{fxr_val}")
    return pairs

def sync_bus_to_hardware(bus_name):
    pairs = compute_bus_batch_pairs(bus_name)
    run_ctl(["batch"] + pairs)

def sync_fx_to_hardware():
    mix1 = STATE["mixes"]["analog"]
    post_fader = (STATE["setup"]["fx_send_mode"] == "post")
    pairs = []
    for i in range(4):
        hw_send = STATE["fx_sends"]["hw"][i]
        if post_fader:
            hw_send = int(round(hw_send * (mix1["hw"][i]["fader"] / 85.0)))
        pairs.append(f"0x4201:{hex(0x0104 + i)}:{max(0, min(100, hw_send))}")

        sw_send = STATE["fx_sends"]["sw"][i]
        if post_fader:
            sw_send = int(round(sw_send * (mix1["sw"][i]["fader"] / 85.0)))
        pairs.append(f"0x4201:{hex(0x0100 + i)}:{max(0, min(100, sw_send))}")

    run_ctl(["batch"] + pairs)
    dsp = STATE["dsp"]
    preset = int(dsp["effect"])
    vol = int(round((dsp["volume"] / 100.0) * 255))
    dur = int(round((dsp["duration"] / 100.0) * 65535))
    fb = int(round((dsp["feedback"] / 100.0) * 255)) if preset in (6, 7) else 0
    run_ctl(["dsp", preset, vol, dur, fb])

def inspect_macos_diagnostics():
    diag = {
        "midnam_files": [],
        "middev_files": [],
        "volumes": [],
        "ram_gb": "Unknown",
        "disk_sleep": "Unknown"
    }
    for d in ["/Library/Audio/MIDI Devices", "/Library/Audio/MIDI Patch Names/Digidesign"]:
        if os.path.exists(d):
            for root, _, files in os.walk(d):
                for f in files:
                    if f.endswith(".midnam"):
                        diag["midnam_files"].append(f)
                    elif f.endswith(".middev"):
                        diag["middev_files"].append(f)
    if not diag["middev_files"]:
        diag["middev_files"] = ["Digidesign Device List.middev (Default)"]
    if not diag["midnam_files"]:
        diag["midnam_files"] = ["Roland_JP8000.midnam (Template)", "General_MIDI.midnam (Template)"]

    try:
        mem = subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True, timeout=1).strip()
        diag["ram_gb"] = f"{round(int(mem) / (1024**3), 1)} GB"
    except Exception:
        pass
    try:
        pm = subprocess.check_output(["pmset", "-g"], text=True, timeout=1)
        for line in pm.splitlines():
            if "disksleep" in line:
                diag["disk_sleep"] = line.strip()
    except Exception:
        pass
    try:
        vols = os.listdir("/Volumes")
        diag["volumes"] = vols
    except Exception:
        pass
    return diag

# Hardware meter block: request 0x03 / 0xA1, wValue 0x0010, wIndex 0x2001 -> 15 LE uint16 peaks.
# Words 0-1 confirmed on hardware (analog inputs 1/2). Others follow the
# 4 hw-in / 4 sw-ret / 4 out / 2 fx layout and are UNVERIFIED -- adjust here if a meter tracks the wrong signal.
LAST_STATE_FILE = "./last_state.json"
RUNTIME_KEYS = {"connected", "streaming", "firmware", "tuner", "meters", "clips"}
DEFAULT_STATE = copy.deepcopy(STATE)
DIRTY = [0.0]  # time of the last unsaved change, 0 = clean
HOLD_CODES = {250: 0x03, 500: 0x05, 750: 0x08, 1000: 0x0a}

def merge_into(dst, src):
    # Copy saved values over defaults key by key, so keys added in newer versions keep their defaults
    for k, v in src.items():
        if k in dst and isinstance(dst[k], dict) and isinstance(v, dict):
            merge_into(dst[k], v)
        elif k in dst:
            dst[k] = v

def mark_dirty():
    DIRTY[0] = time.time()

def save_state():
    data = {k: v for k, v in STATE.items() if k not in RUNTIME_KEYS}
    tmp = LAST_STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, LAST_STATE_FILE)
    DIRTY[0] = 0.0

def load_state():
    if not os.path.exists(LAST_STATE_FILE):
        return False
    try:
        with open(LAST_STATE_FILE) as f:
            merge_into(STATE, json.load(f))
        return True
    except Exception as e:
        print(f"[-] Ignoring unreadable {LAST_STATE_FILE}: {e}")
        return False

MBOX3_DRIVER = "/Library/Audio/Plug-Ins/HAL/Mbox3.driver"

def apply_clock():
    src, rate = STATE["setup"]["clock_source"], STATE["setup"]["sample_rate"]
    if os.path.exists(MBOX3_DRIVER):
        # With the Core Audio driver installed, Core Audio owns the sample rate: writing it to the hardware
        # behind Core Audio's back makes apps stream at the wrong rate (crackle, distortion, wrong speed).
        run_ctl(["clock-source", src])
        if src == "internal":
            run_ctl(["ca-rate", rate])
    else:
        run_ctl(["clock", src, rate])

def full_sync_to_hardware():
    # Push the complete panel state to the Mbox (startup, replug, power cycle, factory reset)
    setup = STATE["setup"]
    apply_clock()
    run_ctl(["host-ctrl", 2 if setup["disable_host_control"] else 0])
    run_ctl(["led-dim", 1 if setup["dim_leds_off_state"] else 0])
    run_ctl(["hold-duration", HOLD_CODES.get(setup["hold_duration"], 0x05)])
    run_ctl(["mono", 1 if STATE["mono"] else 0])
    run_ctl(["dim", 1 if STATE["dim"] else 0])
    STATE["tuner"] = False
    run_ctl(["tuner", 0])
    sync_bus_to_hardware("analog")
    sync_bus_to_hardware("spdif")
    sync_fx_to_hardware()

METER_MAP = {
    "hw": [0, 1, 2, 3],        # analog in 1, analog in 2 (confirmed); S/PDIF in L/R (by elimination)
    "sw": [4, 5, 6, 7],        # software returns 1-4 (by elimination; needs an audio driver to verify)
    "out12": [8, 9],           # Out 1/2 mix L/R (confirmed)
    "out34": [10, 11],         # Out 3/4 mix L/R (confirmed)
    "fx": [13, 14],            # FX output L/R (confirmed)
}
METER_FX_INPUT = 12            # FX send bus input level, used only for the FX clip LED (confirmed)
METER_CLIP_RAW = 32700         # word saturates at 32767 = 0 dBFS
CLIP_LATCH_S = 0.35            # keep a clip visible long enough for the UI poll to catch it
METER_FULL_SCALE = 32767.0
METER_FLOOR_DB = -60.0
METER_RELEASE = 0.82

def raw_to_level(v):
    if v <= 0:
        return 0.0
    db = 20.0 * math.log10(min(1.0, v / METER_FULL_SCALE))
    return max(0.0, min(1.0, (db - METER_FLOOR_DB) / -METER_FLOOR_DB))

def poller():
    tick = 0
    synced = False  # False until the saved state has been pushed to the currently attached Mbox
    held = {k: [0.0] * len(v) for k, v in METER_MAP.items()}
    clip_until = {k: [0.0] * len(v) for k, v in METER_MAP.items()}
    while True:
        tick += 1
        if os.environ.get("MBOX3_APP") and os.getppid() == 1:
            # The app that launched us is gone (crash/force quit): save and release the port
            if DIRTY[0]:
                save_state()
            os._exit(0)
        if tick % 16 == 1:
            st = run_ctl(["status"])
            STATE["connected"] = bool(st.get("connected", False))
            if not STATE["connected"]:
                synced = False
            else:
                bcd = int(st.get("bcdDevice", "0x0"), 16)
                STATE["firmware"] = f"{bcd >> 8}.{bcd & 0xff:02x} (0x{bcd:04x})"
                if not synced:
                    # Fresh attach, replug or power cycle: the Mbox lost its mixer state, restore ours
                    print("[+] Mbox attached, restoring saved mix")
                    full_sync_to_hardware()
                    synced = True
                else:
                    if st.get("sampleRate"):
                        STATE["setup"]["sample_rate"] = int(st["sampleRate"])
                    STATE["setup"]["clock_source"] = "spdif" if st.get("clockSource") == 2 else "internal"

        if DIRTY[0] and time.time() - DIRTY[0] > 0.75:
            try:
                save_state()
            except OSError as e:
                print(f"[-] Could not save {LAST_STATE_FILE}: {e}")

        if tick % 8 == 2 and STATE["connected"] and time.time() - LAST_WRITE[0] > 1.0:
            # Follow front-panel soft buttons (Mono, Dim, Dim+Mono tuner) pressed on the hardware
            regs = run_ctl(["regs"])
            if regs.get("ok") and time.time() - LAST_WRITE[0] > 1.0:
                for key in ("mono", "dim", "tuner"):
                    if regs.get(key) is not None and STATE[key] != bool(regs[key]):
                        STATE[key] = bool(regs[key])
                        if key != "tuner":
                            mark_dirty()
                hold_map = {0x03: 250, 0x05: 500, 0x08: 750, 0x0a: 1000}
                if regs.get("hold") in hold_map:
                    STATE["setup"]["hold_duration"] = hold_map[regs["hold"]]
                    STATE["multi_button"]["hold_duration"] = hold_map[regs["hold"]]

        res = run_ctl(["meters"]) if STATE["connected"] else {}
        raw = res.get("raw") if res.get("ok") else None
        post = (STATE["setup"]["meter_mode"] == "post")
        bus = STATE["mixes"][STATE["active_mix"]]
        any_solo = any(c["solo"] for c in bus["hw"] + bus["sw"])
        for key, idxs in METER_MAP.items():
            for j, idx in enumerate(idxs):
                v = raw[idx] if raw and idx < len(raw) else 0
                clipping = v >= METER_CLIP_RAW or (key == "fx" and raw and raw[METER_FX_INPUT] >= METER_CLIP_RAW)
                if clipping:
                    clip_until[key][j] = time.time() + CLIP_LATCH_S
                STATE["clips"][key][j] = time.time() < clip_until[key][j]
                if post and key in ("hw", "sw"):
                    ch = bus[key][j]
                    audible = not ch["mute"] and (ch["solo"] or not any_solo)
                    v = v * (fader_to_pct(ch["fader"]) / 100.0) if audible else 0
                lvl = raw_to_level(v)
                # instant attack, exponential release so peaks stay readable at ~18 Hz
                held[key][j] = lvl if lvl >= held[key][j] else held[key][j] * METER_RELEASE
                STATE["meters"][key][j] = round(held[key][j], 3)

        STATE["streaming"] = any(v > 0.05 for v in STATE["meters"]["sw"])
        time.sleep(0.055)

print("[+] Restored last session from " + LAST_STATE_FILE if load_state() else "[*] No saved session, using defaults")
atexit.register(lambda: DIRTY[0] and save_state())
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))  # run atexit (final save) on a normal kill
threading.Thread(target=poller, daemon=True).start()

HTML_UI = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Avid Mbox Driver Control Panel — Complete Reference Suite</title>
<style>
    :root {
        --bg-body: #0e0f12;
        --chassis: #242529;
        --panel: #1a1b1f;
        --strip: #202126;
        --border: #36383e;
        --avid-green: #62d926;
        --avid-amber: #f59e0b;
        --avid-purple: #a855f7;
        --avid-blue: #38bdf8;
        --led-red: #ef4444;
        --text: #e5e7eb;
        --muted: #9ca3af;
    }
    * { box-sizing: border-box; user-select: none; }
    body {
        margin: 0; padding: 12px;
        font-family: "Lucida Grande", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        background: var(--bg-body); color: var(--text); font-size: 11px;
    }
    .dcp-shell {
        max-width: 1440px; min-width: 1060px; margin: 0 auto;
        background: var(--chassis); border: 2px solid #454850; border-radius: 6px;
        box-shadow: 0 18px 45px rgba(0,0,0,0.85); overflow: hidden;
    }
    .dcp-topbar {
        display: flex; justify-content: space-between; align-items: center;
        padding: 7px 12px; background: linear-gradient(180deg, #383a40, #232428);
        border-bottom: 1px solid #111; gap: 10px; flex-wrap: wrap;
    }
    .dcp-top-group {
        display: flex; align-items: center; gap: 6px;
        background: #191a1d; padding: 4px 8px; border-radius: 4px; border: 1px solid var(--border);
    }
    .dcp-label { font-size: 10px; font-weight: 700; color: var(--muted); letter-spacing: 0.5px; }
    .dcp-btn, select.dcp-select, input.dcp-input {
        background: linear-gradient(180deg, #3a3c42, #25262a);
        color: #f3f4f6; border: 1px solid #4b4e57; border-radius: 3px;
        padding: 4px 9px; font-size: 10px; font-weight: 700; cursor: pointer;
    }
    .dcp-btn:hover { border-color: #888; background: #3c3f46; }
    .dcp-btn.active { background: var(--avid-amber); color: #000; border-color: #fbbf24; box-shadow: 0 0 8px rgba(245,158,11,0.5); }
    .dcp-btn.green.active { background: var(--avid-green); color: #000; border-color: #86efac; }

    .dcp-subbar {
        display: flex; justify-content: space-between; align-items: center;
        padding: 6px 12px; background: #1b1c20; border-bottom: 1px solid var(--border);
    }
    .mix-tabs, .func-tabs { display: flex; gap: 4px; align-items: center; }
    .mix-tab {
        padding: 5px 16px; font-size: 11px; font-weight: 700; cursor: pointer;
        background: #282a30; color: var(--muted); border: 1px solid var(--border); border-radius: 3px;
    }
    .mix-tab.active {
        background: #131417; color: var(--avid-amber); border-color: var(--avid-amber);
        box-shadow: inset 0 2px 0 var(--avid-amber);
    }

    /* Main Mixer Grid */
    .mixer-main {
        display: grid; grid-template-columns: 4fr 4fr 1.55fr; gap: 8px; padding: 10px;
    }
    .mixer-section-box {
        background: var(--panel); border: 1px solid var(--border); border-radius: 4px; padding: 8px;
    }
    .section-title {
        font-size: 11px; font-weight: 700; color: #d1d5db;
        padding-bottom: 6px; margin-bottom: 8px; border-bottom: 1px solid var(--border);
        display: flex; justify-content: space-between; align-items: center; gap: 4px;
    }
    .channels-grid-4 { display: grid; grid-template-columns: repeat(4, 1fr); gap: 6px; }

    .ch-strip {
        background: var(--strip); border: 1px solid #2e3036; border-radius: 4px;
        padding: 6px 5px; display: flex; flex-direction: column; align-items: center; gap: 6px;
    }
    .meter-wrap { display: flex; flex-direction: column; align-items: center; gap: 2px; cursor: pointer; }
    .clip-led {
        width: 18px; height: 7px; background: #331111; border: 1px solid #552222; border-radius: 1px;
    }
    .clip-led.clipped { background: var(--led-red); box-shadow: 0 0 8px var(--led-red); }
    .meter-track {
        width: 16px; height: 115px; background: #0b0c0e; border: 1px solid #333;
        border-radius: 2px; display: flex; flex-direction: column-reverse; overflow: hidden;
    }
    .meter-fill {
        width: 100%; height: 0%;
        background: linear-gradient(0deg, #22c55e 0%, #22c55e 65%, #eab308 85%, #ef4444 100%);
        transition: height 0.04s linear;
    }

    .knob-box { display: flex; flex-direction: column; align-items: center; width: 100%; }
    .knob-sub { font-size: 9px; color: var(--muted); display: flex; justify-content: space-between; width: 100%; padding: 0 2px; }
    input[type=range].pan-slider { width: 100%; height: 6px; accent-color: var(--avid-green); cursor: pointer; }

    .sm-row { display: flex; gap: 5px; justify-content: center; width: 100%; }
    .sm-btn {
        width: 24px; height: 20px; border-radius: 10px; border: 1px solid #555;
        background: #2b2d33; color: #ccc; font-size: 9px; font-weight: 800; cursor: pointer;
    }
    .sm-btn.solo.active { background: #eab308; color: #000; border-color: #fde047; box-shadow: 0 0 8px #eab308; }
    .sm-btn.mute.active { background: #ef4444; color: #fff; border-color: #fca5a5; box-shadow: 0 0 8px #ef4444; }

    .fader-well {
        height: 155px; width: 100%; display: flex; align-items: center; justify-content: center;
        position: relative; background: #141518; border: 1px solid #2c2e33; border-radius: 3px; padding: 6px 0;
    }
    .fader-scale {
        position: absolute; right: 3px; top: 6px; bottom: 6px;
        display: flex; flex-direction: column; justify-content: space-between;
        font-size: 8px; color: #666; pointer-events: none; text-align: right;
    }
    input[type=range].vert-fader {
        -webkit-appearance: slider-vertical; writing-mode: bt-lr;
        width: 22px; height: 135px; accent-color: #d1d5db; cursor: ns-resize;
    }

    .ch-label {
        width: 100%; background: #d1d5db; color: #111; font-size: 10px; font-weight: 700;
        text-align: center; padding: 3px 2px; border-radius: 2px; cursor: text;
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .ch-label.db-active { background: var(--avid-amber); color: #000; font-family: monospace; }

    .pair-links-row { display: grid; grid-template-columns: 1fr 1fr; gap: 6px; margin-top: 6px; }
    .link-pill {
        background: #282a30; border: 1px solid #444; color: var(--muted);
        border-radius: 10px; padding: 3px 0; text-align: center; font-size: 9px; font-weight: 700; cursor: pointer;
    }
    .link-pill.active { background: rgba(98, 217, 38, 0.22); border-color: var(--avid-green); color: var(--avid-green); }

    .effects-bar {
        display: grid; grid-template-columns: 4fr 4fr 1.55fr; gap: 8px; padding: 0 10px 10px 10px;
    }
    .fx-sends-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 6px; margin-bottom: 6px; }
    .fx-send-cell {
        background: var(--strip); border: 1px solid #2e3036; border-radius: 3px; padding: 5px;
        display: flex; flex-direction: column; align-items: center;
    }
    .dsp-params-bar {
        grid-column: span 2; background: #16171a; border: 1px solid var(--border);
        border-radius: 4px; padding: 8px 12px; display: flex; align-items: center; justify-content: space-between; gap: 12px;
        flex-wrap: wrap; min-width: 0; overflow: hidden;
    }
    .dsp-params-bar > div { min-width: 0; }

    /* Meters-Only Dual Output Bank (1/2 & 3/4 per p.44-45) */
    .meters-only-outputs { display: none; gap: 18px; justify-content: center; padding: 10px 0; }
    .dcp-shell.meters-only .hide-in-meters { display: none !important; }
    .dcp-shell.meters-only .meters-only-outputs { display: flex !important; }
    .dcp-shell.meters-only .meter-track { height: 220px; width: 20px; }

    /* Vertical Layout Overrides (Compact Console Stack per p.45) */
    .dcp-shell.vertical-layout { max-width: 580px; min-width: 0; }
    .dcp-shell.vertical-layout .mixer-main { grid-template-columns: 1fr; }
    .dcp-shell.vertical-layout .effects-bar { grid-template-columns: 1fr; }
    .dcp-shell.vertical-layout .dsp-params-bar { grid-column: span 1; flex-wrap: wrap; }

    .dcp-footer {
        display: flex; justify-content: space-between; align-items: center;
        background: #141518; border-top: 1px solid var(--border); padding: 6px 12px; font-size: 10px;
    }
    .status-indicators { display: flex; gap: 16px; align-items: center; }
    .status-item { display: flex; align-items: center; gap: 6px; font-weight: 700; color: var(--avid-green); }
    .status-item.off { color: #f59e0b; }
    .status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--avid-green); box-shadow: 0 0 6px var(--avid-green); }
    .status-item.off .status-dot { background: #f59e0b; box-shadow: none; }

    /* Engineering & Appendices Companion Tabs (Ch 5-6, App B, App C, App E, App F) */
    .companion-shell {
        max-width: 1440px; margin: 12px auto 0 auto;
        background: var(--chassis); border: 1px solid #3c3f46; border-radius: 6px; overflow: hidden;
    }
    .comp-tabs {
        display: flex; background: #18191d; border-bottom: 1px solid var(--border); padding: 4px 8px; gap: 6px;
    }
    .comp-tab {
        padding: 6px 12px; font-size: 10px; font-weight: 700; color: var(--muted);
        border: 1px solid transparent; border-radius: 4px; cursor: pointer;
    }
    .comp-tab.active { background: #26282e; color: var(--avid-amber); border-color: var(--border); }
    .comp-pane { display: none; padding: 12px; }
    .comp-pane.active { display: block; }

    .front-panel-chassis {
        background: linear-gradient(180deg, #2e3035, #1b1c20); border: 2px solid #555;
        border-radius: 26px; padding: 12px 18px; display: grid; grid-template-columns: 1fr 1fr 0.8fr 1fr 0.9fr; gap: 12px; align-items: center;
    }
    .fp-channel { border-right: 1px solid #444; padding-right: 10px; display: flex; flex-direction: column; gap: 5px; }
    .led-dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; background: #222; border: 1px solid #555; }
    .led-dot.green { background: #22c55e; box-shadow: 0 0 8px #22c55e; }
    .led-dot.red { background: #ef4444; box-shadow: 0 0 8px #ef4444; }
    .led-dot.blue { background: #38bdf8; box-shadow: 0 0 8px #38bdf8; }

    .midi-ch-grid { display: grid; grid-template-columns: repeat(16, 1fr); gap: 3px; margin: 4px 0 8px 0; }
    .midi-ch-btn {
        background: #22252a; border: 1px solid #444; color: #aaa; font-size: 9px;
        padding: 4px 0; text-align: center; border-radius: 2px; cursor: pointer; font-weight: 700;
    }
    .midi-ch-btn.active { background: #3b82f6; color: #fff; border-color: #93c5fd; }

    table.spec-table { width: 100%; border-collapse: collapse; font-size: 10px; }
    table.spec-table th, table.spec-table td { border: 1px solid var(--border); padding: 4px 8px; text-align: left; }
    table.spec-table th { background: #16171a; color: var(--avid-amber); }

    .modal-backdrop {
        display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.75);
        z-index: 1000; align-items: center; justify-content: center;
    }
    .modal-backdrop.open { display: flex; }
    .modal-win {
        background: #232428; border: 2px solid #555; border-radius: 6px; width: 640px; max-width: 95vw;
        box-shadow: 0 20px 60px rgba(0,0,0,0.9); overflow: hidden;
    }
    .modal-head {
        background: #18191c; padding: 10px 14px; font-size: 14px; font-weight: 800;
        color: var(--avid-amber); display: flex; justify-content: space-between; align-items: center;
        border-bottom: 1px solid var(--border);
    }
    .modal-body { padding: 14px; }
    .setup-group { border: 1px solid var(--border); border-radius: 4px; padding: 10px; margin-bottom: 10px; background: #1b1c1f; }
    .setup-group h4 { margin: 0 0 8px 0; font-size: 11px; color: #fff; border-bottom: 1px solid #2d2f34; padding-bottom: 4px; }
    .setup-row { display: flex; justify-content: space-between; align-items: center; margin: 6px 0; }

    /* Rotary knobs (Avid DCP style): hidden range input drives an SVG knob with green value arc */
    .rk { position: relative; cursor: ns-resize; touch-action: none; margin: 2px auto 0 auto; display: block; }
    .rk svg { display: block; overflow: visible; }
    .rk .rk-track { fill: none; stroke: #111216; stroke-linecap: round; }
    .rk .rk-arc { fill: none; stroke: var(--avid-green); stroke-linecap: round; filter: drop-shadow(0 0 2px rgba(98,217,38,0.55)); }
    .rk .rk-body { fill: url(#rkGrad); stroke: #0b0b0d; stroke-width: 1; }
    .rk .rk-ptr { stroke: #e5e7eb; stroke-linecap: round; }
    .rk:focus-visible { outline: 1px solid var(--avid-amber); border-radius: 50%; }
    input[type=range].pan-slider.rk-hidden { display: none; }
    .dsp-params-bar .rk { margin: 0; }
</style>
</head>
<body>

<div id="dcpShell" class="dcp-shell">
    <!-- TOP BAR: PRESETS + LAYOUT (Appendix A p.43-45) -->
    <div class="dcp-topbar">
        <div class="dcp-top-group">
            <span class="dcp-label">PRESETS</span>
            <select id="presetSelect" class="dcp-select" style="min-width:130px;"></select>
            <button class="dcp-btn" onclick="loadSelectedPreset()">LOAD</button>
            <button class="dcp-btn" onclick="savePresetPrompt()">SAVE AS...</button>
        </div>

        <div class="dcp-top-group">
            <span class="dcp-label">LAYOUT</span>
            <select id="layoutSelect" class="dcp-select" onchange="changeLayout(this.value)">
                <option value="horizontal">Horizontal</option>
                <option value="horizontal_meters">Horizontal (Meters only)</option>
                <option value="vertical">Vertical</option>
                <option value="vertical_meters">Vertical (Meters only)</option>
            </select>
        </div>
    </div>

    <!-- SUB BAR: STEREO MIX TABS (Analog 1/2 | S/PDIF L/R) + ADDITIONAL FUNCTIONS (TUNER | SETUP | FLOW | ABOUT) -->
    <div class="dcp-subbar">
        <div class="mix-tabs">
            <div id="tabAnalog" class="mix-tab active" onclick="switchMixBus('analog')">Analog 1/2</div>
            <div id="tabSpdif" class="mix-tab" onclick="switchMixBus('spdif')">S/PDIF L/R</div>
        </div>
        <div class="func-tabs">
            <button id="topBtnTuner" class="dcp-btn" onclick="openModal('tunerModal'); toggleTuner(true); startWebAudioTuner();">TUNER</button>
            <button class="dcp-btn" onclick="openModal('setupModal')">SETUP</button>
            <button class="dcp-btn" onclick="openModal('flowModal')">FLOW</button>
            <button class="dcp-btn" onclick="openModal('aboutModal')">ABOUT</button>
        </div>
    </div>

    <!-- MAIN MIXER SECTION -->
    <div class="mixer-main">
        <!-- Hardware Inputs 1-4 -->
        <div class="mixer-section-box">
            <div class="section-title">
                <span>Hardware Inputs</span>
                <span style="font-size:9px; color:var(--muted);" id="meterModeBadge">Post-Fader</span>
            </div>
            <div id="hwChannelsGrid" class="channels-grid-4"></div>
            <div class="pair-links-row hide-in-meters">
                <div id="link_hw12" class="link-pill active" onclick="toggleLink('hw12')">🔗 Link In 1–2</div>
                <div id="link_hw34" class="link-pill active" onclick="toggleLink('hw34')">🔗 Link In 3–4 (S/PDIF)</div>
            </div>
        </div>

        <!-- Software Returns 1-4 -->
        <div class="mixer-section-box">
            <div class="section-title">
                <span>Software Returns</span>
                <span style="font-size:9px; color:var(--muted);">Double-click knob/fader = Reset</span>
            </div>
            <div id="swChannelsGrid" class="channels-grid-4"></div>
            <div class="pair-links-row hide-in-meters">
                <div id="link_sw12" class="link-pill active" onclick="toggleLink('sw12')">🔗 Link Ret 1–2</div>
                <div id="link_sw34" class="link-pill active" onclick="toggleLink('sw34')">🔗 Link Ret 3–4</div>
            </div>
        </div>

        <!-- Master Section (with Stereo Mix Copy Pull-On in top-right per p.53) -->
        <div class="mixer-section-box">
            <div class="section-title">
                <span>Master</span>
                <select class="dcp-select hide-in-meters" style="font-size:9px; padding:2px 4px;" onchange="if(this.value){copyStereoMix(); this.value='';}" title="Stereo Mix Copy pull-on (p.53)">
                    <option value="">Copy Mix ▾</option>
                    <option value="copy">Copy to Other Stereo Mix</option>
                </select>
            </div>

            <!-- Normal Master Controls + Meter -->
            <div class="hide-in-meters" style="display:flex; gap:10px; align-items:center; justify-content:space-between;">
                <div style="flex:1; display:flex; flex-direction:column; gap:6px;">
                    <div class="knob-box">
                        <div class="knob-sub"><span>Balance</span><span id="lblMasterBal">C</span></div>
                        <input id="masterBal" type="range" class="pan-slider" min="-50" max="50" value="0"
                               oninput="updateMaster('balance', this.value)" ondblclick="this.value=0; updateMaster('balance', 0)">
                    </div>
                    <div class="knob-box">
                        <div class="knob-sub"><span>Width</span><span id="lblMasterWidth">100%</span></div>
                        <input id="masterWidth" type="range" class="pan-slider" min="0" max="100" value="100"
                               oninput="updateMaster('width', this.value)" ondblclick="this.value=100; updateMaster('width', 100)">
                    </div>
                    <div class="sm-row">
                        <button id="masterMuteL" class="sm-btn mute" onclick="toggleMasterMute('mute_l')">M L</button>
                        <button id="masterMuteR" class="sm-btn mute" onclick="toggleMasterMute('mute_r')">M R</button>
                    </div>
                    <button id="masterSwap" class="dcp-btn" onclick="toggleMasterBool('swap')">SWAP</button>
                    <div class="fader-well" style="height:130px;">
                        <div class="fader-scale"><span>0</span><span>-5</span><span>-10</span><span>-15</span><span>-20</span><span>-30</span><span>-50</span><span>-70</span></div>
                        <input id="masterFader" type="range" class="vert-fader" style="height:115px;" min="0" max="100" value="85"
                               oninput="updateMaster('fader', this.value)" ondblclick="this.value=85; updateMaster('fader', 85)">
                    </div>
                </div>

                <div style="display:flex; gap:5px; align-items:flex-end;">
                    <div class="meter-wrap" onclick="clearClips()">
                        <div id="clip_outL" class="clip-led"></div>
                        <div class="meter-track" style="height:220px;"><div id="meter_outL" class="meter-fill"></div></div>
                        <span style="font-size:9px; color:var(--muted);">L</span>
                    </div>
                    <div class="meter-wrap" onclick="clearClips()">
                        <div id="clip_outR" class="clip-led"></div>
                        <div class="meter-track" style="height:220px;"><div id="meter_outR" class="meter-fill"></div></div>
                        <span style="font-size:9px; color:var(--muted);">R</span>
                    </div>
                </div>
            </div>

            <!-- Meters-Only Hardware Outputs (1/2 & 3/4 side-by-side per p.44) -->
            <div class="meters-only-outputs">
                <div style="text-align:center;">
                    <div style="font-weight:700; margin-bottom:4px;">1/2</div>
                    <div style="display:flex; gap:4px;">
                        <div class="meter-track"><div id="mo_out1" class="meter-fill"></div></div>
                        <div class="meter-track"><div id="mo_out2" class="meter-fill"></div></div>
                    </div>
                </div>
                <div style="text-align:center;">
                    <div style="font-weight:700; margin-bottom:4px;">3/4</div>
                    <div style="display:flex; gap:4px;">
                        <div class="meter-track"><div id="mo_out3" class="meter-fill"></div></div>
                        <div class="meter-track"><div id="mo_out4" class="meter-fill"></div></div>
                    </div>
                </div>
            </div>

            <div class="ch-label hide-in-meters" id="masterLabel" style="margin-top:6px;">L/R</div>
            <div id="link_master" class="link-pill active hide-in-meters" style="margin-top:5px;" onclick="toggleLink('master')" title="Links FX Returns section and Master Mute L/R buttons (p.54)">🔗 Link Master Mutes &amp; FX Ret</div>
            <div class="hide-in-meters" style="display:grid; grid-template-columns:1fr 1fr; gap:6px; margin-top:6px;">
                <button id="btnDim" class="dcp-btn" onclick="toggleGlobal('dim')">DIM</button>
                <button id="btnMono" class="dcp-btn green" onclick="toggleGlobal('mono')">MONO</button>
            </div>
        </div>
    </div>

    <!-- EFFECTS SECTION (p.51-53) -->
    <div class="effects-bar hide-in-meters">
        <div class="mixer-section-box">
            <div class="section-title"><span>HARDWARE INPUT FX SENDS</span><span id="fxSendModeLbl" style="font-size:9px; color:var(--muted);">Post-Fader</span></div>
            <div id="hwFxSendsGrid" class="fx-sends-grid"></div>
        </div>

        <div class="mixer-section-box">
            <div class="section-title"><span>SOFTWARE RETURN FX SENDS</span><span style="font-size:9px; color:var(--muted);">Shared</span></div>
            <div id="swFxSendsGrid" class="fx-sends-grid"></div>
        </div>

        <!-- FX Returns Strip -->
        <div class="mixer-section-box" style="grid-row: span 2;">
            <div class="section-title"><span>FX Returns</span><span style="font-size:9px; color:var(--muted);">Per-Mix</span></div>
            <div style="display:flex; justify-content:space-around; align-items:center; gap:6px;">
                <div style="flex:1;">
                    <div class="knob-sub"><span>FX Ret L</span><span id="lblFxRetL">-∞</span></div>
                    <input id="fxRetL" type="range" class="pan-slider" min="0" max="100" value="0" oninput="updateFxRet('l', this.value)" ondblclick="this.value=85; updateFxRet('l', 85)">
                    <div class="knob-sub" style="margin-top:6px;"><span>FX Ret R</span><span id="lblFxRetR">-∞</span></div>
                    <input id="fxRetR" type="range" class="pan-slider" min="0" max="100" value="0" oninput="updateFxRet('r', this.value)" ondblclick="this.value=85; updateFxRet('r', 85)">
                    <div class="sm-row" style="margin-top:8px;">
                        <button id="fxSoloL" class="sm-btn solo" onclick="toggleFxRetBool('solo_l')">S</button>
                        <button id="fxMuteL" class="sm-btn mute" onclick="toggleFxRetBool('mute_l')">M</button>
                        <button id="fxSoloR" class="sm-btn solo" onclick="toggleFxRetBool('solo_r')">S</button>
                        <button id="fxMuteR" class="sm-btn mute" onclick="toggleFxRetBool('mute_r')">M</button>
                    </div>
                </div>
                <div style="display:flex; gap:4px;" title="Clip LED shows clipping at FX input or output (p.53)">
                    <div class="meter-wrap" onclick="clearClips()">
                        <div id="clip_fxL" class="clip-led"></div>
                        <div class="meter-track" style="height:95px;"><div id="meter_fxL" class="meter-fill"></div></div>
                    </div>
                    <div class="meter-wrap" onclick="clearClips()">
                        <div id="clip_fxR" class="clip-led"></div>
                        <div class="meter-track" style="height:95px;"><div id="meter_fxR" class="meter-fill"></div></div>
                    </div>
                </div>
            </div>
        </div>

        <!-- DSP Effect Type, Duration, Feedback, Volume Bar -->
        <div class="dsp-params-bar">
            <div style="display:flex; align-items:center; gap:8px;">
                <span class="dcp-label" style="color:var(--avid-amber);">EFFECT</span>
                <select id="dspEffectSelect" class="dcp-select" onchange="updateDsp('effect', this.value)">
                    <option value="0">Room 1</option>
                    <option value="1">Room 2</option>
                    <option value="2">Room 3</option>
                    <option value="3">Hall 1</option>
                    <option value="4">Hall 2</option>
                    <option value="5">Plate</option>
                    <option value="6">Delay</option>
                    <option value="7">Echo</option>
                </select>
            </div>
            <div style="flex:1; display:flex; align-items:center; gap:6px;">
                <span class="dcp-label">Duration</span>
                <input id="dspDuration" type="range" class="pan-slider" min="0" max="100" value="50" oninput="updateDsp('duration', this.value)">
                <span id="lblDspDur" style="width:32px; font-family:monospace;">50%</span>
            </div>
            <div id="dspFeedbackWrap" style="flex:1; display:flex; align-items:center; gap:6px; opacity:0.35;">
                <span class="dcp-label" title="Controls number of repeats for Delay & Echo only; does not affect reverbs (p.53)">Feedback</span>
                <input id="dspFeedback" type="range" class="pan-slider" min="0" max="100" value="40" oninput="updateDsp('feedback', this.value)">
                <span id="lblDspFb" style="width:32px; font-family:monospace;">40%</span>
            </div>
            <div style="flex:1; display:flex; align-items:center; gap:6px;">
                <span class="dcp-label">Volume</span>
                <input id="dspVolume" type="range" class="pan-slider" min="0" max="100" value="0" oninput="updateDsp('volume', this.value)">
                <span id="lblDspVol" style="width:32px; font-family:monospace;">0%</span>
            </div>
        </div>
    </div>

    <!-- STATUS INDICATORS FOOTER (p.54) -->
    <div class="dcp-footer">
        <div class="status-indicators">
            <div id="stConnected" class="status-item"><span class="status-dot"></span><span id="stConnectedTxt">Hardware Connected</span></div>
            <div id="stStreaming" class="status-item"><span class="status-dot"></span><span id="stStreamingTxt">Streaming</span></div>
            <div id="stHostCtrl" class="status-item"><span class="status-dot"></span><span id="stHostCtrlTxt">Host Control Enabled</span></div>
        </div>
        <div style="color:var(--muted);">
            Firmware: <strong id="footerFw" style="color:#fff;">1.04</strong> |
            Clock: <strong id="footerClock" style="color:#fff;">INTERNAL</strong> |
            Sample Rate: <strong id="footerSr" style="color:#fff;">48.0 kHz</strong>
        </div>
    </div>
</div>

<!-- COMPANION HARDWARE & APPENDICES WORKBENCH (Ch 5-6, App B, App C, App E, App F) -->
<div class="companion-shell">
    <div class="comp-tabs">
        <div class="comp-tab active" onclick="openCompTab(0)">Ch. 5 &amp; 6: Front &amp; Rear Hardware Surface</div>
        <div class="comp-tab" onclick="openCompTab(1)">Appendix B: Multi Button &amp; Tap Tempo</div>
        <div class="comp-tab" onclick="openCompTab(2)">Appendix C: Audio MIDI Setup (AMS) &amp; .midnam</div>
        <div class="comp-tab" onclick="openCompTab(3)">Appendix E &amp; F: Drive Space (Table 6) &amp; System Diagnostics</div>
    </div>

    <!-- TAB 0: FRONT & REAR HARDWARE PANEL -->
    <div id="compPane0" class="comp-pane active">
        <div class="front-panel-chassis">
            <div class="fp-channel">
                <div style="display:flex; justify-content:space-between; align-items:center;">
                    <strong style="font-size:13px;">INPUT 01 (Left)</strong>
                    <span>Sig/Clip <span id="fpLed1" class="led-dot green"></span></span>
                </div>
                <div style="display:flex; gap:4px;">
                    <button id="fpPad1" class="dcp-btn" onclick="toggleFp('in1_pad')" title="Pull Gain knob out = -20dB pad (p.31)">Pull -20dB Pad</button>
                    <button id="fpLimit1" class="dcp-btn" onclick="toggleFp('in1_soft_limit')" title="Smooth tape-type limiting (p.32)">Soft Limit</button>
                </div>
                <button id="fpSrc1" class="dcp-btn" onclick="toggleFpSource(1)">Source: Rear (Mic XLR / Line TRS)</button>
            </div>

            <div class="fp-channel">
                <div style="display:flex; justify-content:space-between; align-items:center;">
                    <strong style="font-size:13px;">INPUT 02 (Right)</strong>
                    <span>Sig/Clip <span id="fpLed2" class="led-dot green"></span></span>
                </div>
                <div style="display:flex; gap:4px;">
                    <button id="fpPad2" class="dcp-btn" onclick="toggleFp('in2_pad')">Pull -20dB Pad</button>
                    <button id="fpLimit2" class="dcp-btn" onclick="toggleFp('in2_soft_limit')">Soft Limit</button>
                </div>
                <button id="fpSrc2" class="dcp-btn" onclick="toggleFpSource(2)">Source: Rear (Mic XLR / Line TRS)</button>
            </div>

            <div class="fp-channel" style="align-items:center;">
                <button class="dcp-btn" style="width:100%;" onmousedown="multiBtnDown()" onmouseup="multiBtnUp()">MULTI BUTTON</button>
                <button id="fp48v" class="dcp-btn" style="width:100%; margin-top:4px;" onclick="togglePhantom48v()">+48V Phantom (XLR)</button>
                <div id="ribbonTimerMsg" style="font-size:9px; color:var(--avid-amber); text-align:center;">Max 4 mA/mic | Wait ≥10s for Ribbon Mics</div>
            </div>

            <div class="fp-channel">
                <div style="display:flex; justify-content:space-between;">
                    <span>USB Power/Clock LED: <span id="fpUsbLed" class="led-dot blue"></span></span>
                    <span>Phones (Mirrors Out 1–2)</span>
                </div>
                <div style="font-size:9px; color:var(--muted); line-height:1.35;">
                    <strong>Rear Alignment (p.35):</strong> Viewed from back: USB 2.0 → MIDI In/Out → S/PDIF RCA (75Ω coax ≤10m) → Line Out L/R → <strong>Mic/Line 02 (Left)</strong> → <strong>Mic/Line 01 (Right, directly behind Front 01)</strong>.
                </div>
            </div>

            <div style="display:flex; flex-direction:column; gap:5px;">
                <button class="dcp-btn" onclick="openModal('tunerModal'); toggleTuner(true); startWebAudioTuner();">Push Dim + Mono (Tuner)</button>
                <button class="dcp-btn" onclick="runCmd('init')">Hardware Reset (Init)</button>
            </div>
        </div>
    </div>

    <!-- TAB 1: APPENDIX B MULTI BUTTON FUNCTION PANE -->
    <div id="compPane1" class="comp-pane">
        <div style="display:grid; grid-template-columns: 1fr 1fr 1fr; gap:14px; align-items:center;">
            <div class="setup-group" style="margin:0;">
                <h4>Soft Button Function (Hardware Setup Dialog, p.56–58)</h4>
                <div class="setup-row">
                    <span>Press and Release (11 options):</span>
                    <select id="multiRelease" class="dcp-select" onchange="saveMultiBtn()">
                        <option>None</option><option>Add Last Track</option><option>Add Selected Track</option>
                        <option>Cursor to Next Marker</option><option>Cursor to Previous Marker</option>
                        <option>Start/Stop Playback</option><option selected>Start/Stop Record</option>
                        <option>Loop Playback Toggle</option><option>Undo</option><option>Save Session</option>
                        <option>Tap Tempo</option>
                    </select>
                </div>
                <div class="setup-row">
                    <span>Press and Hold (10 options, p.57):</span>
                    <select id="multiHold" class="dcp-select" onchange="saveMultiBtn()">
                        <option>None</option><option>Add Last Track</option><option selected>Add Selected Track</option>
                        <option>Cursor to Next Marker</option><option>Cursor to Previous Marker</option>
                        <option>Start/Stop Playback</option><option>Start/Stop Record</option>
                        <option>Loop Playback Toggle</option><option>Undo</option><option>Save Session</option>
                    </select>
                </div>
                <div class="setup-row">
                    <span>Hold Duration:</span>
                    <select id="multiHoldDur" class="dcp-select" onchange="document.getElementById('selHoldDuration').value=this.value; updateSetup();">
                        <option value="250">250 msec</option><option value="500" selected>500 msec</option>
                        <option value="750">750 msec</option><option value="1000">1 sec</option>
                    </select>
                </div>
            </div>

            <div class="setup-group" style="margin:0; text-align:center;">
                <h4>Interactive Multi-Button Test &amp; Tap Tempo</h4>
                <button class="dcp-btn active" style="padding:10px 22px; font-size:12px;" onmousedown="multiBtnDown()" onmouseup="multiBtnUp()">
                    PRESS / HOLD MULTI BUTTON
                </button>
                <div id="multiStatusReadout" style="margin-top:8px; color:var(--avid-green); font-family:monospace;">
                    Last Action: Ready | Tap Tempo: 120.0 BPM
                </div>
            </div>

            <div class="setup-group" style="margin:0;">
                <h4>Quick Recording Workflow (p.56)</h4>
                <div style="font-size:10px; color:var(--muted); line-height:1.45;">
                    1. Hold Multi for <strong>500 msec</strong> → Releases <em>Add Selected Track</em> in Record-Enable mode.<br>
                    2. Press &amp; immediately release Multi → <em>Start/Stop Record</em> begins recording.<br>
                    3. Select <em>Tap Tempo</em> to exit Conductor mode and match tapped BPM.
                </div>
            </div>
        </div>
    </div>

    <!-- TAB 2: APPENDIX C AUDIO MIDI SETUP (AMS) & .MIDNAM PATCH SUPPORT -->
    <div id="compPane2" class="comp-pane">
        <div style="display:grid; grid-template-columns: 1.3fr 1fr; gap:12px;">
            <div class="setup-group" style="margin:0;">
                <h4>External MIDI Device Properties (16-Channel Transmit/Receive Matrix, p.60–61)</h4>
                <div style="display:flex; gap:8px; margin-bottom:8px;">
                    <label>Device Name: <input id="amsName" class="dcp-input" value="JP-8000"></label>
                    <label>Manufacturer: <input id="amsMfg" class="dcp-input" value="Roland" style="width:90px;"></label>
                    <label>Model: <input id="amsModel" class="dcp-input" value="JP-8000" style="width:85px;"></label>
                    <label>SysEx ID: <input id="amsSysex" class="dcp-input" value="17" style="width:45px;"></label>
                </div>
                <div>Transmits Channels (1–16):</div>
                <div id="amsTxGrid" class="midi-ch-grid"></div>
                <div>Receives Channels (1–16):</div>
                <div id="amsRxGrid" class="midi-ch-grid"></div>
                <div style="display:flex; gap:14px; margin-top:6px;">
                    <label><input type="checkbox"> MIDI Beat Clock</label>
                    <label><input type="checkbox"> MIDI Time Code (MTC)</label>
                    <label><input type="checkbox"> General MIDI</label>
                    <label><input type="checkbox"> MIDI Machine Control (MMC)</label>
                </div>
            </div>

            <div class="setup-group" style="margin:0;">
                <h4>MIDI Patch Name Support (.midnam / .middev Inspector, p.60–62)</h4>
                <div style="font-size:10px; color:var(--muted); margin-bottom:6px;">
                    Note: Only USB MIDI interfaces are compatible on macOS (serial-to-modem adapters unsupported, p.42).
                </div>
                <div id="amsFilesList" style="background:#121316; padding:6px; border-radius:3px; font-family:monospace; font-size:9px; max-height:85px; overflow-y:auto; margin-bottom:8px;">
                    Scanning /Library/Audio/MIDI Devices &amp; MIDI Patch Names...
                </div>
                <div style="display:flex; gap:8px;">
                    <button class="dcp-btn" onclick="fetch('/api/open-ams')">Launch macOS Audio MIDI Setup</button>
                    <button class="dcp-btn" onclick="loadSystemDiagnostics()">Rescan .midnam / .middev</button>
                </div>
            </div>
        </div>
    </div>

    <!-- TAB 3: APPENDIX E & F DRIVE SPACE (TABLE 6) & TROUBLESHOOTING AUDITOR -->
    <div id="compPane3" class="comp-pane">
        <div style="display:grid; grid-template-columns: 1.3fr 1fr; gap:12px;">
            <div>
                <table class="spec-table">
                    <thead>
                        <tr>
                            <th>Table 6: Tracks &amp; Length (p.72)</th>
                            <th>16-bit @ 44.1 kHz</th>
                            <th>16-bit @ 48 kHz</th>
                            <th>24-bit @ 44.1 kHz</th>
                            <th>24-bit @ 48 kHz</th>
                        </tr>
                    </thead>
                    <tbody>
                        <tr><td>1 mono track, 1 minute</td><td>5 MB</td><td>5.5 MB</td><td>7.5 MB</td><td>8.2 MB</td></tr>
                        <tr><td>1 stereo track (2 mono), 5 min</td><td>50 MB</td><td>55 MB</td><td>75 MB</td><td>83 MB</td></tr>
                        <tr><td>1 stereo track (2 mono), 60 min</td><td>600 MB</td><td>662 MB</td><td>900 MB</td><td>991 MB</td></tr>
                        <tr><td>24 mono tracks, 5 minutes</td><td>600 MB</td><td>662 MB</td><td>900 MB</td><td>991 MB</td></tr>
                        <tr><td>24 mono tracks, 60 minutes</td><td>7 GB</td><td>7.8 GB</td><td>10.5 GB</td><td>11.6 GB</td></tr>
                        <tr><td>32 mono tracks, 5 minutes</td><td>800 MB</td><td>883 MB</td><td>1.2 GB</td><td>1.3 GB</td></tr>
                        <tr><td>32 mono tracks, 60 minutes</td><td>9.4 GB</td><td>10.4 GB</td><td>14 GB</td><td>15.4 GB</td></tr>
                    </tbody>
                </table>
            </div>

            <div class="setup-group" style="margin:0;">
                <h4>Custom Track Calculator &amp; Appendix E/F System Audit (p.67–74)</h4>
                <div style="display:flex; gap:6px; align-items:center; margin-bottom:6px;">
                    <input id="calcTracks" type="number" class="dcp-input" value="24" min="1" max="256" style="width:55px;" oninput="calcStorage()">
                    <span>Tracks ×</span>
                    <input id="calcMins" type="number" class="dcp-input" value="60" min="1" max="600" style="width:55px;" oninput="calcStorage()">
                    <span>Min @</span>
                    <select id="calcFormat" class="dcp-select" onchange="calcStorage()">
                        <option value="5.0">16-bit / 44.1 kHz</option>
                        <option value="5.5">16-bit / 48 kHz</option>
                        <option value="7.5">24-bit / 44.1 kHz</option>
                        <option value="8.2" selected>24-bit / 48 kHz</option>
                    </select>
                </div>
                <div id="calcResult" style="color:var(--avid-green); font-family:monospace; margin-bottom:6px;">
                    Est: 11.53 GB (11808 MB) | Single file limit: 3.4 GB max
                </div>
                <div id="sysAuditBox" style="background:#121316; padding:6px; border-radius:3px; font-size:9px; color:#ccc; line-height:1.4;">
                    Click "Run Appendix E/F Audit" to verify RAM, Volumes (HFS+ Journaled non-case-sensitive), and Disk Sleep.
                </div>
                <button class="dcp-btn" style="margin-top:6px;" onclick="loadSystemDiagnostics()">Run Appendix E/F System Audit</button>
            </div>
        </div>
    </div>
</div>

<!-- MODAL 1: TUNER (p.33, p.46) -->
<div id="tunerModal" class="modal-backdrop">
    <div class="modal-win">
        <div class="modal-head">
            <span>Tuner (Front Panel Dim + Mono Simultaneous Press)</span>
            <button class="dcp-btn" onclick="toggleTuner(false); stopWebAudioTuner(); closeModal('tunerModal')">Close</button>
        </div>
        <div class="modal-body" style="text-align:center;">
            <p style="color:var(--muted); margin-top:0;">
                Inverse Front-Panel LED Logic (p.33): <strong>Input 1 Red</strong> = Flat (Too Low) |
                <strong>Input 2 Red</strong> = Sharp (Too High) | <strong>Both Green</strong> = Correct Pitch
            </p>
            <div style="background:#111; border:1px solid #444; padding:18px; border-radius:6px; margin:12px 0;">
                <div style="display:flex; justify-content:space-between; color:var(--avid-amber); font-weight:700; margin-bottom:6px;">
                    <span>-50 cents</span><span>0</span><span>+50 cents</span>
                </div>
                <div style="height:26px; background:#1c1d21; border:1px solid #333; position:relative; border-radius:3px;">
                    <div id="tunerNeedle" style="position:absolute; left:50%; top:0; bottom:0; width:4px; background:var(--avid-amber); transform:translateX(-50%); transition:left 0.08s;"></div>
                </div>
                <div style="font-size:30px; font-weight:900; color:var(--avid-amber); margin-top:12px;" id="tunerNoteDisplay">► A (440 Hz) ◄</div>
                <div style="display:flex; justify-content:center; gap:24px; margin-top:10px;">
                    <span>Input 1 Sig/Clip LED: <span id="tunerLed1" class="led-dot green"></span></span>
                    <span>Input 2 Sig/Clip LED: <span id="tunerLed2" class="led-dot green"></span></span>
                </div>
            </div>
            <div style="display:flex; gap:8px; justify-content:center; align-items:center;">
                <span class="dcp-label">Pitch Input</span>
                <select id="tunerInputSelect" class="dcp-select" style="min-width:220px;" onchange="startWebAudioTuner(this.value)"></select>
            </div>
            <p id="tunerHint" style="color:var(--muted); font-size:10px; margin:8px 0 0 0;">
                The Mbox hardware tuner is active: the front-panel Sig/Clip LEDs show tuning. The Mbox does not send pitch over USB,
                so the on-screen needle listens to the audio input selected above (choose the Mbox if an audio driver exposes it, otherwise a mic near the guitar).
            </p>
        </div>
    </div>
</div>

<!-- MODAL 2: SETUP (p.46-49) -->
<div id="setupModal" class="modal-backdrop">
    <div class="modal-win">
        <div class="modal-head">
            <span>Setup</span>
            <button class="dcp-btn" onclick="closeModal('setupModal')">Close</button>
        </div>
        <div class="modal-body">
            <div class="setup-group">
                <h4>Hardware Settings</h4>
                <div class="setup-row">
                    <label title="Uncheck to use Low Latency Monitoring in Pro Tools (p.47)">
                        <input type="checkbox" id="chkDisableHost" onchange="updateSetup()"> Disable Host Control
                    </label>
                    <div>Sample Rate:
                        <select id="selSampleRate" class="dcp-select" onchange="updateSetup()">
                            <option value="44100">44100</option>
                            <option value="48000" selected>48000</option>
                            <option value="88200">88200</option>
                            <option value="96000">96000</option>
                        </select>
                    </div>
                </div>
                <div class="setup-row">
                    <div>Clock Source:
                        <select id="selClockSource" class="dcp-select" onchange="updateSetup()">
                            <option value="internal">Internal</option>
                            <option value="spdif">S/PDIF (Activates S/PDIF In 3–4)</option>
                        </select>
                    </div>
                    <div>Buffer Size (Latency):
                        <select id="selBufferSize" class="dcp-select" onchange="updateSetup()">
                            <option value="64">64</option><option value="128">128</option>
                            <option value="256" selected>256</option><option value="512">512</option><option value="1024">1024</option>
                        </select>
                    </div>
                </div>
                <div id="clockBanner" style="background:#141518; padding:6px 10px; border-radius:3px; color:var(--muted); font-size:10px; margin-top:6px;">
                    External clock not detected, Sample rate fixed at 48 kHz.
                </div>
            </div>

            <div class="setup-group">
                <h4>Soft Button Settings (Multi, +48V, Mono, Dim)</h4>
                <div class="setup-row">
                    <div>Hold Duration:
                        <select id="selHoldDuration" class="dcp-select" onchange="updateSetup()">
                            <option value="250">250 ms</option>
                            <option value="500" selected>500 ms</option>
                            <option value="750">750 ms</option>
                            <option value="1000">1 sec</option>
                        </select>
                    </div>
                    <label><input type="checkbox" id="chkDimLeds" onchange="updateSetup()"> Use Dim LEDs for Button Off State</label>
                </div>
            </div>

            <div class="setup-group">
                <h4>Driver Control Panel Options</h4>
                <div class="setup-row">
                    <label><input type="checkbox" id="chkHoldClips" checked onchange="updateSetup()"> Hold Clipping Indicators until Clicked</label>
                </div>
                <div class="setup-row">
                    <label><input type="checkbox" id="chkLoadLatency" onchange="updateSetup()"> Load Latency and Clock Settings from Settings Files</label>
                </div>
                <div class="setup-row" style="gap:10px;">
                    <select id="selMeterMode" class="dcp-select" style="flex:1;" onchange="updateSetup()">
                        <option value="post">Post-Fader Meters</option>
                        <option value="pre">Pre-Fader Meters</option>
                    </select>
                    <select id="selFxSendMode" class="dcp-select" style="flex:1;" onchange="updateSetup()">
                        <option value="post">Post-Fader (Mix 1/2) FX Sends</option>
                        <option value="pre">Pre-Fader FX Sends</option>
                    </select>
                </div>
            </div>
        </div>
    </div>
</div>

<!-- MODAL 3: FLOW (p.49) -->
<div id="flowModal" class="modal-backdrop">
    <div class="modal-win" style="width:700px;">
        <div class="modal-head">
            <span>Flow — Hardware Signal Flow Diagram (p.49)</span>
            <button class="dcp-btn" onclick="closeModal('flowModal')">Close</button>
        </div>
        <div class="modal-body">
            <svg viewBox="0 0 650 280" style="width:100%; background:#17181b; border:1px solid #333; border-radius:4px;">
                <g fill="#282a30" stroke="#888" stroke-width="1.5" font-family="sans-serif" font-size="11">
                    <rect x="20" y="25" width="90" height="26" rx="3"/><text x="65" y="42" fill="#fff" stroke="none" text-anchor="middle">In 1</text>
                    <rect x="20" y="65" width="90" height="26" rx="3"/><text x="65" y="82" fill="#fff" stroke="none" text-anchor="middle">In 2</text>
                    <rect x="20" y="105" width="90" height="26" rx="3"/><text x="65" y="122" fill="#fff" stroke="none" text-anchor="middle">S/PDIF L</text>
                    <rect x="20" y="145" width="90" height="26" rx="3"/><text x="65" y="162" fill="#fff" stroke="none" text-anchor="middle">S/PDIF R</text>
                    <rect x="235" y="25" width="110" height="80" rx="4" stroke="#f59e0b"/>
                    <text x="290" y="55" fill="#f59e0b" stroke="none" text-anchor="middle" font-weight="bold">USB to and</text>
                    <text x="290" y="75" fill="#fff" stroke="none" text-anchor="middle">from Host</text>
                    <rect x="195" y="135" width="210" height="32" rx="4" stroke="#62d926"/>
                    <text x="300" y="155" fill="#62d926" stroke="none" text-anchor="middle" font-weight="bold">Out 1/2 Mixer</text>
                    <rect x="195" y="182" width="210" height="32" rx="4" stroke="#38bdf8"/>
                    <text x="300" y="202" fill="#38bdf8" stroke="none" text-anchor="middle" font-weight="bold">Out 3/4 Mixer</text>
                    <rect x="195" y="228" width="210" height="32" rx="4" stroke="#8b5cf6"/>
                    <text x="300" y="248" fill="#c4b5fd" stroke="none" text-anchor="middle" font-weight="bold">DSP FX</text>
                    <rect x="520" y="100" width="105" height="26" rx="3"/><text x="572" y="117" fill="#fff" stroke="none" text-anchor="middle">Phones</text>
                    <rect x="520" y="135" width="105" height="26" rx="3"/><text x="572" y="152" fill="#fff" stroke="none" text-anchor="middle">Out 1</text>
                    <rect x="520" y="170" width="105" height="26" rx="3"/><text x="572" y="187" fill="#fff" stroke="none" text-anchor="middle">Out 2</text>
                    <rect x="520" y="205" width="105" height="26" rx="3"/><text x="572" y="222" fill="#fff" stroke="none" text-anchor="middle">S/PDIF L</text>
                    <rect x="520" y="240" width="105" height="26" rx="3"/><text x="572" y="257" fill="#fff" stroke="none" text-anchor="middle">S/PDIF R</text>
                </g>
                <g stroke="#62d926" stroke-width="1.5" fill="none">
                    <path d="M110 38 H235 M110 78 H235 M110 118 H235 M110 158 H235"/>
                    <path d="M145 38 V240 M160 78 V240 M175 118 V240 M190 158 V240"/>
                    <path d="M405 151 H520 M480 151 V113 H520 M480 151 V183 H520"/>
                    <path d="M405 198 H460 V218 H520 M460 218 V253 H520" stroke="#38bdf8"/>
                    <path d="M405 244 H440 V151 M440 198" stroke="#8b5cf6"/>
                </g>
            </svg>
        </div>
    </div>
</div>

<!-- MODAL 4: ABOUT (p.49) -->
<div id="aboutModal" class="modal-backdrop">
    <div class="modal-win">
        <div class="modal-head">
            <span>Mbox © 2010 Avid Technology, Inc.</span>
            <button class="dcp-btn" onclick="closeModal('aboutModal')">Close</button>
        </div>
        <div class="modal-body">
            <div style="background:#151619; border:1px solid #333; padding:16px; border-radius:4px; text-align:center; margin-bottom:12px;">
                <div style="font-size:22px; font-weight:900; color:#a855f7; letter-spacing:3px;">AVID MBOX 3</div>
                <div style="color:var(--muted); margin-top:4px;">USB 2.0 4-In / 4-Out 24-bit Digital Audio &amp; MIDI Interface</div>
            </div>
            <div style="display:flex; justify-content:space-between; align-items:center;">
                <div>
                    <div><strong>Package:</strong> 1.0.10</div>
                    <div><strong>Firmware:</strong> <span id="aboutFw">1.04 (0x0108)</span></div>
                </div>
                <div style="display:flex; gap:6px;">
                    <a class="dcp-btn" href="https://www.avid.com" target="_blank" style="text-decoration:none;">Manual</a>
                    <a class="dcp-btn" href="https://www.avid.com" target="_blank" style="text-decoration:none;">Updates</a>
                    <a class="dcp-btn" href="https://www.avid.com" target="_blank" style="text-decoration:none;">Support</a>
                    <a class="dcp-btn" href="https://www.avid.com" target="_blank" style="text-decoration:none;">FAQ</a>
                    <a class="dcp-btn" href="https://www.avid.com" target="_blank" style="text-decoration:none;">Register</a>
                </div>
            </div>
        </div>
    </div>
</div>

<script>
let S = null;
let draggingLabelId = null;
let multiDownTime = 0;
let tapTimes = [];

function faderToDb(val) {
    if (val <= 0) return "-∞ dB";
    let db = ((val - 85) / 85.0) * 70.0;
    return (db >= 0 ? "+" : "") + db.toFixed(1) + " dB";
}

function buildMixerDOM() {
    const hwGrid = document.getElementById('hwChannelsGrid');
    const swGrid = document.getElementById('swChannelsGrid');
    const hwFxGrid = document.getElementById('hwFxSendsGrid');
    const swFxGrid = document.getElementById('swFxSendsGrid');
    hwGrid.innerHTML = ''; swGrid.innerHTML = ''; hwFxGrid.innerHTML = ''; swFxGrid.innerHTML = '';

    for (let i = 0; i < 4; i++) {
        hwGrid.appendChild(createStrip('hw', i));
        swGrid.appendChild(createStrip('sw', i));
        hwFxGrid.appendChild(createFxSendCell('hw', i));
        swFxGrid.appendChild(createFxSendCell('sw', i));
    }

    // Build 16-channel MIDI grids (Appendix C p.61)
    ['amsTxGrid', 'amsRxGrid'].forEach(gid => {
        const g = document.getElementById(gid);
        g.innerHTML = '';
        for (let c = 1; c <= 16; c++) {
            const b = document.createElement('div');
            b.className = 'midi-ch-btn active';
            b.innerText = c;
            b.onclick = () => b.classList.toggle('active');
            g.appendChild(b);
        }
    });
}

function createStrip(kind, idx) {
    const div = document.createElement('div');
    div.className = 'ch-strip';
    div.innerHTML = `
        <div class="meter-wrap" onclick="clearChannelClip('${kind}', ${idx})" title="Click meter to reset clip indicator (p.50)">
            <div id="clip_${kind}_${idx}" class="clip-led"></div>
            <div class="meter-track"><div id="meter_${kind}_${idx}" class="meter-fill"></div></div>
        </div>
        <div class="knob-box hide-in-meters">
            <div class="knob-sub"><span>Pan</span><span id="panlbl_${kind}_${idx}">C</span></div>
            <input id="pan_${kind}_${idx}" type="range" class="pan-slider" min="-50" max="50" value="0"
                   oninput="onPanChange('${kind}', ${idx}, this.value)"
                   ondblclick="this.value=0; onPanChange('${kind}', ${idx}, 0)">
        </div>
        <div class="sm-row hide-in-meters">
            <button id="solo_${kind}_${idx}" class="sm-btn solo" onclick="onToggleSM('${kind}', ${idx}, 'solo')">S</button>
            <button id="mute_${kind}_${idx}" class="sm-btn mute" onclick="onToggleSM('${kind}', ${idx}, 'mute')">M</button>
        </div>
        <div class="fader-well hide-in-meters">
            <div class="fader-scale"><span>0</span><span>-5</span><span>-10</span><span>-15</span><span>-20</span><span>-30</span><span>-50</span><span>-70</span></div>
            <input id="fader_${kind}_${idx}" type="range" class="vert-fader" min="0" max="100" value="0"
                   oninput="onFaderInput('${kind}', ${idx}, this.value)"
                   onchange="onFaderDone('${kind}', ${idx})"
                   ondblclick="this.value=85; onFaderInput('${kind}', ${idx}, 85); onFaderDone('${kind}', ${idx})">
        </div>
        <div id="label_${kind}_${idx}" class="ch-label" onclick="renameChannel('${kind}', ${idx})" title="Click to type custom channel name (p.52)">Ch ${idx+1}</div>
    `;
    return div;
}

function createFxSendCell(kind, idx) {
    const div = document.createElement('div');
    div.className = 'fx-send-cell';
    div.innerHTML = `
        <div class="knob-sub"><span>Ch ${idx+1}</span><span id="fxsendlbl_${kind}_${idx}">0%</span></div>
        <input id="fxsend_${kind}_${idx}" type="range" class="pan-slider" min="0" max="100" value="0"
               oninput="onFxSendChange('${kind}', ${idx}, this.value)"
               ondblclick="this.value=0; onFxSendChange('${kind}', ${idx}, 0)">
    `;
    return div;
}

function syncUIFromState() {
    if (!S) return;
    const bus = S.mixes[S.active_mix];
    document.getElementById('tabAnalog').classList.toggle('active', S.active_mix === 'analog');
    document.getElementById('tabSpdif').classList.toggle('active', S.active_mix === 'spdif');

    ['hw', 'sw'].forEach(kind => {
        bus[kind].forEach((ch, i) => {
            document.getElementById(`pan_${kind}_${i}`).value = ch.pan;
            document.getElementById(`panlbl_${kind}_${i}`).innerText = ch.pan == 0 ? 'C' : (ch.pan < 0 ? `L${-ch.pan}` : `R${ch.pan}`);
            document.getElementById(`solo_${kind}_${i}`).classList.toggle('active', ch.solo);
            document.getElementById(`mute_${kind}_${i}`).classList.toggle('active', ch.mute);
            document.getElementById(`fader_${kind}_${i}`).value = ch.fader;
            const lblEl = document.getElementById(`label_${kind}_${i}`);
            if (draggingLabelId !== `label_${kind}_${i}`) {
                lblEl.innerText = ch.label;
                lblEl.classList.remove('db-active');
            }
            const sendVal = S.fx_sends[kind][i];
            document.getElementById(`fxsend_${kind}_${i}`).value = sendVal;
            document.getElementById(`fxsendlbl_${kind}_${i}`).innerText = sendVal + '%';
        });
    });

    ['hw12', 'hw34', 'sw12', 'sw34', 'master'].forEach(k => {
        const el = document.getElementById('link_' + k);
        if (el) el.classList.toggle('active', !!bus.links[k]);
    });

    const m = bus.master;
    document.getElementById('masterBal').value = m.balance;
    document.getElementById('lblMasterBal').innerText = m.balance == 0 ? 'C' : (m.balance < 0 ? `L${-m.balance}` : `R${m.balance}`);
    document.getElementById('masterWidth').value = m.width;
    document.getElementById('lblMasterWidth').innerText = m.width + '%';
    document.getElementById('masterFader').value = m.fader;
    document.getElementById('masterMuteL').classList.toggle('active', m.mute_l);
    document.getElementById('masterMuteR').classList.toggle('active', m.mute_r);
    document.getElementById('masterSwap').classList.toggle('active', m.swap);
    document.getElementById('btnDim').classList.toggle('active', S.dim);
    document.getElementById('btnMono').classList.toggle('active', S.mono);
    document.getElementById('topBtnTuner').classList.toggle('active', S.tuner);

    const fxr = bus.fx_ret;
    document.getElementById('fxRetL').value = fxr.l;
    document.getElementById('fxRetR').value = fxr.r;
    document.getElementById('lblFxRetL').innerText = faderToDb(fxr.l);
    document.getElementById('lblFxRetR').innerText = faderToDb(fxr.r);
    document.getElementById('fxSoloL').classList.toggle('active', fxr.solo_l);
    document.getElementById('fxMuteL').classList.toggle('active', fxr.mute_l);
    document.getElementById('fxSoloR').classList.toggle('active', fxr.solo_r);
    document.getElementById('fxMuteR').classList.toggle('active', fxr.mute_r);

    document.getElementById('dspEffectSelect').value = S.dsp.effect;
    document.getElementById('dspDuration').value = S.dsp.duration;
    document.getElementById('dspFeedback').value = S.dsp.feedback;
    document.getElementById('dspVolume').value = S.dsp.volume;
    document.getElementById('lblDspDur').innerText = S.dsp.duration + '%';
    document.getElementById('lblDspFb').innerText = S.dsp.feedback + '%';
    document.getElementById('lblDspVol').innerText = S.dsp.volume + '%';
    document.getElementById('dspFeedbackWrap').style.opacity = (S.dsp.effect >= 6) ? '1.0' : '0.35';

    document.getElementById('chkDisableHost').checked = S.setup.disable_host_control;
    document.getElementById('selClockSource').value = S.setup.clock_source;
    document.getElementById('selSampleRate').value = S.setup.sample_rate;
    document.getElementById('selBufferSize').value = S.setup.buffer_size;
    document.getElementById('selHoldDuration').value = S.setup.hold_duration;
    document.getElementById('multiHoldDur').value = S.setup.hold_duration;
    document.getElementById('chkDimLeds').checked = S.setup.dim_leds_off_state;
    document.getElementById('chkHoldClips').checked = S.setup.hold_clip_indicators;
    document.getElementById('chkLoadLatency').checked = S.setup.load_latency_clock;
    document.getElementById('selMeterMode').value = S.setup.meter_mode;
    document.getElementById('selFxSendMode').value = S.setup.fx_send_mode;

    document.getElementById('meterModeBadge').innerText = S.setup.meter_mode === 'post' ? 'Post-Fader Meters' : 'Pre-Fader Meters';
    document.getElementById('fxSendModeLbl').innerText = S.setup.fx_send_mode === 'post' ? 'Post-Fader (Mix 1/2)' : 'Pre-Fader';
    document.getElementById('footerClock').innerText = S.setup.clock_source.toUpperCase();
    document.getElementById('footerSr').innerText = (S.setup.sample_rate / 1000).toFixed(1) + ' kHz';
    document.getElementById('clockBanner').innerText = S.setup.clock_source === 'spdif'
        ? 'S/PDIF Clock Source Selected — 4 Discrete Input Channels (2 Analog + 2 S/PDIF) Active (p.41).'
        : 'External clock not detected, Sample rate fixed at ' + (S.setup.sample_rate / 1000).toFixed(1) + ' kHz.';

    document.getElementById('fpPad1').classList.toggle('active', S.front_panel.in1_pad);
    document.getElementById('fpLimit1').classList.toggle('active', S.front_panel.in1_soft_limit);
    document.getElementById('fpSrc1').innerText = S.front_panel.in1_source === 'front' ? 'Source: Front (DI Out — Orange Band)' : 'Source: Rear (Mic/Line In)';
    document.getElementById('fpSrc1').classList.toggle('active', S.front_panel.in1_source === 'front');

    document.getElementById('fpPad2').classList.toggle('active', S.front_panel.in2_pad);
    document.getElementById('fpLimit2').classList.toggle('active', S.front_panel.in2_soft_limit);
    document.getElementById('fpSrc2').innerText = S.front_panel.in2_source === 'front' ? 'Source: Front (DI Out — Orange Band)' : 'Source: Rear (Mic/Line In)';
    document.getElementById('fpSrc2').classList.toggle('active', S.front_panel.in2_source === 'front');
    document.getElementById('fp48v').classList.toggle('active', S.phantom_48v);
}

function postStateUpdate(action, payload = {}) {
    fetch('/api/state', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({action, ...payload})
    }).then(r => r.json()).then(d => {
        if (d.state) { S = d.state; syncUIFromState(); }
    });
}

function pairSibling(idx) { return (idx % 2 === 0) ? idx + 1 : idx - 1; }
function isPairLinked(kind, idx) {
    const bus = S.mixes[S.active_mix];
    return !!bus.links[kind + (idx < 2 ? '12' : '34')];
}

function onFaderInput(kind, idx, val) {
    val = parseInt(val);
    const bus = S.mixes[S.active_mix];
    bus[kind][idx].fader = val;
    const lblId = `label_${kind}_${idx}`;
    draggingLabelId = lblId;
    const lblEl = document.getElementById(lblId);
    lblEl.innerText = faderToDb(val);
    lblEl.classList.add('db-active');

    if (isPairLinked(kind, idx)) {
        const sib = pairSibling(idx);
        bus[kind][sib].fader = val;
        document.getElementById(`fader_${kind}_${sib}`).value = val;
    }
    postStateUpdate('update_channel', {bus: S.active_mix, kind, idx, ch: bus[kind][idx], sibling_val: isPairLinked(kind, idx) ? val : null});
}

function onFaderDone(kind, idx) {
    setTimeout(() => { draggingLabelId = null; syncUIFromState(); }, 350);
}

function onPanChange(kind, idx, val) {
    val = parseInt(val);
    const bus = S.mixes[S.active_mix];
    bus[kind][idx].pan = val;
    postStateUpdate('update_channel', {bus: S.active_mix, kind, idx, ch: bus[kind][idx]});
}

function onToggleSM(kind, idx, field) {
    const bus = S.mixes[S.active_mix];
    const newVal = !bus[kind][idx][field];
    bus[kind][idx][field] = newVal;
    if (isPairLinked(kind, idx)) {
        bus[kind][pairSibling(idx)][field] = newVal;
    }
    postStateUpdate('update_channel_pair', {bus: S.active_mix, kind, channels: bus[kind]});
}

function renameChannel(kind, idx) {
    const bus = S.mixes[S.active_mix];
    const name = prompt("Enter custom channel label (e.g., guitar, vocals):", bus[kind][idx].label);
    if (name !== null && name.trim() !== "") {
        bus[kind][idx].label = name.trim();
        postStateUpdate('update_channel', {bus: S.active_mix, kind, idx, ch: bus[kind][idx]});
    }
}

function toggleLink(linkKey) {
    const bus = S.mixes[S.active_mix];
    bus.links[linkKey] = !bus.links[linkKey];
    if (linkKey === 'master') {
        bus.links['fxret'] = bus.links['master'];
    }
    postStateUpdate('update_links', {bus: S.active_mix, links: bus.links});
}

function onFxSendChange(kind, idx, val) {
    val = parseInt(val);
    S.fx_sends[kind][idx] = val;
    if (isPairLinked(kind, idx)) {
        S.fx_sends[kind][pairSibling(idx)] = val;
    }
    postStateUpdate('update_fx_sends', {fx_sends: S.fx_sends});
}

function updateFxRet(side, val) {
    val = parseInt(val);
    const bus = S.mixes[S.active_mix];
    bus.fx_ret[side] = val;
    if (bus.links.master || bus.links.fxret) {
        bus.fx_ret.l = val;
        bus.fx_ret.r = val;
    }
    postStateUpdate('update_fx_ret', {bus: S.active_mix, fx_ret: bus.fx_ret});
}

function toggleFxRetBool(field) {
    const bus = S.mixes[S.active_mix];
    const nv = !bus.fx_ret[field];
    bus.fx_ret[field] = nv;
    if (bus.links.master || bus.links.fxret) {
        if (field.startsWith('mute')) { bus.fx_ret.mute_l = nv; bus.fx_ret.mute_r = nv; }
        if (field.startsWith('solo')) { bus.fx_ret.solo_l = nv; bus.fx_ret.solo_r = nv; }
    }
    postStateUpdate('update_fx_ret', {bus: S.active_mix, fx_ret: bus.fx_ret});
}

function updateDsp(field, val) {
    S.dsp[field] = parseInt(val);
    postStateUpdate('update_dsp', {dsp: S.dsp});
}

function updateMaster(field, val) {
    const bus = S.mixes[S.active_mix];
    bus.master[field] = parseInt(val);
    if (field === 'fader') {
        document.getElementById('masterLabel').innerText = faderToDb(parseInt(val));
        setTimeout(() => { document.getElementById('masterLabel').innerText = 'L/R'; }, 450);
    }
    postStateUpdate('update_master', {bus: S.active_mix, master: bus.master});
}

function toggleMasterMute(field) {
    const bus = S.mixes[S.active_mix];
    const nv = !bus.master[field];
    bus.master[field] = nv;
    // Per p.54: Master Link Button links the FX Returns section and the Master L/R mute buttons!
    if (bus.links.master) {
        bus.master.mute_l = nv;
        bus.master.mute_r = nv;
    }
    postStateUpdate('update_master', {bus: S.active_mix, master: bus.master});
}

function toggleMasterBool(field) {
    const bus = S.mixes[S.active_mix];
    bus.master[field] = !bus.master[field];
    postStateUpdate('update_master', {bus: S.active_mix, master: bus.master});
}

function switchMixBus(busName) {
    S.active_mix = busName;
    postStateUpdate('switch_bus', {bus: busName});
}

function copyStereoMix() {
    const target = S.active_mix === 'analog' ? 'spdif' : 'analog';
    postStateUpdate('copy_mix', {from: S.active_mix, to: target});
}

function changeLayout(layoutMode) {
    const shell = document.getElementById('dcpShell');
    shell.classList.toggle('meters-only', layoutMode.includes('meters'));
    shell.classList.toggle('vertical-layout', layoutMode.startsWith('vertical'));
    postStateUpdate('set_layout', {layout: layoutMode});
}

let lastPanelWrite = 0;
function toggleGlobal(feat) { lastPanelWrite = Date.now(); postStateUpdate('toggle_global', {feature: feat}); }
function toggleTuner(state) { lastPanelWrite = Date.now(); postStateUpdate('set_tuner', {tuner: state}); }

function updateSetup() {
    const setup = {
        disable_host_control: document.getElementById('chkDisableHost').checked,
        clock_source: document.getElementById('selClockSource').value,
        sample_rate: parseInt(document.getElementById('selSampleRate').value),
        buffer_size: parseInt(document.getElementById('selBufferSize').value),
        hold_duration: parseInt(document.getElementById('selHoldDuration').value),
        dim_leds_off_state: document.getElementById('chkDimLeds').checked,
        hold_clip_indicators: document.getElementById('chkHoldClips').checked,
        load_latency_clock: document.getElementById('chkLoadLatency').checked,
        meter_mode: document.getElementById('selMeterMode').value,
        fx_send_mode: document.getElementById('selFxSendMode').value
    };
    postStateUpdate('update_setup', {setup});
}

function toggleFp(field) {
    S.front_panel[field] = !S.front_panel[field];
    postStateUpdate('update_fp', {front_panel: S.front_panel});
}

function toggleFpSource(chNum) {
    const key = `in${chNum}_source`;
    S.front_panel[key] = (S.front_panel[key] === 'rear') ? 'front' : 'rear';
    postStateUpdate('update_fp', {front_panel: S.front_panel});
}

function togglePhantom48v() {
    S.phantom_48v = !S.phantom_48v;
    postStateUpdate('set_phantom', {phantom_48v: S.phantom_48v});
    if (!S.phantom_48v) {
        let sec = 10;
        const msgEl = document.getElementById('ribbonTimerMsg');
        const iv = setInterval(() => {
            msgEl.innerText = `Ribbon Mic Discharging Wait: ${sec}s...`;
            sec--;
            if (sec < 0) { clearInterval(iv); msgEl.innerText = "Safe to connect/disconnect Ribbon Mic"; }
        }, 1000);
    }
}

function multiBtnDown() { multiDownTime = Date.now(); }
function multiBtnUp() {
    const now = Date.now();
    const heldMs = now - multiDownTime;
    const threshold = S ? S.setup.hold_duration : 500;
    const isHold = heldMs >= threshold;
    const action = isHold ? document.getElementById('multiHold').value : document.getElementById('multiRelease').value;

    let bpmTxt = S ? S.multi_button.tap_bpm.toFixed(1) : "120.0";
    if (!isHold && action === 'Tap Tempo') {
        tapTimes.push(now);
        if (tapTimes.length > 5) tapTimes.shift();
        if (tapTimes.length >= 2) {
            let diffs = [];
            for (let i = 1; i < tapTimes.length; i++) diffs.push(tapTimes[i] - tapTimes[i-1]);
            const avgMs = diffs.reduce((a,b) => a+b, 0) / diffs.length;
            if (avgMs > 180 && avgMs < 2500) {
                bpmTxt = (60000.0 / avgMs).toFixed(1);
            }
        }
    }
    document.getElementById('multiStatusReadout').innerText =
        `Triggered [${isHold ? 'Press & Hold (' + heldMs + 'ms)' : 'Press & Release'}]: ${action} | Tap BPM: ${bpmTxt}`;
    postStateUpdate('trigger_multi', {mode: isHold ? 'press_hold' : 'press_release', action, heldMs, tap_bpm: parseFloat(bpmTxt)});
}

function saveMultiBtn() {
    postStateUpdate('update_multi_cfg', {
        press_release: document.getElementById('multiRelease').value,
        press_hold: document.getElementById('multiHold').value
    });
}

function calcStorage() {
    const tr = parseFloat(document.getElementById('calcTracks').value) || 1;
    const mins = parseFloat(document.getElementById('calcMins').value) || 1;
    const rate = parseFloat(document.getElementById('calcFormat').value) || 8.2;
    const totalMb = tr * mins * rate;
    const gb = totalMb / 1024.0;
    document.getElementById('calcResult').innerText = totalMb >= 1024
        ? `Est: ${gb.toFixed(2)} GB (${Math.round(totalMb)} MB) | Single Pro Tools audio file max: 3.4 GB`
        : `Est: ${Math.round(totalMb)} MB | Format: Mac OS Extended (Journaled, Non-Case-Sensitive)`;
}

function loadSystemDiagnostics() {
    fetch('/api/diagnostics').then(r => r.json()).then(d => {
        if (!d.ok) return;
        const info = d.diagnostics;
        document.getElementById('amsFilesList').innerHTML =
            `<strong>.middev Devices:</strong> ${info.middev_files.join(', ')}<br>` +
            `<strong>.midnam Patch Banks:</strong> ${info.midnam_files.slice(0, 12).join(', ')}`;
        document.getElementById('sysAuditBox').innerHTML =
            `<strong>RAM Installed:</strong> ${info.ram_gb} | <strong>Mounted Volumes:</strong> ${info.volumes.join(', ')}<br>` +
            `<strong>Power Saver (pmset):</strong> ${info.disk_sleep} (Disable disk spin-down &amp; screen savers for Pro Tools, p.74)`;
    });
}

function openCompTab(idx) {
    document.querySelectorAll('.comp-tab').forEach((t, i) => t.classList.toggle('active', i === idx));
    document.querySelectorAll('.comp-pane').forEach((p, i) => p.classList.toggle('active', i === idx));
}

function simTuner(cents, label) {
    const pct = 50 + (cents / 50) * 45;
    document.getElementById('tunerNeedle').style.left = pct + '%';
    document.getElementById('tunerNoteDisplay').innerText = `► ${label} ◄`;
    const l1 = document.getElementById('tunerLed1');
    const l2 = document.getElementById('tunerLed2');
    const fp1 = document.getElementById('fpLed1');
    const fp2 = document.getElementById('fpLed2');
    [l1, l2, fp1, fp2].forEach(el => el.className = 'led-dot');
    if (cents < -3) {
        l1.classList.add('red'); fp1.classList.add('red');
    } else if (cents > 3) {
        l2.classList.add('red'); fp2.classList.add('red');
    } else {
        l1.classList.add('green'); l2.classList.add('green');
        fp1.classList.add('green'); fp2.classList.add('green');
    }
}

let tunerStream = null, tunerCtx = null, tunerTimer = null;
function stopWebAudioTuner() {
    if (tunerTimer) clearInterval(tunerTimer);
    if (tunerStream) tunerStream.getTracks().forEach(t => t.stop());
    if (tunerCtx) tunerCtx.close();
    tunerTimer = tunerStream = tunerCtx = null;
}
// Normalised autocorrelation (McLeod-style) with parabolic peak refinement; reliable for guitar/bass 30-1200 Hz
function detectPitch(buf, sr) {
    const n = buf.length;
    let rms = 0;
    for (let i = 0; i < n; i++) rms += buf[i] * buf[i];
    if (Math.sqrt(rms / n) < 0.008) return null;
    const minLag = Math.floor(sr / 1200), maxLag = Math.min(n >> 1, Math.floor(sr / 30));
    const nsdf = new Float32Array(maxLag + 1);
    for (let lag = minLag; lag <= maxLag; lag++) {
        let ac = 0, m = 0;
        for (let i = 0; i < n - lag; i++) { ac += buf[i] * buf[i + lag]; m += buf[i] * buf[i] + buf[i + lag] * buf[i + lag]; }
        nsdf[lag] = m > 0 ? 2 * ac / m : 0;
    }
    let best = -1, bestVal = 0;
    for (let lag = minLag + 1; lag < maxLag; lag++) if (nsdf[lag] > bestVal) bestVal = nsdf[lag];
    // first local peak above 90% of global max avoids octave errors
    for (let lag = minLag + 1; lag < maxLag; lag++) {
        if (nsdf[lag] > 0.9 * bestVal && nsdf[lag] >= nsdf[lag - 1] && nsdf[lag] >= nsdf[lag + 1]) { best = lag; break; }
    }
    if (best < 0 || bestVal < 0.6) return null;
    const a = nsdf[best - 1], b = nsdf[best], c = nsdf[best + 1];
    const shift = (a - c) / (2 * (a - 2 * b + c) || 1);
    return sr / (best + shift);
}
async function populateTunerInputs(selected) {
    const sel = document.getElementById('tunerInputSelect');
    const devs = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'audioinput');
    sel.innerHTML = devs.map(d => `<option value="${d.deviceId}">${d.label || 'Audio Input'}</option>`).join('');
    const mbox = devs.find(d => /mbox/i.test(d.label));
    sel.value = selected || (mbox ? mbox.deviceId : (devs[0] ? devs[0].deviceId : ''));
    return sel.value;
}
async function startWebAudioTuner(deviceId) {
    stopWebAudioTuner();
    try {
        tunerStream = await navigator.mediaDevices.getUserMedia({audio: {
            deviceId: deviceId ? {exact: deviceId} : undefined,
            echoCancellation: false, noiseSuppression: false, autoGainControl: false }});
        const chosen = await populateTunerInputs(deviceId || tunerStream.getAudioTracks()[0].getSettings().deviceId);
        if (!deviceId && chosen && chosen !== tunerStream.getAudioTracks()[0].getSettings().deviceId) return startWebAudioTuner(chosen);
        tunerCtx = new (window.AudioContext || window.webkitAudioContext)();
        const analyser = tunerCtx.createAnalyser();
        analyser.fftSize = 4096;
        tunerCtx.createMediaStreamSource(tunerStream).connect(analyser);
        const buf = new Float32Array(analyser.fftSize);
        const notes = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
        let smooth = null;
        tunerTimer = setInterval(() => {
            if (!S || !S.tuner) return;
            analyser.getFloatTimeDomainData(buf);
            const freq = detectPitch(buf, tunerCtx.sampleRate);
            if (!freq) { smooth = null; return; }
            const midi = 69 + 12 * Math.log2(freq / 440.0);
            smooth = (smooth === null || Math.abs(smooth - midi) > 0.5) ? midi : smooth * 0.7 + midi * 0.3;
            const nearest = Math.round(smooth);
            const cents = Math.max(-50, Math.min(50, Math.round((smooth - nearest) * 100)));
            const octave = Math.floor(nearest / 12) - 1;
            simTuner(cents, `${notes[(nearest % 12 + 12) % 12]}${octave}  ${freq.toFixed(1)} Hz`);
        }, 80);
    } catch (e) {
        document.getElementById('tunerHint').innerText =
            'Microphone access was not granted, so the on-screen needle is off. The front-panel LEDs still show tuning.';
    }
}

function clearChannelClip(kind, idx) {
    document.getElementById(`clip_${kind}_${idx}`).classList.remove('clipped');
}
function clearClips() {
    document.querySelectorAll('.clip-led').forEach(el => el.classList.remove('clipped'));
}
function openModal(id) { document.getElementById(id).classList.add('open'); }
function closeModal(id) { document.getElementById(id).classList.remove('open'); }
function runCmd(c) { fetch('/api/' + c); }

function refreshPresetList() {
    fetch('/api/presets/list').then(r => r.json()).then(d => {
        const sel = document.getElementById('presetSelect');
        sel.innerHTML = '';
        (d.presets && d.presets.length ? d.presets : ['Factory_Default']).forEach(p => {
            const opt = document.createElement('option');
            opt.value = p; opt.innerText = p;
            sel.appendChild(opt);
        });
    });
}

function savePresetPrompt() {
    const name = prompt("Save Mbox Settings File As:", "Studio_Session");
    if (!name) return;
    fetch('/api/presets/save', {
        method: 'POST', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({name})
    }).then(() => refreshPresetList());
}

function loadSelectedPreset() {
    const name = document.getElementById('presetSelect').value;
    if (!name) return;
    fetch('/api/presets/load', {
        method: 'POST', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({name})
    }).then(r => r.json()).then(d => { if (d.state) { S = d.state; syncUIFromState(); }});
}

setInterval(() => {
    fetch('/api/meters').then(r => r.json()).then(d => {
        if (!d.ok) return;
        const m = d.meters;
        const holdClip = S ? S.setup.hold_clip_indicators : true;

        ['hw', 'sw'].forEach(kind => {
            m[kind].forEach((val, i) => {
                const el = document.getElementById(`meter_${kind}_${i}`);
                if (el) el.style.height = (val * 100) + '%';
                const clipEl = document.getElementById(`clip_${kind}_${i}`);
                if (d.clips[kind][i]) clipEl.classList.add('clipped');
                else if (!holdClip) clipEl.classList.remove('clipped');
            });
        });
        ['fxL', 'fxR'].forEach((id, i) => {
            const clipEl = document.getElementById('clip_' + id);
            if (d.clips.fx[i]) clipEl.classList.add('clipped');
            else if (!holdClip) clipEl.classList.remove('clipped');
        });

        const outPair = (S && S.active_mix === 'spdif') ? m.out34 : m.out12;
        document.getElementById('meter_outL').style.height = (outPair[0] * 100) + '%';
        document.getElementById('meter_outR').style.height = (outPair[1] * 100) + '%';
        document.getElementById('mo_out1').style.height = (m.out12[0] * 100) + '%';
        document.getElementById('mo_out2').style.height = (m.out12[1] * 100) + '%';
        document.getElementById('mo_out3').style.height = (m.out34[0] * 100) + '%';
        document.getElementById('mo_out4').style.height = (m.out34[1] * 100) + '%';
        document.getElementById('meter_fxL').style.height = (m.fx[0] * 100) + '%';
        document.getElementById('meter_fxR').style.height = (m.fx[1] * 100) + '%';

        if (S && d.panel && Date.now() - lastPanelWrite > 1500) {
            const p = d.panel;
            if (p.mono !== S.mono || p.dim !== S.dim) {
                S.mono = p.mono; S.dim = p.dim;
                document.getElementById('btnDim').classList.toggle('active', S.dim);
                document.getElementById('btnMono').classList.toggle('active', S.mono);
            }
            if (p.tuner !== S.tuner) {
                S.tuner = p.tuner;
                document.getElementById('topBtnTuner').classList.toggle('active', S.tuner);
                const open = document.getElementById('tunerModal').classList.contains('open');
                if (S.tuner && !open) { openModal('tunerModal'); startWebAudioTuner(); }
                if (!S.tuner && open) { stopWebAudioTuner(); closeModal('tunerModal'); }
            }
            S.firmware = p.firmware;
            document.getElementById('footerFw').innerText = p.firmware.split(' ')[0];
            document.getElementById('aboutFw').innerText = p.firmware;
            document.getElementById('footerClock').innerText = p.clock_source.toUpperCase();
            document.getElementById('footerSr').innerText = (p.sample_rate / 1000).toFixed(1) + ' kHz';
        }
        document.getElementById('stConnected').classList.toggle('off', !d.connected);
        document.getElementById('stConnectedTxt').innerText = d.connected ? 'Hardware Connected' : 'Hardware Disconnected';
        document.getElementById('stStreaming').classList.toggle('off', !d.streaming);
        document.getElementById('stStreamingTxt').innerText = d.streaming ? 'Streaming' : 'Not Streaming';
        const hostOff = S && S.setup.disable_host_control;
        document.getElementById('stHostCtrl').classList.toggle('off', hostOff);
        document.getElementById('stHostCtrlTxt').innerText = hostOff ? 'Host Control Disabled' : 'Host Control Enabled';
    }).catch(() => {});
}, 60);

// ---- Rotary knob enhancer: every input.pan-slider becomes an Avid-style knob ----
const RK_SWEEP = 270;
function rkPolar(cx, cy, r, deg) { const a = (deg - 90) * Math.PI / 180; return [cx + r * Math.cos(a), cy + r * Math.sin(a)]; }
function rkArc(cx, cy, r, a0, a1) {
    if (Math.abs(a1 - a0) < 0.01) return '';
    const [x0, y0] = rkPolar(cx, cy, r, a0), [x1, y1] = rkPolar(cx, cy, r, a1);
    const large = Math.abs(a1 - a0) > 180 ? 1 : 0, sweep = a1 > a0 ? 1 : 0;
    return `M${x0.toFixed(2)},${y0.toFixed(2)} A${r},${r} 0 ${large} ${sweep} ${x1.toFixed(2)},${y1.toFixed(2)}`;
}
function rkSizeFor(inp) {
    if (inp.closest('.dsp-params-bar')) return 34;
    if (inp.id.startsWith('fxRet') || inp.id.startsWith('master')) return 32;
    if (inp.id.startsWith('fxsend_')) return 30;
    return 30;
}
function enhanceKnob(inp) {
    if (inp.dataset.rk) return;
    inp.dataset.rk = '1';
    const size = rkSizeFor(inp), c = size / 2, rArc = c - 2, rBody = c - 6;
    const min = parseFloat(inp.min), max = parseFloat(inp.max);
    const bipolar = min < 0 && max > 0;
    const wrap = document.createElement('div');
    wrap.className = 'rk';
    wrap.tabIndex = 0;
    wrap.style.width = wrap.style.height = size + 'px';
    wrap.innerHTML = `<svg width="${size}" height="${size}">
        <path class="rk-track" stroke-width="3" d="${rkArc(c, c, rArc, -RK_SWEEP / 2, RK_SWEEP / 2)}"/>
        <path class="rk-arc" stroke-width="3"/>
        <circle class="rk-body" cx="${c}" cy="${c}" r="${rBody}"/>
        <line class="rk-ptr" stroke-width="2"/></svg>`;
    const arc = wrap.querySelector('.rk-arc'), ptr = wrap.querySelector('.rk-ptr');
    const render = () => {
        const v = parseFloat(inp.value), t = (v - min) / (max - min);
        const ang = -RK_SWEEP / 2 + t * RK_SWEEP;
        const from = bipolar ? 0 : -RK_SWEEP / 2;
        arc.setAttribute('d', rkArc(c, c, rArc, Math.min(from, ang), Math.max(from, ang)));
        const [x0, y0] = rkPolar(c, c, rBody * 0.25, ang), [x1, y1] = rkPolar(c, c, rBody - 1.5, ang);
        ptr.setAttribute('x1', x0); ptr.setAttribute('y1', y0); ptr.setAttribute('x2', x1); ptr.setAttribute('y2', y1);
        wrap.title = `${inp.previousElementSibling ? inp.previousElementSibling.innerText.replace(/\s+/g, ' ') : ''}`;
    };
    // Re-render whenever code assigns .value programmatically (state sync, presets, double-click resets)
    const desc = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
    Object.defineProperty(inp, 'value', { get() { return desc.get.call(this); }, set(v) { desc.set.call(this, v); render(); } });
    const setVal = (v) => {
        const step = parseFloat(inp.step) || 1;
        v = Math.max(min, Math.min(max, Math.round(v / step) * step));
        if (String(v) === inp.value) return;
        inp.value = v;
        inp.dispatchEvent(new Event('input', { bubbles: true }));
    };
    let dragY = null, dragV = 0;
    wrap.addEventListener('pointerdown', e => { dragY = e.clientY; dragV = parseFloat(inp.value); wrap.setPointerCapture(e.pointerId); e.preventDefault(); wrap.focus(); });
    wrap.addEventListener('pointermove', e => {
        if (dragY === null) return;
        const px = e.shiftKey ? 600 : 150;  // full sweep over 150px, shift = fine
        setVal(dragV + (dragY - e.clientY) / px * (max - min));
    });
    const end = () => { if (dragY !== null) { dragY = null; inp.dispatchEvent(new Event('change', { bubbles: true })); } };
    wrap.addEventListener('pointerup', end);
    wrap.addEventListener('pointercancel', end);
    wrap.addEventListener('wheel', e => { e.preventDefault(); setVal(parseFloat(inp.value) + (e.deltaY < 0 ? 1 : -1) * (e.shiftKey ? 1 : 2)); }, { passive: false });
    wrap.addEventListener('keydown', e => {
        const d = { ArrowUp: 1, ArrowRight: 1, ArrowDown: -1, ArrowLeft: -1 }[e.key];
        if (d) { e.preventDefault(); setVal(parseFloat(inp.value) + d * (e.shiftKey ? 5 : 1)); }
    });
    wrap.addEventListener('dblclick', () => inp.dispatchEvent(new MouseEvent('dblclick', { bubbles: true })));
    inp.classList.add('rk-hidden');
    inp.after(wrap);
    render();
}
function enhanceKnobs(root) { (root || document).querySelectorAll('input[type=range].pan-slider').forEach(enhanceKnob); }
(function () {
    const defs = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    defs.setAttribute('width', 0); defs.setAttribute('height', 0); defs.style.position = 'absolute';
    defs.innerHTML = '<defs><radialGradient id="rkGrad" cx="40%" cy="35%" r="70%"><stop offset="0" stop-color="#5a5c63"/><stop offset="0.6" stop-color="#2c2d32"/><stop offset="1" stop-color="#17181b"/></radialGradient></defs>';
    document.body.appendChild(defs);
})();

buildMixerDOM();
enhanceKnobs();
fetch('/api/state').then(r => r.json()).then(d => { S = d.state; syncUIFromState(); refreshPresetList(); loadSystemDiagnostics(); });
</script>
</body>
</html>
"""

class ReusableThreadingServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        if os.environ.get("MBOX3_LOG"):  # opt-in request log for debugging
            sys.stderr.write("[http] " + (format % args) + "\n")

    def send_json(self, payload, code=200):
        try:
            self.send_response(code)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode('utf-8'))
        except BrokenPipeError:
            pass

    def do_GET(self):
        if self.path in ('/', '/index.html'):
            try:
                self.send_response(200)
                self.send_header("Content-type", "text/html")
                self.end_headers()
                self.wfile.write(HTML_UI.encode('utf-8'))
            except BrokenPipeError:
                pass
            return
        if self.path == '/api/state':
            self.send_json({"ok": True, "state": STATE})
            return
        if self.path == '/api/meters':
            self.send_json({
                "ok": True,
                "connected": STATE["connected"],
                "streaming": STATE["streaming"],
                "meters": STATE["meters"],
                "clips": STATE["clips"],
                "panel": {"mono": STATE["mono"], "dim": STATE["dim"], "tuner": STATE["tuner"],
                          "firmware": STATE["firmware"], "clock_source": STATE["setup"]["clock_source"],
                          "sample_rate": STATE["setup"]["sample_rate"]}
            })
            return
        if self.path == '/api/diagnostics':
            self.send_json({"ok": True, "diagnostics": inspect_macos_diagnostics()})
            return
        if self.path == '/api/presets/list':
            files = sorted([f[:-5] for f in os.listdir(PRESETS_DIR) if f.endswith('.json')])
            self.send_json({"ok": True, "presets": files})
            return
        if self.path == '/api/open-ams':
            subprocess.Popen(["open", "-a", "Audio MIDI Setup"])
            self.send_json({"ok": True})
            return
        if self.path.startswith('/api/'):
            parts = self.path[5:].split('/')
            self.send_json(run_ctl(parts))
            return
        super().do_GET()

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(length).decode('utf-8')) if length > 0 else {}

        if self.path == '/api/state':
            act = body.get('action')
            if act == 'update_channel':
                bus = body['bus']
                kind = body['kind']
                idx = int(body['idx'])
                STATE["mixes"][bus][kind][idx] = body['ch']
                if body.get('sibling_val') is not None:
                    sib = (idx + 1) if (idx % 2 == 0) else (idx - 1)
                    STATE["mixes"][bus][kind][sib]["fader"] = int(body['sibling_val'])
                sync_bus_to_hardware(bus)
                if STATE["setup"]["fx_send_mode"] == "post":
                    sync_fx_to_hardware()
            elif act == 'update_channel_pair':
                bus = body['bus']
                kind = body['kind']
                STATE["mixes"][bus][kind] = body['channels']
                sync_bus_to_hardware(bus)
            elif act == 'update_links':
                STATE["mixes"][body['bus']]["links"] = body['links']
            elif act == 'update_fx_sends':
                STATE["fx_sends"] = body['fx_sends']
                sync_fx_to_hardware()
            elif act == 'update_fx_ret':
                bus = body['bus']
                STATE["mixes"][bus]["fx_ret"] = body['fx_ret']
                sync_bus_to_hardware(bus)
            elif act == 'update_dsp':
                STATE["dsp"] = body['dsp']
                sync_fx_to_hardware()
            elif act == 'update_master':
                bus = body['bus']
                STATE["mixes"][bus]["master"] = body['master']
                sync_bus_to_hardware(bus)
            elif act == 'switch_bus':
                STATE["active_mix"] = body['bus']
            elif act == 'copy_mix':
                STATE["mixes"][body['to']] = copy.deepcopy(STATE["mixes"][body['from']])
                sync_bus_to_hardware(body['to'])
            elif act == 'set_layout':
                STATE["layout"] = body['layout']
            elif act == 'toggle_global':
                feat = body['feature']
                STATE[feat] = not STATE[feat]
                run_ctl([feat, 1 if STATE[feat] else 0])
            elif act == 'set_tuner':
                STATE["tuner"] = bool(body['tuner'])
                run_ctl(["tuner", 1 if STATE["tuner"] else 0])
            elif act == 'update_setup':
                STATE["setup"].update(body['setup'])
                apply_clock()
                run_ctl(["led-dim", 1 if STATE["setup"]["dim_leds_off_state"] else 0])
                run_ctl(["host-ctrl", 2 if STATE["setup"]["disable_host_control"] else 0])
                run_ctl(["hold-duration", HOLD_CODES.get(STATE["setup"]["hold_duration"], 0x05)])
                sync_fx_to_hardware()
            elif act == 'update_fp':
                STATE["front_panel"].update(body['front_panel'])
            elif act == 'set_phantom':
                STATE["phantom_48v"] = bool(body['phantom_48v'])
            elif act == 'trigger_multi':
                STATE["multi_button"]["last_triggered"] = body.get('action', 'None')
                if body.get('tap_bpm'):
                    STATE["multi_button"]["tap_bpm"] = body['tap_bpm']
            elif act == 'update_multi_cfg':
                STATE["multi_button"]["press_release"] = body['press_release']
                STATE["multi_button"]["press_hold"] = body['press_hold']
            elif act == 'reset_defaults':
                for k, v in copy.deepcopy(DEFAULT_STATE).items():
                    if k not in RUNTIME_KEYS:
                        STATE[k] = v
                full_sync_to_hardware()

            if act != 'set_tuner':
                mark_dirty()
            self.send_json({"ok": True, "state": STATE})
            return

        if self.path == '/api/presets/save':
            name = body.get('name', 'Preset')
            with open(os.path.join(PRESETS_DIR, f"{name}.json"), 'w') as f:
                json.dump(STATE, f, indent=2)
            self.send_json({"ok": True})
            return

        if self.path == '/api/presets/load':
            name = body.get('name', 'Preset')
            fp = os.path.join(PRESETS_DIR, f"{name}.json")
            if os.path.exists(fp):
                with open(fp, 'r') as f:
                    loaded = json.load(f)
                keep_clock = not STATE["setup"]["load_latency_clock"]
                old_clock = STATE["setup"]["clock_source"]
                old_buf = STATE["setup"]["buffer_size"]
                STATE["mixes"] = loaded.get("mixes", STATE["mixes"])
                STATE["fx_sends"] = loaded.get("fx_sends", STATE["fx_sends"])
                STATE["dsp"] = loaded.get("dsp", STATE["dsp"])
                if not keep_clock and "setup" in loaded:
                    STATE["setup"]["clock_source"] = loaded["setup"].get("clock_source", old_clock)
                    STATE["setup"]["buffer_size"] = loaded["setup"].get("buffer_size", old_buf)
                sync_bus_to_hardware("analog")
                sync_bus_to_hardware("spdif")
                sync_fx_to_hardware()
                if not keep_clock:
                    apply_clock()
                mark_dirty()
            self.send_json({"ok": True, "state": STATE})
            return

if __name__ == '__main__':
    print(f"[*] Avid Mbox 3 Driver Control Panel (Threaded v6) live at http://localhost:{PORT}")
    ReusableThreadingServer(('127.0.0.1', PORT), Handler).serve_forever()
