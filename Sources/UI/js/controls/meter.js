// Level meter with a peak-hold line and a clip LED. Levels are 0..1 over -60..0 dBFS (MeterProcessor.swift).

const PEAK_HOLD_MS = 1200, PEAK_FALL = 0.015;

export class Meter {
    /** @param {object} o wide (bigger master meters), title, onClick */
    constructor(o = {}) {
        this.el = document.createElement('div');
        this.el.className = 'meter' + (o.wide ? ' wide' : '');
        this.el.title = o.title || 'Click to clear the clip indicator';
        this.el.innerHTML = '<div class="clip"></div><div class="bar"><div class="fill"></div><div class="peak"></div></div>';
        this.clipEl = this.el.querySelector('.clip');
        this.fillEl = this.el.querySelector('.fill');
        this.peakEl = this.el.querySelector('.peak');
        this.level = -1;
        this.peak = 0;
        this.peakAt = 0;
        this.clipped = false;
        this.el.addEventListener('click', () => { this.clearClip(); o.onClick?.(); });
    }

    /** One meter frame. `holdClip`: keep the clip LED lit until clicked (Setup option). */
    set(level, clipping, holdClip) {
        level = Math.max(0, Math.min(1, level || 0));
        if (level !== this.level) {
            this.level = level;
            this.fillEl.style.transform = `scaleY(${level.toFixed(3)})`;
        }
        const now = performance.now();
        if (level >= this.peak) { this.peak = level; this.peakAt = now; }
        else if (now - this.peakAt > PEAK_HOLD_MS) this.peak = Math.max(level, this.peak - PEAK_FALL);
        this.peakEl.style.bottom = `calc(${(this.peak * 100).toFixed(2)}% - 2px)`;
        this.peakEl.classList.toggle('show', this.peak > 0.02);
        const lit = clipping || (holdClip && this.clipped);
        if (lit !== this.clipped) { this.clipped = lit; this.clipEl.classList.toggle('on', lit); }
    }

    clearClip() {
        this.clipped = false;
        this.clipEl.classList.remove('on');
    }
}

/** dB scale for a big meter (positions match the meter's -60..0 dB range). */
export function meterScale(marks = [0, -6, -12, -18, -24, -36, -48]) {
    const el = document.createElement('div');
    el.className = 'meter-scale';
    // the bar starts 9 px below the top (clip LED + gap)
    el.innerHTML = marks.map(db => `<span style="bottom:calc((100% - 9px) * ${((db + 60) / 60).toFixed(4)})">${db === 0 ? '0' : -db}</span>`).join('');
    return el;
}
