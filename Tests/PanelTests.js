// Unit tests for the panel's gain math (Sources/UI/js/gain.js), run by JavaScriptCore:
//   jsc -m Tests/PanelTests.js -- <taper.json from `driver-tests --taper-table`>
// The readouts must show exactly the gain MboxKit sends to the hardware.

import { pctToDb, faderDb, masterDb, channelLaw, masterLaw, stepDb, formatDb, panLabel, UNITY } from '../Sources/UI/js/gain.js';

let checks = 0, failures = 0;
function expect(ok, message) {
    checks++;
    if (!ok) { failures++; print(`  FAIL ${message}`); }
}
function test(name, body) {
    const before = failures;
    body();
    print(`${failures === before ? 'ok  ' : 'FAIL'} ${name}`);
}
const near = (a, b, tol) => Math.abs(a - b) <= tol;

test('readouts match the hardware taper', () => {
    const table = JSON.parse(readFile(arguments[0]));  // levels 0..100 in quarter steps
    expect(table.length === 401, 'table covers 0..100');
    for (let q = 0; q <= 400; q++) {
        const js = pctToDb(q / 4), c = table[q] === null ? -Infinity : table[q];
        expect(js === c || near(js, c, 1e-6), `level ${q / 4}: panel ${js} dB, hardware ${c} dB`);
    }
});

test('channel fader law', () => {
    expect(channelLaw.toPos(UNITY) === 1, 'unity at the top');
    expect(channelLaw.toPos(0) === 0, 'off at the bottom');
    let last = -1, monotonic = true;
    for (let p = 0; p <= 1.0001; p += 0.01) {
        const v = channelLaw.toValue(p);
        monotonic = monotonic && v >= last;
        last = v;
        if (p > 0.05) expect(near(channelLaw.toPos(v), p, 0.012), `round trip at ${p.toFixed(2)}`);
    }
    expect(monotonic, 'travel is monotonic');
    expect(near(faderDb(channelLaw.toValue(0.5)), -20, 0.3), 'half travel is -20 dB');
    expect(near(faderDb(channelLaw.toValue(0.75)), -10, 0.3), 'three quarters is -10 dB');
    // No jumps: over 0.5 % of travel (under a pixel) the gain moves at most ~1 dB in the -60..-30 dB fade zone and
    // half a dB above it (whole-percent levels used to jump 2.9 dB in the lower half of the travel)
    const step = p => faderDb(channelLaw.toValue(p + 0.005)) - faderDb(channelLaw.toValue(p));
    let low = 0, high = 0;
    for (let p = 0.05; p < 0.3; p += 0.005) low = Math.max(low, step(p));
    for (let p = 0.3; p < 0.995; p += 0.005) high = Math.max(high, step(p));
    expect(low <= 1.05, `fade zone: largest step ${low.toFixed(2)} dB`);
    expect(high <= 0.55, `working range: largest step ${high.toFixed(2)} dB`);
});

test('master fader law', () => {
    expect(near(masterLaw.toPos(UNITY), 0.9, 1e-9), 'unity at 90 % of travel');
    expect(masterLaw.toValue(1) === 100, 'top is the +1.4 dB lift');
    expect(near(masterDb(100), 20 * Math.log10(100 / 85), 1e-9), 'lift above unity');
    expect(masterDb(0) === -Infinity, 'off');
});

test('stepping in dB', () => {
    const down = stepDb(channelLaw, UNITY, -1);
    expect(near(faderDb(down), -1, 0.3), `one step down from unity reads ${faderDb(down)}`);
    expect(stepDb(channelLaw, 0, 1) > 0, 'stepping up from off leaves off');
    expect(stepDb(channelLaw, channelLaw.toValue(0.06), -6) === 0, 'stepping below -60 dB turns it off');
});

test('formatting', () => {
    expect(formatDb(-Infinity) === '−∞', 'minus infinity');
    expect(formatDb(0) === '0.0', 'unity');
    expect(formatDb(-6.02) === '−6.0', 'negative with a real minus sign');
    expect(formatDb(1.41) === '+1.4', 'positive with a plus sign');
    expect(panLabel(0) === 'C' && panLabel(-50) === 'L50' && panLabel(12) === 'R12', 'pan labels');
});

print(`panel tests: ${checks} checks, ${failures} failed`);
if (failures) throw new Error('panel tests failed');
