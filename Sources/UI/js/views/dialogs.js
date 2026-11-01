// Setup, About and Flow dialogs (native <dialog>: Esc closes, focus stays inside).

import { $, h, escapeHTML } from '../dom.js';
import { api } from '../api.js';
import { store } from '../store.js';

const RATES = [44100, 48000, 88200, 96000];
const OWNER = 'isaacmateosv';  // GitHub account that publishes the project (copyright holder)
const REPOSITORY = `https://github.com/${OWNER}/ghostbox-revenant`;
const LATENCY = [
    ['safe', 'Safe', 'Most margin against USB timing hiccups (10 ms in, 13 ms out). Start here.'],
    ['balanced', 'Balanced', 'About 4 ms less each way (6 ms in, 9 ms out).'],
    ['low', 'Low', 'Lowest round trip (4 ms in, 6 ms out). Go back one step if you hear clicks.'],
];

export function openDialog(id) {
    const d = $('#' + id);
    if (!d.open) d.showModal();
}

export function closeDialog(el) {
    const d = el.closest('dialog');
    if (d?.open) d.close();
}

export function createDialogs(ctx) {
    // MARK: setup

    function postSetup(patch) {
        Object.assign(store.S.setup, patch);
        ctx.post('update_setup', { setup: store.S.setup }, 'setup');
        renderSetup();
        ctx.render();
    }

    function segmented(options, current, onPick, disabled = false) {
        return h('div', { class: 'segmented' }, ...options.map(([value, label]) =>
            h('button', { class: value === current ? 'on' : '', disabled, onclick: () => onPick(value) }, label)));
    }

    function field(label, control, hint) {
        return [h('div', { class: 'label' }, label), control, hint ? h('div', { class: 'hint' }, hint) : null];
    }

    function renderSetup() {
        const S = store.S, info = store.info, s = S.setup;
        const spdif = s.clock_source === 'spdif';
        const latencySupported = !!info.driver_latency;
        const latency = LATENCY.find(l => l[0] === s.latency_mode) || LATENCY[0];
        const check = (key, label) => h('label', {}, h('input', { type: 'checkbox', checked: !!s[key], onchange: e => postSetup({ [key]: e.target.checked }) }), ' ', label);
        $('#setupBody').replaceChildren(
            h('div', { class: 'section-title' }, 'Clock'),
            h('div', { class: 'field' },
                ...field('Sample rate', segmented(RATES.map(r => [r, `${r / 1000} kHz`]), Number(s.sample_rate), r => postSetup({ sample_rate: r }), spdif),
                    spdif ? 'The S/PDIF source sets the rate; the driver follows it.' : 'Core Audio owns the rate while the driver is installed: changing it here is the same as changing it in your DAW or Audio MIDI Setup.'),
                ...field('Clock source', segmented([['internal', 'Internal'], ['spdif', 'S/PDIF']], s.clock_source, c => postSetup({ clock_source: c })),
                    spdif ? (info.spdif_locked ? 'S/PDIF signal locked. Inputs 3/4 record the S/PDIF input.' : 'No S/PDIF signal: connect a source, or switch back to Internal.')
                          : 'Choose S/PDIF to record from (and clock to) a digital source on S/PDIF In.')),
            h('div', { class: 'section' },
                h('div', { class: 'section-title' }, 'Core Audio driver'),
                h('div', { class: 'field' },
                    ...field('Latency', segmented(LATENCY.map(l => [l[0], l[1]]), s.latency_mode, m => postSetup({ latency_mode: m }), !latencySupported),
                        latencySupported ? latency[2] : 'The installed driver has no latency modes. Install driver 1.0 or later.'))),
            h('div', { class: 'section' },
                h('div', { class: 'section-title' }, 'Front panel'),
                h('div', { class: 'field' },
                    ...field('Hold time', h('select', { onchange: e => postSetup({ hold_duration: Number(e.target.value) }) },
                        ...[[250, '250 ms'], [500, '500 ms'], [750, '750 ms'], [1000, '1 s']].map(([v, l]) =>
                            h('option', { value: v, selected: Number(s.hold_duration) === v }, l))),
                        'How long to hold the soft buttons (Multi, +48V, Mono, Dim).'),
                    ...field('Button LEDs', check('dim_leds_off_state', 'Dim instead of off when a button is off'))),
            ),
            h('div', { class: 'section' },
                h('div', { class: 'section-title' }, 'Panel'),
                h('div', { class: 'field' },
                    ...field('Meters', segmented([['post', 'Post-fader'], ['pre', 'Pre-fader']], s.meter_mode, v => postSetup({ meter_mode: v }))),
                    ...field('FX sends', segmented([['post', 'Post-fader'], ['pre', 'Pre-fader']], s.fx_send_mode, v => postSetup({ fx_send_mode: v })),
                        'Post-fader sends follow the Analog 1/2 faders.'),
                    ...field('Options', h('div', { class: 'checks' },
                        check('hold_clip_indicators', 'Hold clip indicators until clicked'),
                        check('load_latency_clock', 'Presets also load clock, rate and latency'))))),
            h('p', { class: 'dim', style: 'font-size:10px; margin-top:8px' },
                'Low Latency Monitoring stays off: it is a Pro Tools mode that Avid documents as muting the inputs. Use the mixer for zero-latency monitoring.'));
    }

    // MARK: about and flow

    function renderAbout() {
        const S = store.S, info = store.info;
        const row = (k, v) => [h('dt', {}, k), h('dd', {}, v)];
        $('#aboutBody').replaceChildren(
            h('div', { class: 'about-hero' },
                $('.brand-mark').cloneNode(true),
                h('div', { class: 'title' }, 'GhostBox ', h('b', {}, 'Revenant')),
                h('div', { class: 'sub' }, 'Operations center for the Avid Mbox (3rd generation)')),
            h('div', { class: 'card' }, h('dl', {},
                ...row('App', info.app_version || '-'),
                ...row('Core Audio driver', info.driver_version ? `${info.driver_version}${info.driver_latency ? '' : ' (no latency modes)'}` : 'not installed'),
                ...row('Bundled driver', info.bundled_driver_version || '-'),
                ...row('Firmware', S.firmware || '-'),
                ...row('Settings folder', info.data_dir || '-'))),
            h('div', { class: 'row', style: 'margin-top:12px' },
                h('button', { onclick: () => api.revealData() }, 'Show Settings Folder'),
                h('button', { onclick: () => api.openAudioMidiSetup() }, 'Open Audio MIDI Setup'),
                info.bundled_driver_version ? h('button', { dataset: { action: 'installDriver' },
                    title: `Install the driver bundled with this app (${info.bundled_driver_version})` },
                    info.driver_version ? 'Reinstall Driver…' : 'Install Driver…') : null),
            // GPL-3.0 section 5(d): interactive programs show these notices
            h('p', { class: 'about-legal' }, `Copyright © 2026 ${OWNER} and contributors. This program comes with `
                + 'ABSOLUTELY NO WARRANTY. It is free software: you may redistribute and modify it under the GNU General '
                + 'Public License, version 3 or later.'),
            h('p', { class: 'about-legal about-links' },
                h('a', { href: REPOSITORY, target: '_blank', rel: 'noopener' }, 'Source code'), ' · ',
                h('a', { href: 'https://www.gnu.org/licenses/gpl-3.0.html', target: '_blank', rel: 'noopener' }, 'License'), ' · ',
                h('a', { href: `${REPOSITORY}/blob/main/AUTHORS.md`, target: '_blank', rel: 'noopener' }, 'Credits')),
            h('p', { class: 'about-legal' },
                'Independent software. Not affiliated with or endorsed by Avid. Mbox is a trademark of Avid Technology.'));
    }

    // The recording path bridges over the hardware mixer. Inputs (left) and the Mac (right) each feed both mixes and
    // the FX send, the FX return feeds both mixes, and every wire starts and ends on a box edge.
    function renderFlow() {
        if ($('#flowBody').childElementCount) return;
        const summary = 'Signal flow: the four inputs go straight to your Mac. In the hardware mixer, the inputs, the Mac\'s '
            + 'Software Returns and the FX return feed the Analog 1/2 mix (Out 1/2 and headphones) and the S/PDIF L/R mix (S/PDIF Out).';
        const box = (x, y, w, ht, cls = '') => `<rect class="fl-box ${cls}" x="${x}" y="${y}" width="${w}" height="${ht}" rx="6"/>`;
        const label = (x, y, text, cls = '', anchor = 'middle') =>
            `<text class="${cls}" x="${x}" y="${y}" text-anchor="${anchor}">${escapeHTML(text)}</text>`;
        const heading = (x, y, path, meaning, anchor) => `<text x="${x}" y="${y}" text-anchor="${anchor}">`
            + `<tspan class="fl-path">${escapeHTML(path)}</tspan><tspan class="fl-note"> · ${escapeHTML(meaning)}</tspan></text>`;
        const wire = (color, d, cls = '') => `<path class="fl-wire fl-${color} ${cls}" d="${d}" marker-end="url(#flow-${color})"/>`;
        const marker = color => `<marker id="flow-${color}" class="fl-${color}" viewBox="0 0 10 10" refX="9" refY="5" `
            + `markerWidth="8" markerHeight="8" markerUnits="userSpaceOnUse" orient="auto"><path d="M0 1L10 5L0 9z"/></marker>`;
        $('#flowBody').innerHTML = `<svg viewBox="0 0 680 300" role="img" aria-label="${escapeHTML(summary)}">
            <defs>${['in', 'usb', 'fx', 'analog', 'spdif'].map(marker).join('')}</defs>
            ${heading(340, 19, 'TO YOUR MAC', 'what you record', 'middle')}
            <rect class="fl-zone" x="140" y="40" width="400" height="252" rx="10"/>
            ${heading(154, 57, 'HARDWARE MIXER', 'what you hear', 'start')}
            ${box(12, 108, 112, 136)}${label(68, 130, 'Inputs', 'fl-title')}
            ${label(68, 154, 'Input 1')}${label(68, 176, 'Input 2')}${label(68, 198, 'S/PDIF In L')}${label(68, 220, 'S/PDIF In R')}
            ${box(556, 108, 112, 136, 'fl-usb')}${label(612, 172, 'Your Mac', 'fl-title')}${label(612, 188, 'over USB', 'fl-note')}
            ${box(210, 110, 260, 30, 'fl-analog')}${label(340, 129, 'Analog 1/2 mix', 'fl-title')}
            ${box(270, 162, 140, 28, 'fl-fx')}${label(340, 180, 'Reverb / delay (FX)', 'fl-title')}
            ${box(210, 212, 260, 30, 'fl-spdif')}${label(340, 231, 'S/PDIF L/R mix', 'fl-title')}
            ${box(236, 66, 96, 24)}${label(284, 82, 'Out 1/2')}${box(348, 66, 96, 24)}${label(396, 82, 'Headphones')}
            ${box(292, 262, 96, 24)}${label(340, 278, 'S/PDIF Out')}
            ${wire('usb', 'M68 108V28H612V108')}
            ${wire('in', 'M124 125H210')}${wire('in', 'M124 227H210')}${wire('fx', 'M124 176H270', 'fl-send')}
            ${wire('usb', 'M556 125H470')}${wire('usb', 'M556 227H470')}${wire('fx', 'M556 176H410', 'fl-send')}
            ${label(505, 119, 'DAW Ret 1-4', 'fl-note')}${label(505, 221, 'DAW Ret 1-4', 'fl-note')}
            ${label(205, 170, 'FX send', 'fl-note')}${label(475, 170, 'FX send', 'fl-note')}
            ${wire('fx', 'M340 162V140')}${wire('fx', 'M340 190V212')}
            ${wire('analog', 'M284 110V90')}${wire('analog', 'M396 110V90')}${wire('spdif', 'M340 242V262')}
        </svg>
        <ul class="flow-notes">
            <li><b>Recording is dry.</b> Your Mac gets the inputs before any fader or FX: the mixer changes what you hear, not what you record.</li>
            <li><b>Your Mac comes back through the DAW Ret faders.</b> Pull them down or mute them and you won't hear the Mac.</li>
            <li><b>Each mix has its own levels.</b> The Analog 1/2 and S/PDIF L/R tabs pick the mix you are setting.</li>
        </ul>`;
    }

    function open(which) {
        if (which === 'setup') renderSetup();
        if (which === 'about') renderAbout();
        if (which === 'flow') renderFlow();
        openDialog({ setup: 'dlgSetup', about: 'dlgAbout', flow: 'dlgFlow' }[which]);
    }

    /** Keeps an open Setup in step with changes made elsewhere (DAW rate change, menu bar). */
    function render() {
        const choosing = document.activeElement?.tagName === 'SELECT' && $('#dlgSetup').contains(document.activeElement);
        if ($('#dlgSetup').open && !choosing) renderSetup();
        if ($('#dlgAbout').open) renderAbout();
    }

    return { open, render };
}
