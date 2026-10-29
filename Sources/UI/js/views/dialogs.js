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

    function renderFlow() {
        if ($('#flowBody').childElementCount) return;
        const box = (x, y, w, label, color = '#3a3d45', text = '#e9eaee') =>
            `<rect x="${x}" y="${y}" width="${w}" height="26" rx="5" fill="#1d1f24" stroke="${color}"/>` +
            `<text x="${x + w / 2}" y="${y + 17}" fill="${text}" text-anchor="middle">${escapeHTML(label)}</text>`;
        $('#flowBody').innerHTML = `<svg viewBox="0 0 680 300" font-family="-apple-system, sans-serif" font-size="11">
            ${box(20, 30, 100, 'Input 1')}${box(20, 70, 100, 'Input 2')}${box(20, 110, 100, 'S/PDIF In L')}${box(20, 150, 100, 'S/PDIF In R')}
            <rect x="250" y="24" width="160" height="72" rx="8" fill="#1d1f24" stroke="#f5a524"/>
            <text x="330" y="54" fill="#f5a524" text-anchor="middle" font-weight="600">USB to and from</text>
            <text x="330" y="72" fill="#e9eaee" text-anchor="middle">your Mac (4 in, 4 out)</text>
            <rect x="220" y="140" width="220" height="30" rx="6" fill="#1d1f24" stroke="#5fd13f"/>
            <text x="330" y="159" fill="#5fd13f" text-anchor="middle" font-weight="600">Analog 1/2 mix</text>
            <rect x="220" y="186" width="220" height="30" rx="6" fill="#1d1f24" stroke="#4cc2ff"/>
            <text x="330" y="205" fill="#4cc2ff" text-anchor="middle" font-weight="600">S/PDIF L/R mix</text>
            <rect x="220" y="232" width="220" height="30" rx="6" fill="#1d1f24" stroke="#b17cff"/>
            <text x="330" y="251" fill="#b17cff" text-anchor="middle" font-weight="600">Reverb / delay (FX)</text>
            ${box(560, 120, 100, 'Headphones')}${box(560, 156, 100, 'Out 1 / Out 2')}${box(560, 200, 100, 'S/PDIF Out')}
            <g stroke="#5fd13f" stroke-width="1.4" fill="none" opacity="0.85">
              <path d="M120 43 H250 M120 83 H250 M120 123 H250 M120 163 H250"/>
              <path d="M160 43 V245 H220 M175 83 V200 M190 123 V200 M205 163 V155 H220"/>
              <path d="M440 155 H560 M500 155 V133 H560 M500 155 V169"/>
            </g>
            <path d="M440 201 H560" stroke="#4cc2ff" stroke-width="1.4" fill="none"/>
            <path d="M440 247 H470 V155 M470 201" stroke="#b17cff" stroke-width="1.4" fill="none"/>
            <path d="M330 96 V140" stroke="#f5a524" stroke-width="1.4" fill="none" stroke-dasharray="3 3"/>
            <text x="338" y="122" fill="#a9adb7">Software Returns 1-4</text>
            <text x="20" y="215" fill="#a9adb7">Inputs also go to the Mac</text>
            <text x="20" y="230" fill="#a9adb7">and into both mixes and the FX sends.</text>
        </svg>`;
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
