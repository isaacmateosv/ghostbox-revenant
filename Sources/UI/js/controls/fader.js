// Vertical fader with a dB scale. Drag anywhere on it (relative: no jumps), scroll, or use the keyboard
// (arrows +-1 dB, Shift +-0.25 dB, Page keys +-6 dB, Home = 0 dB, End = off); double-click returns to 0 dB.

import { formatDb, stepDb } from '../gain.js';
import { store } from '../store.js';

export class Fader {
    /**
     * @param {object} o law (gain.js channelLaw / masterLaw), value, reset, label, onInput(v), onCommit(v)
     */
    constructor(o) {
        Object.assign(this, { reset: 85, onInput() {}, onCommit() {} }, o);
        this._v = o.value ?? 0;
        this.dragging = false;
        this.el = document.createElement('div');
        this.el.className = 'fader';
        this.el.tabIndex = 0;
        this.el.setAttribute('role', 'slider');
        this.el.setAttribute('aria-label', o.label || 'Fader');
        this.el.innerHTML = `<div class="scale">${this.law.ticks.map(db => {
            const top = ((1 - this.law.tickPos(db)) * 100).toFixed(2);
            return `<span class="tick${db === 0 ? ' unity' : ''}" style="top:${top}%">${db === 0 ? '0' : -db}</span>`;
        }).join('')}</div><div class="rail"><div class="rail-fill"></div></div><div class="cap"></div>`;
        this.capEl = this.el.querySelector('.cap');
        this.fillEl = this.el.querySelector('.rail-fill');
        this._bind();
        this._render();
    }

    get value() { return this._v; }
    set value(v) {
        if (this.dragging) return;
        this._v = Math.max(0, Math.min(this.law.max, v));
        this._render();
    }

    get db() { return this.law.db(this._v); }

    _set(v, commit) {
        v = Math.max(0, Math.min(this.law.max, v));
        if (v !== this._v) {
            this._v = v;
            this._render();
            this.onInput(v);
        }
        if (commit) this.onCommit(v);
    }

    _render() {
        const p = this.law.toPos(this._v);
        // Rail and cap share the area between 9 px insets (see controls.css)
        this.capEl.style.top = `calc(9px + (100% - 18px) * ${(1 - p).toFixed(4)})`;
        this.fillEl.style.height = `${(p * 100).toFixed(2)}%`;
        const text = formatDb(this.db) + ' dB';
        this.el.setAttribute('aria-valuenow', this._v);
        this.el.setAttribute('aria-valuetext', text);
    }

    _bind() {
        let startY = 0, startP = 0, height = 1;
        this.el.addEventListener('pointerdown', e => {
            if (e.button !== 0) return;
            startY = e.clientY;
            startP = this.law.toPos(this._v);
            height = Math.max(40, this.el.getBoundingClientRect().height - 18);  // screen pixels (Fit scales the panel)
            this.dragging = true; store.dragging++;
            this.el.classList.add('dragging');
            this.el.setPointerCapture(e.pointerId);
            this.el.focus();
            e.preventDefault();
        });
        this.el.addEventListener('pointermove', e => {
            if (!this.dragging) return;
            const dp = ((startY - e.clientY) / height) * (e.shiftKey || e.altKey ? 0.25 : 1);
            const p = Math.max(0, Math.min(1, startP + dp));
            this._set(this.law.toValue(p), false);
        });
        const end = () => {
            if (!this.dragging) return;
            this.dragging = false; store.dragging--;
            this.el.classList.remove('dragging');
            this.onCommit(this._v);
        };
        this.el.addEventListener('pointerup', end);
        this.el.addEventListener('pointercancel', end);
        this.el.addEventListener('lostpointercapture', end);  // e.g. an alert took the pointer mid-drag
        this.el.addEventListener('wheel', e => {
            e.preventDefault();
            this._set(stepDb(this.law, this._v, (e.deltaY < 0 ? 1 : -1) * (e.shiftKey ? 0.25 : 0.5)), true);
        }, { passive: false });
        this.el.addEventListener('keydown', e => {
            const steps = { ArrowUp: 1, ArrowRight: 1, ArrowDown: -1, ArrowLeft: -1, PageUp: 6, PageDown: -6 };
            if (e.key in steps) {
                e.preventDefault();
                this._set(stepDb(this.law, this._v, steps[e.key] * (e.shiftKey && Math.abs(steps[e.key]) === 1 ? 0.25 : 1)), true);
            } else if (e.key === 'Home') { e.preventDefault(); this._set(this.reset, true); }
            else if (e.key === 'End') { e.preventDefault(); this._set(0, true); }
        });
        this.el.addEventListener('dblclick', () => this._set(this.reset, true));
    }
}
