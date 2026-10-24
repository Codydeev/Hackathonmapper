// Scores the route filter on held-out Hervanta walks with simulated signals.
//   python ml/export_routes.py --eval && node ml/runtime/eval-fusion.mjs [stride]
//
// Signals are simulated from where the person really walked:
//   Bluetooth  a searcher's phone 15-45 m from the person hears the lost phone:
//              RSSI from MeshCore's outdoor path-loss model with 5 dB noise, the
//              searcher's own position known to +-4 m
//   steps      the lost phone's pedometer and compass, with a per-walk step-length
//              error (+-6%), compass bias (+-7 deg) that drifts, and noise;
//              standing still reads as no steps. Fed to the filter every 10 s.
// Scenarios: no signals, one reading at t, three readings (t-20, t-10, t),
// steps all along, steps + one reading at t. Error = distance from the
// filter's best position to where the person really was at t.

import { readFileSync, writeFileSync } from 'node:fs';
import { createRoutePredictor } from './route-model.js';
import { createRouteFilter } from './route-filter.js';

const ml = new URL('../', import.meta.url);
const read = (p) => JSON.parse(readFileSync(new URL(p, ml)));
const model = read('export/route-model.json');
const windows = read('data/eval/hervanta-windows.json');
const stride = Number(process.argv[2] || 1);
const TIMES = [120, 300, 600], N = Number(process.env.PARTICLES || 300);
const preds = [0, 1].map((k) => createRoutePredictor(model, read(`data/eval/hervanta-pop-from-fold${k}.json`)));

function mulberry32(a) {
  return () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
}
const gauss = (r) => Math.sqrt(-2 * Math.log(1 - r())) * Math.cos(2 * Math.PI * r());

function bluetooth(path, tau, r, radio) {
  const truth = path[tau], d0 = 15 + 30 * r(), phi = 2 * Math.PI * r();
  const at = [truth[0] + d0 * Math.cos(phi), truth[1] + d0 * Math.sin(phi)];
  return { listener: [at[0] + 4 * gauss(r), at[1] + 4 * gauss(r)], listenerAcc: 4, rssi: radio.p0 - 10 * radio.n * Math.log10(d0) + radio.sigma * gauss(r) };
}

function pedometer(path, r) {
  const H = process.env.HARSH ? { scale: 0.10, bias: 15, drift: 0.5 } : { scale: 0.06, bias: 7, drift: 0.2 };   // HARSH=1: a worse phone
  const scale = 1 + H.scale * gauss(r);
  let heading = (H.bias * Math.PI / 180) * gauss(r);
  const steps = [];
  for (let k = 1; k < path.length; k++) {
    heading += (H.drift * Math.PI / 180) * gauss(r);
    const tx = path[k][0] - path[k - 1][0], ty = path[k][1] - path[k - 1][1];
    if (Math.hypot(tx, ty) < 0.25) { steps.push([0, 0]); continue; }
    const c = Math.cos(heading), s = Math.sin(heading);
    steps.push([scale * (c * tx - s * ty) + 0.1 * gauss(r), scale * (s * tx + c * ty) + 0.1 * gauss(r)]);
  }
  return steps;   // steps[k-1]: displacement from second k-1 to k
}

// Run one scenario up to time t and return the filter's estimate.
function run(f, w, wi, t, scenario) {
  const r = mulberry32(wi * 7919 + t * 13 + scenario.length);
  const s = f.start(w.hist, 4);
  const steps = scenario.includes('steps') ? pedometer(w.path, mulberry32(wi * 31 + 1)) : null;
  const pings = { 'one reading': [t], 'three readings': [t - 20, t - 10, t], 'steps + one reading': [t],
    'heard for 1 min': Array.from({ length: 12 }, (_, k) => t - 55 + 5 * k) }[scenario] || [];
  let clock = 0;
  const events = new Set([...pings, ...(steps ? Array.from({ length: Math.floor(t / 10) }, (_, k) => (k + 1) * 10) : [])]);
  for (const e of [...events].sort((a, b) => a - b)) {
    f.advance(s, e);
    if (steps && e % 10 === 0 && e > clock) {
      let dx = 0, dy = 0;
      for (let k = clock; k < e; k++) { dx += steps[k][0]; dy += steps[k][1]; }
      f.observeSteps(s, { dx, dy, seconds: e - clock });
      clock = e;
    }
    if (pings.includes(e)) f.observeBluetooth(s, bluetooth(w.path, e, r, f.radio));
  }
  f.advance(s, t);
  return f.estimate(s);
}

const SCENARIOS = ['no signals', 'one reading', 'three readings', 'heard for 1 min', 'steps', 'steps + one reading'];
const errs = Object.fromEntries(SCENARIOS.map((sc) => [sc, Object.fromEntries(TIMES.map((t) => [t, { e: [], covered: [] }]))]));
const t0 = performance.now();
let done = 0;
for (let wi = 0; wi < windows.length; wi += stride) {
  const w = windows[wi], rp = preds[1 - w.fold];
  for (const sc of SCENARIOS) {
    for (const t of TIMES) {
      const f = createRouteFilter(rp, { particles: N, random: mulberry32(wi * 104729 + t + SCENARIOS.indexOf(sc) * 7) });
      const est = run(f, w, wi, t, sc), truth = w.path[t];
      const e = Math.hypot(est.center[0] - truth[0], est.center[1] - truth[1]);
      errs[sc][t].e.push(e); errs[sc][t].covered.push(e <= est.r95);
    }
  }
  done++;
}
const q = (a, p) => { const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor(p * s.length))]; };
const out = {};
console.log(`${done} held-out Hervanta moments, ${N} particles, ${((performance.now() - t0) / 1000).toFixed(0)} s`);
console.log('scenario                   ' + TIMES.map((t) => `${t / 60} min: median / 90% / under 10 m / r95 holds`.padEnd(46)).join(''));
for (const sc of SCENARIOS) {
  out[sc] = {};
  const cells = TIMES.map((t) => {
    const a = errs[sc][t].e, c = errs[sc][t].covered;
    const row = { median: q(a, 0.5), p90: q(a, 0.9), under10: a.filter((x) => x < 10).length / a.length, r95holds: c.filter(Boolean).length / c.length };
    out[sc][t] = row;
    return `${row.median.toFixed(1).padStart(6)} m ${row.p90.toFixed(0).padStart(5)} m ${(100 * row.under10).toFixed(0).padStart(5)}% ${(100 * row.r95holds).toFixed(0).padStart(5)}%`.padEnd(46);
  });
  console.log(sc.padEnd(27) + cells.join(''));
}
writeFileSync(new URL('results/metrics-fusion.json', ml), JSON.stringify({ n: done, particles: N, results: out }, null, 1));
