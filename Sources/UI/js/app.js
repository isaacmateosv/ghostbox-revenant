// GhostBox Revenant GUI panel: bootstrap, actions, polling.
//
//   api.js            the app's local API, ActionQueue (coalesced posts)
//   store.js          the panel's copy of the engine state
//   gain.js           gain math and fader law (mirrors MboxKit's taper)
//   controls/         knob, fader, meter
//   views/            console (mixer), chrome (top bar, banners, status), dialogs, tuner, tools, fit, toast
//
// The engine is the single source of truth. Controls update the local state at once and post an action; the
// meters poll (60 ms) carries the engine's revision, and a newer revision (menu bar, front panel, DAW) refetches
// the state.

import { $$, icons } from './dom.js';
import { api, ActionQueue } from './api.js';
import { store, mix, otherBus, busName } from './store.js';
import { installKnobDefs } from './controls/knob.js';
import { createConsole } from './views/console.js';
import { createChrome } from './views/chrome.js';
import { createDialogs, closeDialog } from './views/dialogs.js';
import { createTuner } from './views/tuner.js';
import { createTools } from './views/tools.js';
import { createFit } from './views/fit.js';
import { toast } from './views/toast.js';

const POLL_MS = 60, HIDDEN_POLL_MS = 400;

let pendingState = null;  // a response that arrived while a control was being dragged
const queue = new ActionQueue(d => accept(d), e => toast(`Not applied: ${e.message}`, { error: true }));

const ctx = {
    post: (action, payload, key) => queue.send(action, payload, key),
    render: () => renderAll(),
    apply: d => accept(d, true),
    toast,
    refit: () => fit.refresh(),
};

installKnobDefs();
for (const el of $$('[data-icon]')) el.insertAdjacentHTML('afterbegin', icons[el.dataset.icon] || '');
for (const el of $$('button.link')) el.insertAdjacentHTML('afterbegin', icons.link);

const consoleView = createConsole(ctx);
const chrome = createChrome(ctx);
const dialogs = createDialogs(ctx);
const tuner = createTuner(ctx);
const tools = createTools(ctx);
const fit = createFit();

function accept(d, force = false) {
    if (!force && (store.dragging > 0 || !queue.idle)) { pendingState = d; return; }
    pendingState = null;
    const lastJob = store.info.driver_job;
    store.S = d.state;
    if (d.rev) store.rev = d.rev;
    if (d.info) store.info = d.info;
    const job = store.info.driver_job;
    if (lastJob && job && job.id !== lastJob.id && job.message) toast(job.message, { error: job.state === 'failed' });
    renderAll();
}

function renderAll() {
    const S = store.S;
    if (!S) return;
    const root = document.documentElement;
    root.classList.toggle('layout-vertical', S.layout.startsWith('vertical'));
    root.classList.toggle('meters-only', S.layout.endsWith('meters'));
    consoleView.render();
    chrome.render();
    tools.render();
    dialogs.render();
    tuner.render();
    fit.set(!!S.ui?.fit);
    fit.refresh();
}

// MARK: actions

function setUI(patch) {
    Object.assign(store.S.ui, patch);
    ctx.post('update_ui', { ui: patch }, 'ui:' + Object.keys(patch).join(','));
    renderAll();
}

function setGlobal(feature) {
    store.S[feature] = !store.S[feature];
    ctx.post('set_global', { feature, on: store.S[feature] }, feature);
    renderAll();
}

async function run(promise, done) {
    try { await promise; if (done) toast(done); } catch (e) { toast(e.message, { error: true }); }
}

const actions = {
    mix: bus => { if (store.S.active_mix !== bus) { store.S.active_mix = bus; ctx.post('switch_bus', { bus }, 'bus'); renderAll(); } },
    layout: layout => { store.S.layout = layout; ctx.post('set_layout', { layout }, 'layout'); renderAll(); },
    fit: () => setUI({ fit: !store.S.ui.fit }),
    tools: () => setUI({ tools_open: !store.S.ui.tools_open }),
    toolsTab: tab => setUI({ tools_tab: tab, tools_open: store.S.ui.tools_tab === tab ? !store.S.ui.tools_open : true }),
    link: key => consoleView.toggleLink(key),
    dim: () => setGlobal('dim'),
    mono: () => setGlobal('mono'),
    clearSolos: () => {
        for (const m of Object.values(store.S.mixes)) {
            [...m.hw, ...m.sw].forEach(c => { c.solo = false; });
            m.fx_ret.solo_l = m.fx_ret.solo_r = false;
        }
        ctx.post('clear_solos');
        renderAll();
        toast('Solos cleared');
    },
    copyMix: () => {
        const from = store.S.active_mix, to = otherBus();
        if (!confirm(`Replace the ${busName(to)} mix with a copy of the ${busName(from)} mix?`)) return;
        store.S.mixes[to] = JSON.parse(JSON.stringify(mix()));
        ctx.post('copy_mix', { from, to });
        toast(`Copied to ${busName(to)}`);
    },
    tuner: () => tuner.toggle(),
    closeTuner: () => tuner.hide(true),
    tunerMic: () => tuner.toggleMic(),
    setup: () => dialogs.open('setup'),
    about: () => dialogs.open('about'),
    flow: () => dialogs.open('flow'),
    closeDialog: (_, el) => closeDialog(el),
    loadPreset: () => chrome.loadPreset(),
    savePreset: () => chrome.savePreset(),
    deletePreset: () => chrome.deletePreset(),
    dismissDriverBanner: () => chrome.dismissDriverBanner(),
    reenumerate: () => run(api.reenumerate(), 'USB connection reset: the Mbox reconnects in a few seconds'),
    installDriver: () => {
        const v = store.info.bundled_driver_version;
        if (!confirm(`Install the Mbox 3 driver ${v}? macOS asks for your password. Core Audio restarts, so sound stops for a second; ` +
            'apps that were using audio may need to be reopened. For 3 minutes a watchdog removes the driver again if Core Audio misbehaves.')) return;
        run(api.installDriver(), 'Waiting for your password…');
    },
    initialize: async () => {
        if (!confirm('Reset the mixer, effect and setup to factory defaults? Presets are kept.')) return;
        try { accept(await api.initialize(), true); toast('Defaults restored'); } catch (e) { toast(e.message, { error: true }); }
    },
    multiLearn: () => tools.multi.learn(),
    multiForget: () => tools.multi.forget(),
    openAMS: () => run(api.openAudioMidiSetup()),
    revealData: () => run(api.revealData()),
    rescan: () => tools.loadDiagnostics(),
};

const changes = {
    multiAction: value => tools.multi.action(value),
    holdTime: value => { store.S.setup.hold_duration = Number(value); ctx.post('update_setup', { setup: store.S.setup }, 'setup'); },
    tunerInput: value => tuner.selectInput(value),
    calc: () => tools.calc(),
};

document.addEventListener('click', e => {
    const el = e.target.closest('[data-action]');
    if (!el || el.disabled || !store.S) return;
    const fn = actions[el.dataset.action];
    if (fn) { e.preventDefault(); fn(el.dataset.arg, el, e); }
});
document.addEventListener('change', e => {
    const el = e.target.closest('[data-change]');
    if (el && store.S) changes[el.dataset.change]?.(el.value, el);
});
document.addEventListener('input', e => {
    if (e.target.dataset.input === 'calc') tools.calc();
});

// Commands from the app's menus (MainWindowController.run)
window.mbox = {
    command(name) {
        if (!store.S) return;
        if (name === 'clearClips') { consoleView.clearClips(); toast('Clip indicators cleared'); }
        else actions[name]?.();
    },
};

// MARK: polling

let refetching = false;

async function poll() {
    if (document.hidden) { setTimeout(poll, HIDDEN_POLL_MS); return; }
    try {
        const d = await api.meters();
        consoleView.renderMeters(d);
        chrome.renderPanel(d);
        tools.renderMeters(d);
        tuner.onMeters(d);
        if (store.dragging === 0 && queue.idle) {
            if (pendingState) accept(pendingState);
            else if (d.rev > store.rev && !refetching) {
                refetching = true;
                api.state().then(s => accept(s)).catch(() => {}).finally(() => { refetching = false; });
            }
        }
    } catch {
        chrome.renderPanel({ offline: true, connected: false, panel: {} });
    }
    setTimeout(poll, POLL_MS);
}

async function start() {
    try {
        accept(await api.state(), true);
    } catch {
        toast('Cannot reach GhostBox Revenant GUI. Is the app running?', { error: true });
        setTimeout(start, 1000);
        return;
    }
    chrome.refreshPresets();
    tools.loadDiagnostics();
    poll();
}

start();
