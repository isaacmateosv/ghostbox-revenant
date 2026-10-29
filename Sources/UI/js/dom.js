// Small DOM helpers shared by the views.

export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

/** Element builder: h('div', {class: 'x', dataset: {k: 'v'}, onclick}, child, 'text', ...) */
export function h(tag, attrs = {}, ...children) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
        if (v === undefined || v === null || v === false) continue;
        if (k === 'class') el.className = v;
        else if (k === 'dataset') Object.assign(el.dataset, v);
        else if (k === 'html') el.innerHTML = v;
        else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
        else el.setAttribute(k, v === true ? '' : v);
    }
    for (const c of children.flat()) if (c !== null && c !== undefined) el.append(c instanceof Node ? c : String(c));
    return el;
}

/** Writes only when the text changes (cheap to call on every meter frame). */
export function setText(el, text) {
    if (el && el.textContent !== text) el.textContent = text;
}

export function setOn(el, on, cls = 'on') {
    if (el) el.classList.toggle(cls, !!on);
}

export function escapeHTML(s) {
    return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

export const icons = {
    link: '<svg viewBox="0 0 16 16"><path d="M6.5 9.5l3-3M7 4.5l1-1a2.5 2.5 0 013.5 3.5l-1 1M9 11.5l-1 1A2.5 2.5 0 014.5 9l1-1"/></svg>',
    trash: '<svg class="icon" viewBox="0 0 16 16"><path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.7 8.5h5.6l.7-8.5"/></svg>',
    horizontal: '<svg viewBox="0 0 18 14"><rect x="1" y="2" width="16" height="10" rx="1.5"/><path d="M6.5 2v10M11.5 2v10"/></svg>',
    horizontalMeters: '<svg viewBox="0 0 18 14"><rect x="1" y="2" width="16" height="10" rx="1.5"/><path d="M4 10V6M7 10V4.5M10 10V7M13 10V5"/></svg>',
    vertical: '<svg viewBox="0 0 18 14"><rect x="4" y="1" width="10" height="12" rx="1.5"/><path d="M4 5h10M4 9h10"/></svg>',
    verticalMeters: '<svg viewBox="0 0 18 14"><rect x="4" y="1" width="10" height="12" rx="1.5"/><path d="M7 11V7M9 11V4M11 11V8"/></svg>',
    fit: '<svg class="icon" viewBox="0 0 16 16"><path d="M2.5 6V2.5H6M10 2.5h3.5V6M13.5 10v3.5H10M6 13.5H2.5V10"/></svg>',
};
