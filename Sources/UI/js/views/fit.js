// Fit to Window: scales the whole panel so it fits the window height (optional; off by default so nothing
// shrinks unless asked). The layout is re-flowed at the scaled width, then shrunk with a transform.

import { $ } from '../dom.js';

const MIN_SCALE = 0.45;

export function createFit() {
    const app = $('#app'), viewport = $('#viewport'), root = document.documentElement;
    let enabled = false, applying = false, frame = 0;

    function clear() {
        root.classList.remove('fit');
        app.style.transform = app.style.width = viewport.style.height = '';
    }

    function layout() {
        if (!enabled) return clear();
        applying = true;
        root.classList.add('fit');
        const W = root.clientWidth, H = window.innerHeight;
        const maxW = root.classList.contains('layout-vertical') ? 640 : 1480;
        let z = 1, w = Math.min(W, maxW);
        // The content height depends on its width, so iterate to a stable scale
        for (let i = 0; i < 5; i++) {
            w = Math.min(W / z, maxW);
            app.style.width = `${w}px`;
            const next = Math.max(MIN_SCALE, Math.min(1, H / app.scrollHeight, W / w));
            if (Math.abs(next - z) < 0.002) { z = next; break; }
            z = next;
        }
        w = Math.min(W / z, maxW);
        app.style.width = `${w}px`;
        app.style.transform = `translate(${Math.max(0, (W - w * z) / 2)}px, 0) scale(${z})`;
        viewport.style.height = `${Math.ceil(app.scrollHeight * z)}px`;
        requestAnimationFrame(() => { applying = false; });
    }

    function refresh() {
        if (frame) return;
        frame = requestAnimationFrame(() => { frame = 0; layout(); });
    }

    window.addEventListener('resize', refresh);
    new ResizeObserver(() => { if (enabled && !applying) refresh(); }).observe(app);

    return {
        set(on) { if (on !== enabled) { enabled = on; layout(); } },
        refresh,
    };
}
