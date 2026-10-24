// Route filter golden cases: the JS filter replayed on real Hervanta moments
// with recorded signals (pedometer every 10 s and/or a searcher's phone
// hearing the lost phone for the last minute), seeded so other runtimes can
// replay them exactly. RouteFilter.swift is checked against these.
//   node ml/runtime/test-golden-filter.mjs            # check
//   node ml/runtime/test-golden-filter.mjs --write    # regenerate (needs ml/data/eval)

import { readFileSync, writeFileSync } from 'node:fs';
import { createRoutePredictor } from './route-model.js';
import { createRouteFilter } from './route-filter.js';

const ml = new URL('../', import.meta.url);
const read = (p) => JSON.parse(readFileSync(new URL(p, ml)));
const rp = createRoutePredictor(read('export/route-model.json'), read('export/graphs/hervanta.json'));
const T = 300, PARTICLES = 300;

function mulberry32(a) {
  return () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
}
const gauss = (r) => Math.sqrt(-2 * Math.log(1 - r())) * Math.cos(2 * Math.PI * r());

function replay(c) {
  const f = createRouteFilter(rp, { particles: c.particles, random: mulberry32(c.seed) });
  const s = f.start(c.hist, c.acc);
  for (const e of c.events) {
    f.advance(s, e.t);
    if (e.kind === 'steps') f.observeSteps(s, { dx: e.dx, dy: e.dy, seconds: e.seconds });
    else f.observeBluetooth(s, { listener: e.listener, listenerAcc: e.listenerAcc, rssi: e.rssi });
  }
  f.advance(s, c.T);
  const est = f.estimate(s);
  return { center: est.center, r95: est.r95, share: est.share };
}

if (process.argv.includes('--write')) {
  const windows = read('data/eval/hervanta-windows.json');
  const cases = [];
  const kinds = ['steps', 'ble', 'both'];
  for (let k = 0; k < 9; k++) {
    const w = windows[Math.floor((k + 0.5) * windows.length / 9)], kind = kinds[k % 3], r = mulberry32(17 + k);
    const events = [];
    if (kind !== 'ble') {
      // Pedometer with a step-length error and a drifting compass bias, summed every 10 s.
      const scale = 1 + 0.06 * gauss(r);
      let heading = (7 * Math.PI / 180) * gauss(r), dx = 0, dy = 0;
      for (let sec = 1; sec <= T; sec++) {
        heading += (0.2 * Math.PI / 180) * gauss(r);
        const tx = w.path[sec][0] - w.path[sec - 1][0], ty = w.path[sec][1] - w.path[sec - 1][1];
        if (Math.hypot(tx, ty) >= 0.25) {
          const c = Math.cos(heading), s = Math.sin(heading);
          dx += scale * (c * tx - s * ty) + 0.1 * gauss(r); dy += scale * (s * tx + c * ty) + 0.1 * gauss(r);
        }
        if (sec % 10 === 0) { events.push({ t: sec, kind: 'steps', dx, dy, seconds: 10 }); dx = 0; dy = 0; }
      }
    }
    if (kind !== 'steps') {
      for (let tau = T - 55; tau <= T; tau += 5) {
        const truth = w.path[tau], d0 = 20 + 20 * r(), a = 2 * Math.PI * r();
        const at = [truth[0] + d0 * Math.cos(a), truth[1] + d0 * Math.sin(a)];
        events.push({ t: tau, kind: 'ble', listener: [at[0] + 4 * gauss(r), at[1] + 4 * gauss(r)], listenerAcc: 4, rssi: -59 - 25 * Math.log10(d0) + 5 * gauss(r) });
      }
    }
    events.sort((a, b) => a.t - b.t || (a.kind === 'steps' ? -1 : 1));
    const c = { kind, hist: w.hist, acc: 4, seed: 1000 + k, particles: PARTICLES, T, events, truth: w.path[T] };
    c.out = replay(c);
    cases.push(c);
  }
  writeFileSync(new URL('export/golden-filter.json', ml), JSON.stringify(cases));
  console.log(`wrote ${cases.length} filter golden cases: ` + cases.map((c) => `${c.kind} ${Math.hypot(c.out.center[0] - c.truth[0], c.out.center[1] - c.truth[1]).toFixed(1)} m`).join(', '));
} else {
  const cases = read('export/golden-filter.json');
  let worst = 0;
  for (const c of cases) {
    const o = replay(c);
    worst = Math.max(worst, Math.hypot(o.center[0] - c.out.center[0], o.center[1] - c.out.center[1]), Math.abs(o.r95 - c.out.r95));
  }
  console.log(`${cases.length} filter golden cases: worst difference ${worst.toFixed(4)} m`);
  if (worst > 1e-6) process.exit(1);
}
