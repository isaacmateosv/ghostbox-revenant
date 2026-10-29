// Everything around the mixer: the top bar (mix, presets, layout, Fit), the banners and the status bar.

import { $, $$, h, setText, setOn } from '../dom.js';
import { api } from '../api.js';
import { store, anySolo } from '../store.js';

const LATENCY_NAMES = { safe: 'Safe', balanced: 'Balanced', low: 'Low' };

export function createChrome(ctx) {
    let driverBannerDismissed = false;
    let lastPanel = {};
    let statusKey = '';

    // MARK: presets

    async function refreshPresets(select) {
        const sel = $('#presetSelect');
        try {
            const d = await api.presets();
            const names = d.presets || [];
            sel.replaceChildren(...(names.length ? names.map(n => h('option', { value: n }, n)) : [h('option', { value: '' }, 'No presets yet')]));
            if (select && names.includes(select)) sel.value = select;
        } catch { /* the poll shows the connection problem */ }
    }

    async function loadPreset() {
        const name = $('#presetSelect').value;
        if (!name) return ctx.toast('Save a preset first');
        try {
            ctx.apply(await api.loadPreset(name));
            ctx.toast(`Loaded “${name}”`);
        } catch (e) { ctx.toast(e.message, { error: true }); }
    }

    async function savePreset() {
        const name = prompt('Save the current mixer settings as:', $('#presetSelect').value || 'My Session');
        if (!name || !name.trim()) return;
        try {
            await api.savePreset(name.trim());
            await refreshPresets(name.trim());
            ctx.toast(`Saved “${name.trim()}”`);
        } catch (e) { ctx.toast(e.message, { error: true }); }
    }

    async function deletePreset() {
        const name = $('#presetSelect').value;
        if (!name || !confirm(`Delete the preset “${name}”?`)) return;
        try {
            await api.deletePreset(name);
            await refreshPresets();
            ctx.toast(`Deleted “${name}”`);
        } catch (e) { ctx.toast(e.message, { error: true }); }
    }

    // MARK: render

    function render() {
        const S = store.S;
        setOn($('#tabAnalog'), S.active_mix === 'analog');
        setOn($('#tabSpdif'), S.active_mix === 'spdif');
        $('#tabAnalog').setAttribute('aria-selected', S.active_mix === 'analog');
        $('#tabSpdif').setAttribute('aria-selected', S.active_mix === 'spdif');
        for (const b of $$('.layout-switch button')) setOn(b, b.dataset.arg === S.layout);
        setOn($('#btnFit'), S.ui?.fit);
        setOn($('#btnTuner'), S.tuner);
        $('#bannerSolo').hidden = !anySolo();
        renderDriverBanner();
    }

    /** True when version a is newer than b ("1.0.1" > "1.0" == "1.0.0"). */
    function newer(a, b) {
        const pa = String(a).split('.').map(Number), pb = String(b).split('.').map(Number);
        for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
            const x = pa[i] || 0, y = pb[i] || 0;
            if (x !== y) return x > y;
        }
        return false;
    }

    /** What the driver needs, if anything: [message, button label or null]. */
    function driverAdvice() {
        const S = store.S, info = store.info;
        const bundled = info.bundled_driver_version, installed = info.driver_version;
        if (info.driver_job?.state === 'running') return ['Installing the driver: macOS asks for your password…', null];
        if (!installed) {
            return ['The Mbox 3 Core Audio driver is not installed, so apps cannot play or record through the Mbox yet (the mixer works).',
                bundled ? 'Install Driver…' : null];
        }
        // Builds before 1.0.0 had no latency modes (and reported version "1.0")
        if (bundled && (newer(bundled, installed) || (S.coreaudio && !info.driver_latency && !newer(installed, bundled)))) {
            return [`This app includes driver ${bundled}; ${installed} is installed. The update adds the latency modes and the latest fixes. Core Audio restarts for a second.`,
                'Update Driver…'];
        }
        if (lastPanel.connected && !S.coreaudio) {
            return ['The driver is installed but Core Audio has not loaded it. Reinstall it, or restart the Mac.', bundled ? 'Reinstall Driver…' : null];
        }
        return null;
    }

    function renderDriverBanner() {
        const advice = driverAdvice();
        setText($('#bannerDriverText'), advice ? advice[0] : '');
        const action = $('#bannerDriverAction');
        action.hidden = !advice || !advice[1];
        if (advice?.[1]) setText(action, advice[1]);
        $('#bannerDriver').hidden = !advice || (driverBannerDismissed && store.info.driver_job?.state !== 'running');
    }

    function chip(label, value, { led, action, title } = {}) {
        return h(action ? 'button' : 'span', { class: 'chip', title, dataset: action ? { action } : undefined },
            led !== undefined ? h('span', { class: `led ${led}` }) : null, label ? `${label} ` : null, value ? h('b', {}, value) : null);
    }

    /** Device facts from the meters poll (about 16 times a second; the status bar is rebuilt only on change). */
    function renderPanel(d) {
        const p = d.panel || {};
        const key = JSON.stringify([d.offline, d.connected, d.streaming, p.firmware, p.clock_source, p.sample_rate, p.coreaudio, p.spdif_locked,
            store.S?.setup.latency_mode, store.info.driver_latency, store.info.driver_version, store.info.driver_job?.id]);
        lastPanel = { ...p, connected: d.connected };
        $('#bannerOffline').hidden = d.connected;
        setText($('#bannerOffline span'), d.offline ? 'Lost contact with GhostBox Revenant GUI. Reconnecting…'
            : 'Mbox 3 not connected. Plug it in: your mix is restored automatically.');
        setOn($('#brandDot'), d.connected);
        setText($('#brandSub'), d.connected ? `Mbox 3 online · fw ${(p.firmware || '-').split(' ')[0]}` : d.offline ? 'Reconnecting…' : 'Mbox 3 offline');
        if (key === statusKey) return;
        statusKey = key;
        const spdif = p.clock_source === 'spdif';
        const rate = p.sample_rate ? `${(p.sample_rate / 1000).toFixed(1)} kHz` : '-';
        const latency = store.info.driver_latency ? LATENCY_NAMES[store.S?.setup.latency_mode] || 'Safe' : null;
        $('#statusbar').replaceChildren(...[
            chip(null, d.connected ? 'Mbox 3' : 'Mbox 3 not connected', { led: d.connected ? 'green' : '' }),
            chip('Core Audio', p.coreaudio ? `driver ${store.info.driver_version || 'active'}` : 'driver not loaded', { led: p.coreaudio ? 'green' : 'amber' }),
            chip(null, d.streaming ? 'Audio from the computer' : 'No audio from the computer', { led: d.streaming ? 'green' : '' }),
            chip('Clock', spdif ? `S/PDIF${p.spdif_locked ? '' : ' (no signal)'}` : 'Internal', { action: 'setup', title: 'Change in Setup' }),
            chip(null, rate, { action: 'setup', title: 'Set the rate in your DAW, Audio MIDI Setup or Setup' }),
            latency ? chip('Latency', latency, { action: 'setup', title: 'Driver latency (Setup)' }) : null,
            h('span', { class: 'spacer' }),
            chip(null, `GhostBox Revenant ${store.info.app_version || ''}`)].filter(Boolean));
        if (store.S) renderDriverBanner();
    }

    function dismissDriverBanner() {
        driverBannerDismissed = true;
        $('#bannerDriver').hidden = true;
        ctx.refit();
    }

    return { render, renderPanel, refreshPresets, loadPreset, savePreset, deletePreset, dismissDriverBanner };
}
