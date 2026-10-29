// Rotary knob (Avid DCP style): drag up/down, scroll, arrow keys; Shift for fine steps; double-click resets.

import { store } from '../store.js';

const SWEEP = 270;
const polar = (c, r, deg) => {
    const a = ((deg - 90) * Math.PI) / 180;
    return [c + r * Math.cos(a), c + r * Math.sin(a)];
};
function arc(c, r, a0, a1) {
    if (Math.abs(a1 - a0) < 0.01) return '';
    const [x0, y0] = polar(c, r, a0), [x1, y1] = polar(c, r, a1);
    return `M${x0.toFixed(2)},${y0.toFixed(2)} A${r},${r} 0 ${Math.abs(a1 - a0) > 180 ? 1 : 0} 1 ${x1.toFixed(2)},${y1.toFixed(2)}`;
}

export class Knob {
    /**
     * @param {object} o min, max, value, reset (double-click value), step, size, label (for screen readers),
     *   format(v) -> readout text, onInput(v) while moving, onCommit(v) when a gesture ends, variant ('fx')
     */
    constructor(o) {
        Object.assign(this, { min: 0, max: 100, step: 1, size: 30, reset: null, format: v => String(v), onInput() {}, onCommit() {} }, o);
        this._v = o.value ?? this.min;
        this.bipolar = this.min < 0 && this.max > 0;
        const s = this.size, c = s / 2;
        this.el = document.createElement('div');
        this.el.className = 'knob' + (o.variant ? ' ' + o.variant : '');
        this.el.style.width = this.el.style.height = s + 'px';
        this.el.tabIndex = 0;
        this.el.setAttribute('role', 'slider');
        this.el.setAttribute('aria-label', o.label || '');
        this.el.setAttribute('aria-valuemin', this.min);
        this.el.setAttribute('aria-valuemax', this.max);
        this.el.innerHTML = `<svg width="${s}" height="${s}">
            <path class="track" stroke-width="3" d="${arc(c, c - 2, -SWEEP / 2, SWEEP / 2)}"/>
            <path class="arc" stroke-width="3"/>
            <circle class="body" cx="${c}" cy="${c}" r="${c - 6}"/>
            <line class="ptr" stroke-width="2"/></svg>`;
        this.arcEl = this.el.querySelector('.arc');
        this.ptrEl = this.el.querySelector('.ptr');
        this.dragging = false;
        this._bind();
        this._render();
    }

    get value() { return this._v; }
    set value(v) {
        if (this.dragging) return;  // the pointer owns the knob
        this._v = this._clamp(v);
        this._render();
    }

    _clamp(v) {
        const q = Math.round(v / this.step) * this.step;
        return Math.max(this.min, Math.min(this.max, Number(q.toFixed(4))));
    }

    _set(v, commit) {
        v = this._clamp(v);
        if (v === this._v) { if (commit) this.onCommit(v); return; }
        this._v = v;
        this._render();
        this.onInput(v);
        if (commit) this.onCommit(v);
    }

    _render() {
        const c = this.size / 2, rBody = c - 6;
        const t = (this._v - this.min) / (this.max - this.min);
        const ang = -SWEEP / 2 + t * SWEEP;
        const from = this.bipolar ? 0 : -SWEEP / 2;
        this.arcEl.setAttribute('d', arc(c, c - 2, Math.min(from, ang), Math.max(from, ang)));
        const [x0, y0] = polar(c, rBody * 0.25, ang), [x1, y1] = polar(c, rBody - 1.5, ang);
        this.ptrEl.setAttribute('x1', x0); this.ptrEl.setAttribute('y1', y0);
        this.ptrEl.setAttribute('x2', x1); this.ptrEl.setAttribute('y2', y1);
        const text = this.format(this._v);
        this.el.setAttribute('aria-valuenow', this._v);
        this.el.setAttribute('aria-valuetext', text);
        this.el.title = `${this.label ? this.label + ': ' : ''}${text}`;
    }

    _bind() {
        const range = this.max - this.min;
        let startY = 0, startV = 0;
        this.el.addEventListener('pointerdown', e => {
            if (e.button !== 0) return;
            startY = e.clientY; startV = this._v;
            this.dragging = true; store.dragging++;
            this.el.setPointerCapture(e.pointerId);
            this.el.focus();
            e.preventDefault();
        });
        this.el.addEventListener('pointermove', e => {
            if (!this.dragging) return;
            const px = e.shiftKey ? 600 : 150;  // full sweep over 150 px; Shift = fine
            this.dragging = false;  // let _set through
            this._set(startV + ((startY - e.clientY) / px) * range, false);
            this.dragging = true;
        });
        const end = () => {
            if (!this.dragging) return;
            this.dragging = false; store.dragging--;
            this.onCommit(this._v);
        };
        this.el.addEventListener('pointerup', end);
        this.el.addEventListener('pointercancel', end);
        this.el.addEventListener('lostpointercapture', end);  // e.g. an alert took the pointer mid-drag
        this.el.addEventListener('wheel', e => {
            e.preventDefault();
            const notch = e.deltaY < 0 ? 1 : -1;
            this._set(this._v + notch * this.step * (e.shiftKey ? 1 : Math.max(1, Math.round(range / 100) * 2)), true);
        }, { passive: false });
        this.el.addEventListener('keydown', e => {
            const d = { ArrowUp: 1, ArrowRight: 1, ArrowDown: -1, ArrowLeft: -1 }[e.key];
            if (d) { e.preventDefault(); this._set(this._v + d * this.step * (e.shiftKey ? 5 : 1), true); }
            if (e.key === 'Home' && this.reset !== null) { e.preventDefault(); this._set(this.reset, true); }
        });
        this.el.addEventListener('dblclick', () => { if (this.reset !== null) this._set(this.reset, true); });
    }
}

/** The knob gradient, defined once per page. */
export function installKnobDefs() {
    const defs = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    defs.setAttribute('width', 0); defs.setAttribute('height', 0);
    defs.style.position = 'absolute';
    defs.innerHTML = '<defs><radialGradient id="knobGrad" cx="40%" cy="35%" r="70%"><stop offset="0" stop-color="#60636b"/>' +
        '<stop offset="0.6" stop-color="#2e3036"/><stop offset="1" stop-color="#18191c"/></radialGradient></defs>';
    document.body.appendChild(defs);
}
