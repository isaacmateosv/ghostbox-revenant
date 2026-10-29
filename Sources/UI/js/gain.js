// Gain math. The readouts mirror MboxKit's mixer taper (Sources/MboxKit/MboxControl.cpp), so the panel shows the
// gain the hardware really gets. Fader travel follows a console-style law (the upper half covers 0 to -20 dB)
// while the stored value keeps its meaning: 0 = off, 85 = unity, gain linear in amplitude.

export const UNITY = 85;                   // fader value at 0 dB
const KNEE_PCT = 15, KNEE_DB = -16.478;    // the taper turns logarithmic at 15 % (20*log10(0.15))
const FLOOR_DB = -60;

const lround = x => (x < 0 ? -Math.round(-x) : Math.round(x));

/** Hardware gain (dB, quantised to the Mbox's 0.25 dB steps) for a crosspoint level of 0..100 (fractions allowed). */
export function pctToDb(pct) {
    if (!(pct > 0)) return -Infinity;
    if (pct >= 100) return 0;
    const db = pct < KNEE_PCT ? FLOOR_DB + (pct / KNEE_PCT) * (-FLOOR_DB + KNEE_DB) : 20 * Math.log10(pct / 100);
    const raw = Math.trunc(lround(db * 256) / 64) * 64;
    return Math.max(-15360, Math.min(0, raw)) / 256;
}

export const faderToPct = v => Math.max(0, Math.min(100, (v / UNITY) * 100));  // as MixLaw.faderToLevel
export const faderDb = v => pctToDb(faderToPct(v));
/** The master scales every channel: above unity it lifts channels that are below unity. */
export const masterDb = v => (v <= 0 ? -Infinity : v <= UNITY ? faderDb(v) : 20 * Math.log10(v / UNITY));

// Unquantised taper, used to place controls
function pctToDbExact(pct) {
    if (pct <= 0) return -Infinity;
    if (pct >= 100) return 0;
    return pct < KNEE_PCT ? FLOOR_DB + (pct / KNEE_PCT) * (-FLOOR_DB + KNEE_DB) : 20 * Math.log10(pct / 100);
}

function dbToPct(db) {
    if (!isFinite(db)) return 0;
    if (db >= 0) return 100;
    if (db >= KNEE_DB) return 100 * 10 ** (db / 20);
    return Math.max(0, ((db - FLOOR_DB) / (-FLOOR_DB + KNEE_DB)) * KNEE_PCT);
}

// Fader travel: [position 0..1, dB]
const LAW = [[0.04, -60], [0.15, -40], [0.3, -30], [0.5, -20], [0.75, -10], [1, 0]];

export function posToDb(p) {
    if (p <= 0.005) return -Infinity;
    if (p <= LAW[0][0]) return LAW[0][1];
    for (let i = 1; i < LAW.length; i++) {
        const [p1, d1] = LAW[i], [p0, d0] = LAW[i - 1];
        if (p <= p1) return d0 + ((p - p0) / (p1 - p0)) * (d1 - d0);
    }
    return 0;
}

export function dbToPos(db) {
    if (!isFinite(db)) return 0;
    if (db <= LAW[0][1]) return LAW[0][0];
    for (let i = 1; i < LAW.length; i++) {
        const [p1, d1] = LAW[i], [p0, d0] = LAW[i - 1];
        if (db <= d1) return p0 + ((db - d0) / (d1 - d0)) * (p1 - p0);
    }
    return 1;
}

const round2 = v => Math.round(v * 100) / 100;

/** Channel faders: value 0..85 <-> travel 0..1 */
export const channelLaw = {
    max: UNITY,
    toPos: v => (v <= 0 ? 0 : dbToPos(pctToDbExact((v / UNITY) * 100))),
    toValue: p => round2((dbToPct(posToDb(p)) * UNITY) / 100),
    db: faderDb,
    ticks: [0, -6, -12, -20, -30, -40, -60],
    tickPos: dbToPos,
};

/** Master fader: like a channel up to unity at 90 % of travel, the last 10 % lifts up to +1.4 dB */
const MASTER_KNEE = 0.9;
export const masterLaw = {
    max: 100,
    toPos: v => (v <= UNITY ? channelLaw.toPos(v) * MASTER_KNEE : MASTER_KNEE + ((v - UNITY) / (100 - UNITY)) * (1 - MASTER_KNEE)),
    toValue: p => (p <= MASTER_KNEE ? channelLaw.toValue(p / MASTER_KNEE) : round2(UNITY + ((p - MASTER_KNEE) / (1 - MASTER_KNEE)) * (100 - UNITY))),
    db: masterDb,
    ticks: [0, -6, -12, -20, -30, -40, -60],
    tickPos: db => dbToPos(db) * MASTER_KNEE,
};

/** Steps a fader value by `deltaDb` in the dB domain (arrow keys, scroll wheel). */
export function stepDb(law, v, deltaDb) {
    const db = law.db(v);
    if (!isFinite(db)) return deltaDb > 0 ? law.toValue(dbToPos(-60) + 0.001) : 0;
    const target = db + deltaDb;
    if (target < -60) return 0;
    // Search the travel for the value whose readout is closest to the target (laws are monotonic)
    let lo = 0, hi = 1;
    for (let i = 0; i < 30; i++) {
        const mid = (lo + hi) / 2;
        if (law.db(law.toValue(mid)) < target) lo = mid; else hi = mid;
    }
    const next = law.toValue(deltaDb > 0 ? hi : lo);
    return next === v ? Math.min(law.max, Math.max(0, v + Math.sign(deltaDb))) : next;
}

export function formatDb(db, digits = 1) {
    if (!isFinite(db)) return '−∞';
    const v = Math.abs(db) < 0.05 ? 0 : db;
    return (v > 0 ? '+' : v < 0 ? '−' : '') + Math.abs(v).toFixed(digits);
}

export const panLabel = p => (Math.round(p) === 0 ? 'C' : p < 0 ? `L${Math.round(-p)}` : `R${Math.round(p)}`);
