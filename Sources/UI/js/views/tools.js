// The tools panel under the mixer: Hardware Check, Multi Button, MIDI, System.

import { $, $$, h, setText, setOn, escapeHTML } from '../dom.js';
import { api } from '../api.js';
import { store } from '../store.js';

export function createTools(ctx) {
    const peaks = [-120, -120];
    let midiCount = -1;

    let actionsShown = '';

    function render() {
        const S = store.S, ui = S.ui || {};
        const actions = store.info.multi_actions || ['None'];
        if (actions.join() !== actionsShown) {
            actionsShown = actions.join();
            $('#multiAction').replaceChildren(...actions.map(a => h('option', { value: a }, a)));
        }
        const tab = ui.tools_tab || 'hardware';
        $('#tools').classList.toggle('closed', !ui.tools_open);
        setText($('#btnTools'), ui.tools_open ? 'Hide' : 'Show');
        for (const b of $$('.tools-head nav button')) setOn(b, ui.tools_open && b.dataset.arg === tab);
        for (const pane of $$('[data-pane]')) pane.hidden = pane.dataset.pane !== tab;
        const mb = S.multi_button || {};
        setText($('#multiTrigger'), mb.learning ? 'press Multi on the Mbox…' : mb.trigger || 'not learned');
        setOn($('#multiLearn'), mb.learning);
        if (document.activeElement !== $('#multiAction')) $('#multiAction').value = mb.press_release || 'None';
        if (document.activeElement !== $('#multiHold')) $('#multiHold').value = String(S.setup.hold_duration);
        setText($('#multiLast'), mb.last_triggered && mb.last_triggered !== 'None' ? mb.last_triggered : 'none');
    }

    function renderMeters(d) {
        const S = store.S, p = d.panel || {};
        [0, 1].forEach(i => {
            const lvl = d.meters.hw[i] || 0;
            const db = lvl > 0 ? lvl * 60 - 60 : -120;
            peaks[i] = Math.max(peaks[i] - 0.4, db);
            $('#hcBar' + i).style.transform = `scaleX(${lvl.toFixed(3)})`;
            setText($('#hcDb' + i), db > -60 ? db.toFixed(1) : '−∞');
            setText($('#hcPeak' + i), peaks[i] > -60 ? `peak ${peaks[i].toFixed(1)}` : '');
            if (!S?.tuner) $('#hcLed' + i).className = 'led' + (d.clips.hw[i] ? ' red' : db > -50 ? ' green' : '');
        });
        const rows = [
            ['Mbox 3', d.connected ? `connected, firmware ${p.firmware || '-'}` : 'not connected'],
            ['Clock', `${p.clock_source === 'spdif' ? 'S/PDIF' : 'Internal'} · ${((p.sample_rate || 0) / 1000).toFixed(1)} kHz`],
            ['Core Audio', p.coreaudio ? `driver ${store.info.driver_version || ''} active: the Mbox is a sound device` : 'driver not loaded: mixer control only'],
        ];
        const html = rows.map(([k, v]) => `<dt>${k}</dt><dd>${escapeHTML(v)}</dd>`).join('');
        if ($('#hcDevice').innerHTML !== html) $('#hcDevice').innerHTML = html;
        if (p.midi_events !== undefined && p.midi_events !== midiCount) {
            midiCount = p.midi_events;
            setText($('#midiCount'), `${midiCount} message${midiCount === 1 ? '' : 's'}`);
            refreshMidi();
        }
    }

    async function refreshMidi() {
        try {
            const m = await api.midi();
            const ev = m.events || [];
            $('#midiLog').innerHTML = ev.length
                ? ev.map(e => `${escapeHTML(e.time)} <b>${escapeHTML(e.port)}</b> ${escapeHTML(e.bytes)}`).join('<br>')
                : 'No MIDI received yet.';
        } catch { /* shown by the poll */ }
    }

    async function loadDiagnostics() {
        try {
            const d = (await api.diagnostics()).diagnostics;
            const list = (title, items) => `<strong>${title}</strong> ${items.length ? items.map(escapeHTML).join(', ') : 'none installed'}`;
            $('#midiFiles').innerHTML = `${list('Devices (.middev):', d.middev_files)}<br>${list('Patch names (.midnam):', d.midnam_files.slice(0, 20))}`;
            const row = (k, v) => `<dt>${k}</dt><dd>${escapeHTML(v)}</dd>`;
            $('#sysInfo').innerHTML = row('macOS', d.macos) + row('Processor', d.cpu) + row('Memory', d.ram_gb) +
                row('Disk sleep', d.disk_sleep) + row('Volumes', d.volumes.join(', ')) +
                row('App', d.app_version) + row('Driver', d.driver_version);
        } catch { /* shown by the poll */ }
    }

    function calc() {
        const tracks = Math.max(1, Number($('#calcTracks').value) || 1);
        const minutes = Math.max(1, Number($('#calcMinutes').value) || 1);
        const bytes = tracks * minutes * 60 * Number($('#calcRate').value) * (Number($('#calcFormat').value) / 8);
        setText($('#calcResult'), bytes >= 1e9 ? `${(bytes / 1e9).toFixed(2)} GB` : `${Math.round(bytes / 1e6)} MB`);
    }
    calc();

    const multi = {
        learn: () => { store.S.multi_button.learning = true; ctx.post('midi_learn'); render(); },
        forget: () => { Object.assign(store.S.multi_button, { trigger: '', learning: false }); ctx.post('midi_forget'); render(); },
        action: value => { store.S.multi_button.press_release = value; ctx.post('update_multi_cfg', { press_release: value }, 'multi'); },
    };

    return { render, renderMeters, loadDiagnostics, calc, multi };
}
