// The app's local API (Sources/App/Server/APIRouter.swift). State-changing calls are JSON POSTs.

async function request(path, body) {
    const opts = body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
    const r = await fetch(path, opts);
    const d = await r.json().catch(() => ({ ok: false, error: r.statusText }));
    if (!r.ok || d.ok === false) throw new Error(d.error || r.statusText);
    return d;
}

export const api = {
    state: () => request('/api/state'),
    meters: () => request('/api/meters'),
    midi: () => request('/api/midi'),
    diagnostics: () => request('/api/diagnostics'),
    presets: () => request('/api/presets/list'),
    savePreset: name => request('/api/presets/save', { name }),
    loadPreset: name => request('/api/presets/load', { name }),
    deletePreset: name => request('/api/presets/delete', { name }),
    initialize: () => request('/api/init', {}),
    reenumerate: () => request('/api/reenumerate', {}),
    openAudioMidiSetup: () => request('/api/open-ams', {}),
    revealData: () => request('/api/reveal-data', {}),
    installDriver: () => request('/api/install-driver', {}),
};

/**
 * Posts panel actions one at a time. While one is in flight, a newer action with the same key replaces the
 * queued one, so a fader drag sends its latest position instead of a backlog. The state in the last response
 * is handed to `onState` once nothing is pending.
 */
export class ActionQueue {
    constructor(onState, onError) {
        this.pending = new Map();
        this.busy = false;
        this.onState = onState;
        this.onError = onError;
    }

    get idle() { return !this.busy && this.pending.size === 0; }

    send(action, payload = {}, key = action) {
        this.pending.set(key, { action, ...payload });
        if (!this.busy) this.flush();
    }

    async flush() {
        let last = null;
        while (this.pending.size) {
            const [key, body] = this.pending.entries().next().value;
            this.pending.delete(key);
            this.busy = true;
            try { last = await request('/api/state', body); } catch (e) { this.onError?.(e); }
            this.busy = false;
        }
        if (last) this.onState(last);
    }
}
