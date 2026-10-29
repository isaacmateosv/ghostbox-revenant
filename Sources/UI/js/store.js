// The panel's copy of the engine state (shape: PanelState.makeDefault in Sources/App/Model/PanelState.swift).

export const store = {
    S: null,       // the state tree
    rev: 0,        // engine revision of S
    info: {},      // runtime facts: app/driver versions, latency support, S/PDIF lock
    dragging: 0,   // controls being dragged (responses wait so they never fight the pointer)
};

export const mix = () => store.S.mixes[store.S.active_mix];
export const otherBus = () => (store.S.active_mix === 'analog' ? 'spdif' : 'analog');
export const busName = bus => (bus === 'analog' ? 'Analog 1/2' : 'S/PDIF L/R');
export const sibling = idx => (idx % 2 === 0 ? idx + 1 : idx - 1);
export const isLinked = (kind, idx) => !!mix().links[kind + (idx < 2 ? '12' : '34')];

export function anySolo() {
    const S = store.S;
    if (!S) return false;
    return Object.values(S.mixes).some(m =>
        [...m.hw, ...m.sw].some(c => c.solo) || m.fx_ret.solo_l || m.fx_ret.solo_r);
}
