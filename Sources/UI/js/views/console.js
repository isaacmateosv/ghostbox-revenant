// The mixer console: input and return strips, master, FX sends and returns, the effect unit.
// Controls change the local state at once and post the action; render() repaints from the state.

import { $, h, setText, setOn } from '../dom.js';
import { store, mix, isLinked, sibling, otherBus, busName } from '../store.js';
import { Knob } from '../controls/knob.js';
import { Fader } from '../controls/fader.js';
import { Meter, meterScale } from '../controls/meter.js';
import { channelLaw, masterLaw, faderDb, pctToDb, formatDb, panLabel, UNITY } from '../gain.js';

export const EFFECTS = ['Room 1', 'Room 2', 'Room 3', 'Hall 1', 'Hall 2', 'Plate', 'Delay', 'Echo'];
const SEND_NAMES = { hw: ['In 1', 'In 2', 'S/PDIF L', 'S/PDIF R'], sw: ['Ret 1', 'Ret 2', 'Ret 3', 'Ret 4'] };
const percent = v => `${Math.round(v)}%`;
const dbText = db => `${formatDb(db)} dB`;

export function createConsole(ctx) {
    const strips = { hw: [], sw: [] };
    const sends = { hw: [], sw: [] };
    const bus = () => store.S.active_mix;

    // MARK: channel strips

    function postChannel(kind, idx, target = bus()) {
        const m = store.S.mixes[target];
        const linked = !!m.links[kind + (idx < 2 ? '12' : '34')];
        ctx.post('update_channel', { bus: target, kind, idx, ch: m[kind][idx], sibling_val: linked ? m[kind][idx].fader : null },
            `ch:${target}:${kind}:${idx}`);
    }

    function setReadout(s, v) {
        const db = faderDb(v);
        setText(s.readout, formatDb(db));
        setOn(s.readout, db === 0 && v > 0, 'unity');
    }

    function faderMoved(kind, idx, v) {
        const m = mix();
        m[kind][idx].fader = v;
        setReadout(strips[kind][idx], v);
        if (isLinked(kind, idx)) {
            const sib = sibling(idx);
            m[kind][sib].fader = v;
            strips[kind][sib].fader.value = v;
            setReadout(strips[kind][sib], v);
        }
        postChannel(kind, idx);
    }

    function toggleSoloMute(kind, idx, field) {
        const m = mix(), v = !m[kind][idx][field];
        m[kind][idx][field] = v;
        if (isLinked(kind, idx)) m[kind][sibling(idx)][field] = v;
        ctx.post('update_channel_pair', { bus: bus(), kind, channels: m[kind] }, `pair:${bus()}:${kind}`);
        ctx.render();
    }

    // Names belong to the channel, so a rename applies to both mixes
    function rename(kind, idx) {
        const s = strips[kind][idx], current = mix()[kind][idx].label;
        const input = h('input', { type: 'text', class: 'strip-name', value: current, maxlength: 24, 'aria-label': 'Channel name' });
        s.name.replaceWith(input);
        input.focus();
        input.select();
        let done = false;
        const finish = save => {
            if (done) return;
            done = true;
            input.replaceWith(s.name);
            const name = input.value.trim();
            if (!save || !name || name === current) return;
            for (const target of ['analog', 'spdif']) {
                store.S.mixes[target][kind][idx].label = name;
                postChannel(kind, idx, target);
            }
            setText(s.name, name);
        };
        input.addEventListener('keydown', e => {
            if (e.key === 'Enter') finish(true);
            if (e.key === 'Escape') finish(false);
        });
        input.addEventListener('blur', () => finish(true));
    }

    function buildStrip(kind, idx) {
        const s = {};
        s.name = h('div', { class: 'strip-name', title: 'Click to rename', onclick: () => rename(kind, idx) });
        s.panValue = h('div', { class: 'pan-value' }, 'C');
        s.pan = new Knob({
            min: -50, max: 50, reset: 0, size: 28, label: 'Pan', format: panLabel,
            onInput: v => { mix()[kind][idx].pan = v; setText(s.panValue, panLabel(v)); postChannel(kind, idx); },
        });
        s.solo = h('button', { class: 'solo', title: 'Solo', onclick: () => toggleSoloMute(kind, idx, 'solo') }, 'S');
        s.mute = h('button', { class: 'mute', title: 'Mute', onclick: () => toggleSoloMute(kind, idx, 'mute') }, 'M');
        s.fader = new Fader({ law: channelLaw, reset: UNITY, label: 'Level', onInput: v => faderMoved(kind, idx, v) });
        s.meter = new Meter();
        s.readout = h('div', { class: 'readout', title: 'Gain into this mix (dB)' }, '−∞');
        s.el = h('div', { class: 'strip' },
            s.name,
            h('div', { class: 'pan' }, s.pan.el, s.panValue),
            h('div', { class: 'sm' }, s.solo, s.mute),
            h('div', { class: 'fader-meter' }, s.fader.el, s.meter.el),
            s.readout);
        return s;
    }

    for (const kind of ['hw', 'sw']) {
        const grid = $(kind === 'hw' ? '#hwStrips' : '#swStrips');
        for (let i = 0; i < 4; i++) {
            const s = buildStrip(kind, i);
            strips[kind].push(s);
            grid.append(s.el);
        }
    }

    // MARK: master

    const master = {};
    const masterEl = $('#master');
    function postMaster() { ctx.post('update_master', { bus: bus(), master: mix().master }, `master:${bus()}`); }
    master.balanceValue = h('span', { class: 'knob-value' }, 'C');
    master.widthValue = h('span', { class: 'knob-value' }, '100%');
    master.balance = new Knob({
        min: -50, max: 50, reset: 0, label: 'Balance', format: panLabel,
        onInput: v => { mix().master.balance = v; setText(master.balanceValue, panLabel(v)); postMaster(); },
    });
    master.width = new Knob({
        min: 0, max: 100, reset: 100, label: 'Stereo width', format: percent,
        onInput: v => { mix().master.width = v; setText(master.widthValue, percent(v)); postMaster(); },
    });
    const toggleMasterMute = field => {
        const m = mix().master, v = !m[field];
        m[field] = v;
        if (mix().links.master) { m.mute_l = v; m.mute_r = v; }
        postMaster();
        ctx.render();
    };
    master.muteL = h('button', { title: 'Mute left', onclick: () => toggleMasterMute('mute_l') }, 'M L');
    master.muteR = h('button', { title: 'Mute right', onclick: () => toggleMasterMute('mute_r') }, 'M R');
    master.swap = h('button', { id: 'masterSwap', title: 'Swap left and right', onclick: () => { mix().master.swap = !mix().master.swap; postMaster(); ctx.render(); } }, 'Swap');
    master.link = h('button', { id: 'link_master', class: 'link', dataset: { action: 'link', arg: 'master' }, title: 'Link the master mutes and the FX return pair' }, 'Link');
    master.readout = h('div', { class: 'readout', title: 'Master level' }, '0.0');
    master.fader = new Fader({
        law: masterLaw, reset: UNITY, label: 'Master level',
        onInput: v => { mix().master.fader = v; setText(master.readout, formatDb(masterLaw.db(v))); postMaster(); },
    });
    master.meterL = new Meter({ wide: true });
    master.meterR = new Meter({ wide: true });
    master.dim = h('button', { id: 'btnDim', dataset: { action: 'dim' }, title: 'Dim the outputs (⇧⌘D)' }, 'DIM');
    master.mono = h('button', { id: 'btnMono', dataset: { action: 'mono' }, title: 'Sum the outputs to mono (⇧⌘M)' }, 'MONO');
    master.copy = h('button', { id: 'copyMix', class: 'ghost mini', dataset: { action: 'copyMix' } });
    master.title = h('span', { class: 'badge' });
    master.outs = [new Meter(), new Meter(), new Meter(), new Meter()];
    masterEl.append(
        h('header', { class: 'group-head' }, h('h2', {}, 'Master'), master.copy),
        h('div', { class: 'master-body' },
            h('div', { class: 'master-controls' },
                h('div', { class: 'knob-row' },
                    h('div', { class: 'knob-cell' }, 'Balance', master.balance.el, master.balanceValue),
                    h('div', { class: 'knob-cell' }, 'Width', master.width.el, master.widthValue)),
                h('div', { class: 'pair' }, master.muteL, master.muteR),
                master.swap,
                master.link),
            h('div', { class: 'master-fader' },
                h('div', { class: 'fader-meter' }, master.fader.el, master.meterL.el, master.meterR.el, meterScale()),
                master.readout)),
        h('div', { class: 'outputs' },
            h('div', { class: 'pair-meter' }, 'Out 1/2', h('div', { class: 'meters' }, master.outs[0].el, master.outs[1].el)),
            h('div', { class: 'pair-meter' }, 'Out 3/4 (S/PDIF)', h('div', { class: 'meters' }, master.outs[2].el, master.outs[3].el))),
        h('div', { class: 'globals' }, master.dim, master.mono));

    // MARK: FX sends, returns and the effect unit

    function postSends() { ctx.post('update_fx_sends', { fx_sends: store.S.fx_sends }, 'fxsends'); }
    for (const kind of ['hw', 'sw']) {
        const row = $(kind === 'hw' ? '#hwSends' : '#swSends');
        for (let i = 0; i < 4; i++) {
            const value = h('span', { class: 'knob-value' }, '−∞');
            const knob = new Knob({
                min: 0, max: 100, reset: 0, variant: 'fx', label: `FX send ${SEND_NAMES[kind][i]}`, format: v => dbText(pctToDb(v)),
                onInput: v => {
                    store.S.fx_sends[kind][i] = v;
                    setText(value, formatDb(pctToDb(v)));
                    if (isLinked(kind, i)) {
                        const sib = sibling(i);
                        store.S.fx_sends[kind][sib] = v;
                        sends[kind][sib].knob.value = v;
                        setText(sends[kind][sib].value, formatDb(pctToDb(v)));
                    }
                    postSends();
                },
            });
            const name = h('span', { class: 'send-name' }, SEND_NAMES[kind][i]);
            sends[kind].push({ knob, value, name });
            row.append(h('div', { class: 'send' }, name, knob.el, value));
        }
    }

    const fx = {};
    function postFxReturn() { ctx.post('update_fx_ret', { bus: bus(), fx_ret: mix().fx_ret }, `fxret:${bus()}`); }
    const fxLinked = () => mix().links.master || mix().links.fxret;
    function fxSide(side) {
        const value = h('span', { class: 'knob-value' }, '−∞');
        const knob = new Knob({
            min: 0, max: UNITY, reset: UNITY, variant: 'fx', label: `FX return ${side.toUpperCase()}`, format: v => dbText(faderDb(v)),
            onInput: v => {
                const r = mix().fx_ret;
                r[side] = v;
                if (fxLinked()) { r.l = v; r.r = v; }
                renderFx();
                postFxReturn();
            },
        });
        const toggle = field => {
            const r = mix().fx_ret, v = !r[`${field}_${side}`];
            r[`${field}_${side}`] = v;
            if (fxLinked()) { r[`${field}_l`] = v; r[`${field}_r`] = v; }
            postFxReturn();
            ctx.render();
        };
        const solo = h('button', { class: 'solo', title: 'Solo', onclick: () => toggle('solo') }, 'S');
        const mute = h('button', { class: 'mute', title: 'Mute', onclick: () => toggle('mute') }, 'M');
        return { knob, value, solo, mute, el: h('div', { class: 'side' }, side.toUpperCase(), knob.el, value, h('div', { class: 'sm' }, solo, mute)) };
    }
    fx.l = fxSide('l');
    fx.r = fxSide('r');
    fx.meterL = new Meter({ title: 'Effect output (clip: effect input or output). Click to clear.' });
    fx.meterR = new Meter({ title: 'Effect output (clip: effect input or output). Click to clear.' });
    $('#fxReturns').append(
        h('header', { class: 'group-head' }, h('h2', {}, 'FX Returns'), h('span', { class: 'badge' }, 'This mix')),
        h('div', { class: 'fxret-body' }, fx.l.el, fx.r.el, h('div', { class: 'fx-meters' }, fx.meterL.el, fx.meterR.el)));

    const dsp = {};
    function postDsp() { ctx.post('update_dsp', { dsp: store.S.dsp }, 'dsp'); }
    dsp.select = h('select', { 'aria-label': 'Effect type', onchange: e => { store.S.dsp.effect = Number(e.target.value); postDsp(); ctx.render(); } },
        ...EFFECTS.map((name, i) => h('option', { value: i }, name)));
    function dspKnob(field, label) {
        const value = h('span', { class: 'knob-value' }, '0%');
        const knob = new Knob({
            min: 0, max: 100, reset: field === 'volume' ? 0 : 50, variant: 'fx', label, format: percent,
            onInput: v => { store.S.dsp[field] = v; setText(value, percent(v)); postDsp(); },
        });
        const cell = h('div', { class: 'knob-cell' }, label, knob.el, value);
        return { knob, value, cell };
    }
    dsp.duration = dspKnob('duration', 'Duration');
    dsp.feedback = dspKnob('feedback', 'Feedback');
    dsp.volume = dspKnob('volume', 'Volume');
    dsp.feedback.cell.title = 'Number of repeats (Delay and Echo only)';
    $('#dsp').append(
        h('header', { class: 'group-head' }, h('h2', {}, 'Effect')),
        h('div', { class: 'dsp-effect' }, dsp.select),
        dsp.duration.cell, dsp.feedback.cell, dsp.volume.cell);

    // MARK: render

    function renderFx() {
        const r = mix().fx_ret;
        for (const side of ['l', 'r']) {
            fx[side].knob.value = r[side];
            setText(fx[side].value, formatDb(faderDb(r[side])));
            setOn(fx[side].solo, r[`solo_${side}`]);
            setOn(fx[side].mute, r[`mute_${side}`]);
        }
    }

    function render() {
        const S = store.S, m = mix();
        for (const kind of ['hw', 'sw']) {
            m[kind].forEach((ch, i) => {
                const s = strips[kind][i];
                if (!s) return;
                setText(s.name, ch.label);  // (while renaming, the name element is detached)
                s.pan.value = ch.pan;
                setText(s.panValue, panLabel(ch.pan));
                setOn(s.solo, ch.solo);
                setOn(s.mute, ch.mute);
                s.fader.value = ch.fader;
                if (!s.fader.dragging) setReadout(s, ch.fader);
                const send = sends[kind][i];
                send.knob.value = S.fx_sends[kind][i];
                setText(send.value, formatDb(pctToDb(S.fx_sends[kind][i])));
                send.name.title = ch.label;
            });
        }
        for (const key of ['hw12', 'hw34', 'sw12', 'sw34', 'master']) setOn($('#link_' + key), m.links[key]);
        const mm = m.master;
        master.balance.value = mm.balance;
        setText(master.balanceValue, panLabel(mm.balance));
        master.width.value = mm.width;
        setText(master.widthValue, percent(mm.width));
        master.fader.value = mm.fader;
        if (!master.fader.dragging) setText(master.readout, formatDb(masterLaw.db(mm.fader)));
        setOn(master.muteL, mm.mute_l);
        setOn(master.muteR, mm.mute_r);
        setOn(master.swap, mm.swap);
        setOn(master.dim, S.dim);
        setOn(master.mono, S.mono);
        setText(master.copy, `Copy to ${busName(otherBus())} →`);
        master.copy.title = `Replace the ${busName(otherBus())} mix with this one`;
        renderFx();
        dsp.select.value = S.dsp.effect;
        for (const field of ['duration', 'feedback', 'volume']) {
            dsp[field].knob.value = S.dsp[field];
            setText(dsp[field].value, percent(S.dsp[field]));
        }
        dsp.feedback.cell.classList.toggle('disabled', S.dsp.effect < 6);
        setText($('#meterModeBadge'), S.setup.meter_mode === 'post' ? 'Post-fader meters' : 'Pre-fader meters');
        setText($('#fxSendModeBadge'), S.setup.fx_send_mode === 'post' ? 'Post-fader (Analog 1/2)' : 'Pre-fader');
    }

    function renderMeters(d) {
        const hold = store.S?.setup.hold_clip_indicators ?? true;
        const m = d.meters, c = d.clips;
        for (const kind of ['hw', 'sw']) strips[kind].forEach((s, i) => s.meter.set(m[kind][i], c[kind][i], hold));
        const spdif = store.S?.active_mix === 'spdif';
        const pair = spdif ? m.out34 : m.out12, pairClip = spdif ? c.out34 : c.out12;
        master.meterL.set(pair[0], pairClip[0], hold);
        master.meterR.set(pair[1], pairClip[1], hold);
        [...m.out12, ...m.out34].forEach((v, i) => master.outs[i].set(v, [...c.out12, ...c.out34][i], hold));
        fx.meterL.set(m.fx[0], c.fx[0], hold);
        fx.meterR.set(m.fx[1], c.fx[1], hold);
    }

    function clearClips() {
        for (const kind of ['hw', 'sw']) strips[kind].forEach(s => s.meter.clearClip());
        [master.meterL, master.meterR, fx.meterL, fx.meterR, ...master.outs].forEach(mt => mt.clearClip());
    }

    function toggleLink(key) {
        const m = mix();
        m.links[key] = !m.links[key];
        if (key === 'master') m.links.fxret = m.links.master;
        ctx.post('update_links', { bus: bus(), links: m.links }, `links:${bus()}`);
        ctx.render();
    }

    return { render, renderMeters, clearClips, toggleLink };
}
