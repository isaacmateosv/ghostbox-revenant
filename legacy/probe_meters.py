#!/usr/bin/env python3
"""Guided probe for the Mbox 3 meter block (15 words at MEM 0x0010 / entity 0x2001).

Run from this folder (the web panel may stay open; the FX step uses it):  ./venv/bin/python3 probe_meters.py
For each step, feed the named signal while it records; it reports which words rose
above the silent baseline so METER_MAP in server.py can be confirmed or corrected.
"""
import json
import subprocess
import time

CTL = "./mbox3-ctl"
STEPS = [
    ("silence", "Leave every input silent"),
    ("in1", "Play or speak into INPUT 1 only"),
    ("in2", "Play or speak into INPUT 2 only"),
    ("spdif", "Feed S/PDIF IN (needs Clock Source = S/PDIF)"),
    ("fxret", "Turn up an FX send + FX Volume + FX Return in the panel, then play into INPUT 1"),
    ("tuner", "TUNER MODE: pluck an open A string into INPUT 1 (hardware tuner is switched on for this step)"),
]


def ctl(*args):
    out = subprocess.run([CTL, *map(str, args)], capture_output=True, text=True, timeout=2).stdout
    return json.loads(out.strip().splitlines()[-1]) if out.strip() else {}


def capture(seconds=4.0):
    peaks, samples = [0] * 15, []
    end = time.time() + seconds
    while time.time() < end:
        raw = ctl("meters").get("raw") or [0] * 15
        samples.append(raw)
        peaks = [max(a, b) for a, b in zip(peaks, raw)]
        time.sleep(0.03)
    return peaks, samples


def main():
    if not ctl("status").get("connected"):
        print("Mbox 3 not connected.")
        return
    results = {}
    for key, prompt in STEPS:
        input(f"\n[{key}] {prompt}. Press Enter, then keep the signal going for 4 s...")
        if key == "tuner":
            ctl("tuner", 1)
        peaks, samples = capture()
        if key == "tuner":
            ctl("tuner", 0)
            distinct = [sorted({s[i] for s in samples}) for i in range(15)]
            print("  distinct values per word while tuning (look for a word that tracks pitch):")
            for i, vals in enumerate(distinct):
                if len(vals) > 1:
                    print(f"    word {i:2d}: {vals[:12]}{' ...' if len(vals) > 12 else ''}")
        results[key] = peaks
        base = results.get("silence", [0] * 15)
        risen = [i for i in range(15) if peaks[i] > max(64, base[i] * 4)]
        print(f"  peaks: {peaks}")
        print(f"  words above baseline: {risen or 'none'}")
    with open("meter_probe_results.json", "w") as f:
        json.dump(results, f, indent=2)
    print("\nSaved meter_probe_results.json")


if __name__ == "__main__":
    main()
