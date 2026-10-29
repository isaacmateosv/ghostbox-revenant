// The tuner. While tuner mode is on, the Mbox measures pitch itself and reports note and cents over MIDI (the app
// decodes it; see Model/Tuner.swift). A microphone can stand in, on request only (it asks for permission).

import { $, h, setText } from '../dom.js';
import { store } from '../store.js';

const NOTES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

export function createTuner(ctx) {
    const dlg = $('#dlgTuner');
    let isOpen = false, lastHardware = 0, lastUserChange = 0, lastReading = 0;
    let mic = null;  // { stream, ctx, timer }

    function setTuner(on) {
        lastUserChange = Date.now();
        store.S.tuner = on;
        ctx.post('set_tuner', { tuner: on }, 'tuner');
        ctx.render();
    }

    function show(fromUser) {
        if (!dlg.open) dlg.showModal();
        isOpen = true;
        idle('Play a single note');
        if (fromUser && !store.S.tuner) setTuner(true);
    }

    function hide(fromUser) {
        isOpen = false;
        stopMic();
        if (dlg.open) dlg.close();
        if (fromUser && store.S.tuner) setTuner(false);
    }

    // Esc closes the dialog: leave tuner mode too
    dlg.addEventListener('close', () => { if (isOpen) hide(true); });

    const toggle = () => (isOpen ? hide(true) : show(true));

    /** Follows tuner mode started or stopped elsewhere (Dim + Mono on the Mbox, the menu bar). */
    function render() {
        if (Date.now() - lastUserChange < 1500) return;
        if (store.S.tuner && !isOpen) show(false);
        if (!store.S.tuner && isOpen) hide(false);
    }

    function idle(text) {
        const note = $('#tunerNote');
        setText(note, '–');
        note.className = 'note';
        setText($('#tunerCents'), text);
        $('#tunerNeedle').classList.remove('live');
        $('#tunerNeedle').style.left = '50%';
        $('#tunerLed0').className = 'led';
        $('#tunerLed1').className = 'led';
    }

    function display(cents, note, source) {
        lastReading = Date.now();
        const inTune = Math.abs(cents) <= 3;
        const el = $('#tunerNote');
        setText(el, note);
        el.className = 'note' + (inTune ? ' in-tune' : Math.abs(cents) <= 10 ? ' close' : '');
        setText($('#tunerCents'), inTune ? 'in tune' : `${cents > 0 ? '+' : '−'}${Math.abs(cents)} ¢ ${cents > 0 ? 'sharp' : 'flat'}`);
        const needle = $('#tunerNeedle');
        needle.classList.add('live');
        needle.style.left = `${50 + (cents / 50) * 46}%`;
        // The front-panel logic: Input 1 red = flat, Input 2 red = sharp, both green = in tune
        $('#tunerLed0').className = 'led' + (inTune ? ' green' : cents < 0 ? ' red' : '');
        $('#tunerLed1').className = 'led' + (inTune ? ' green' : cents > 0 ? ' red' : '');
        setText($('#tunerSource'), source);
    }

    function onMeters(d) {
        if (!isOpen) return;
        const p = d.panel || {};
        if (p.tuner_note !== undefined) {
            lastHardware = Date.now();
            display(p.tuner_cents, p.tuner_note, 'Pitch from the Mbox\'s own tuner.');
        } else if (Date.now() - lastReading > 700) {
            idle(mic ? 'Listening to the microphone…' : 'Play a single note (the Mbox reports pitch while a note sounds)');
        }
    }

    // MARK: microphone fallback

    function stopMic() {
        if (!mic) return;
        clearInterval(mic.timer);
        mic.stream.getTracks().forEach(t => t.stop());
        mic.ctx.close();
        mic = null;
        $('#tunerMic').hidden = true;
        setText($('#tunerMicToggle'), 'Use a microphone instead');
    }

    async function startMic(deviceId) {
        stopMic();
        try {
            const stream = await navigator.mediaDevices.getUserMedia({ audio: {
                deviceId: deviceId ? { exact: deviceId } : undefined, echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
            const devices = (await navigator.mediaDevices.enumerateDevices()).filter(dv => dv.kind === 'audioinput');
            const current = stream.getAudioTracks()[0].getSettings().deviceId;
            $('#tunerInput').replaceChildren(...devices.map(dv => h('option', { value: dv.deviceId, selected: dv.deviceId === current }, dv.label || 'Audio input')));
            const audio = new AudioContext();
            const analyser = audio.createAnalyser();
            analyser.fftSize = 4096;
            audio.createMediaStreamSource(stream).connect(analyser);
            const buf = new Float32Array(analyser.fftSize);
            let smooth = null;
            const timer = setInterval(() => {
                if (Date.now() - lastHardware < 1000) return;  // the Mbox is reporting
                analyser.getFloatTimeDomainData(buf);
                const freq = detectPitch(buf, audio.sampleRate);
                if (!freq) { smooth = null; return; }
                const midi = 69 + 12 * Math.log2(freq / 440);
                smooth = smooth === null || Math.abs(smooth - midi) > 0.5 ? midi : smooth * 0.7 + midi * 0.3;
                const nearest = Math.round(smooth);
                const cents = Math.max(-50, Math.min(50, Math.round((smooth - nearest) * 100)));
                display(cents, `${NOTES[((nearest % 12) + 12) % 12]}${Math.floor(nearest / 12) - 1}`, `Microphone: ${freq.toFixed(1)} Hz`);
            }, 80);
            mic = { stream, ctx: audio, timer };
            $('#tunerMic').hidden = false;
            setText($('#tunerMicToggle'), 'Stop the microphone');
        } catch {
            setText($('#tunerSource'), 'Microphone access was not granted. The Mbox\'s tuner and its LEDs still work.');
        }
    }

    const toggleMic = () => (mic ? stopMic() : startMic());

    return { toggle, show, hide, render, onMeters, toggleMic, selectInput: id => startMic(id) };
}

// Normalised autocorrelation (McLeod-style) with parabolic peak refinement; reliable for guitar and bass, 30-1200 Hz.
function detectPitch(buf, sr) {
    const n = buf.length;
    let rms = 0;
    for (let i = 0; i < n; i++) rms += buf[i] * buf[i];
    if (Math.sqrt(rms / n) < 0.008) return null;
    const minLag = Math.floor(sr / 1200), maxLag = Math.min(n >> 1, Math.floor(sr / 30));
    const nsdf = new Float32Array(maxLag + 1);
    for (let lag = minLag; lag <= maxLag; lag++) {
        let ac = 0, m = 0;
        for (let i = 0; i < n - lag; i++) { ac += buf[i] * buf[i + lag]; m += buf[i] * buf[i] + buf[i + lag] * buf[i + lag]; }
        nsdf[lag] = m > 0 ? (2 * ac) / m : 0;
    }
    let best = -1, bestVal = 0;
    for (let lag = minLag + 1; lag < maxLag; lag++) if (nsdf[lag] > bestVal) bestVal = nsdf[lag];
    // first local peak above 90 % of the global maximum avoids octave errors
    for (let lag = minLag + 1; lag < maxLag; lag++) {
        if (nsdf[lag] > 0.9 * bestVal && nsdf[lag] >= nsdf[lag - 1] && nsdf[lag] >= nsdf[lag + 1]) { best = lag; break; }
    }
    if (best < 0 || bestVal < 0.6) return null;
    const a = nsdf[best - 1], b = nsdf[best], c = nsdf[best + 1];
    const shift = (a - c) / (2 * (a - 2 * b + c) || 1);
    return sr / (best + shift);
}
