// Scores the route model on held-out Hervanta walks with the same JS the
// phone and the demo run.
//   python ml/export_routes.py --eval && node ml/runtime/eval-routes.mjs
//
// For every moment (60 s of history, then 10 min of what really happened):
// is the person within 20 m of the top route / any shown route after 2, 5 and
// 10 min, the log of the probability given to the route they were on, and how
// far the "probably here" marker was from them. The turn model is swapped
// (uniform / straightest / map / map + where people walk) while everything
// else stays the same. Intervals come from resampling outing days.

import { readFileSync, writeFileSync } from 'node:fs';
import { createRoutePredictor } from './route-model.js';

const ml = new URL('../', import.meta.url);
const read = (p) => JSON.parse(readFileSync(new URL(p, ml)));
const model = read('export/route-model.json');
const windows = read('data/eval/hervanta-windows.json');
const TIMES = [120, 300, 600], HIT_M = 20, OFF_M = 25;
const graphs = Object.fromEntries(['uniform', 'straightest', 'map', 'pop-from-fold0', 'pop-from-fold1']
  .map((n) => [n, createRoutePredictor(model, read(`data/eval/hervanta-${n}.json`))]));
const VARIANTS = {
  uniform: { name: 'Guess at every fork', pick: () => graphs.uniform },
  straightest: { name: 'Straightest way', pick: () => graphs.straightest },
  map: { name: 'Map model', pick: () => graphs.map },
  pop: { name: 'Map + where people walk', pick: (w) => graphs[`pop-from-fold${1 - w.fold}`] },
};

function mulberry32(a) {
  return () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
}
function meshHistory(hist, seed) {
  const r = mulberry32(seed), g = () => Math.sqrt(-2 * Math.log(1 - r())) * Math.cos(2 * Math.PI * r());
  let e = [g(), g()];
  return hist.map((p, i) => {
    if (i) e = [0.9 * e[0] + Math.sqrt(0.19) * g(), 0.9 * e[1] + Math.sqrt(0.19) * g()];
    return [p[0] + 15 * e[0], p[1] + 15 * e[1]];
  });
}
function distToLine(r, p) {
  let best = Infinity;
  for (let i = 1; i < r.line.length; i++) {
    const a = r.line[i - 1], b = r.line[i], vx = b[0] - a[0], vy = b[1] - a[1], L2 = vx * vx + vy * vy || 1e-9;
    const f = Math.max(0, Math.min(1, ((p[0] - a[0]) * vx + (p[1] - a[1]) * vy) / L2));
    best = Math.min(best, Math.hypot(a[0] + f * vx - p[0], a[1] + f * vy - p[1]));
  }
  return best;
}
const median = (a) => { const s = [...a].sort((x, y) => x - y); return s.length ? s[s.length >> 1] : NaN; };
const mean = (a) => a.reduce((x, y) => x + y, 0) / a.length;
function dayInterval(vals, days, stat, n = 2000) {
  const uniq = [...new Set(days)], by = new Map(uniq.map((d) => [d, vals.filter((_, i) => days[i] === d)]));
  const r = mulberry32(7), out = [];
  for (let k = 0; k < n; k++) {
    const sample = [];
    for (let j = 0; j < uniq.length; j++) sample.push(...by.get(uniq[Math.floor(r() * uniq.length)]));
    out.push(stat(sample));
  }
  out.sort((a, b) => a - b);
  return [out[Math.floor(0.05 * n)], out[Math.floor(0.95 * n)]];
}

const results = {};
const days = windows.map((w) => w.day);
let onPath = 0;
for (const quality of ['gps', 'mesh']) {
  results[quality] = {};
  for (const [key, v] of Object.entries(VARIANTS)) {
    const per = Object.fromEntries(TIMES.map((t) => [t, { top: [], any: [], logp: [], markTop: [], markBest: [] }]));
    windows.forEach((w, wi) => {
      const hist = quality === 'gps' ? w.hist : meshHistory(w.hist, wi);
      const acc = quality === 'gps' ? 4 : Math.hypot(15, 4);
      const rp = v.pick(w);
      const pred = rp.predictRoutes(hist, acc);
      if (quality === 'gps' && key === 'uniform' && !pred.offNow) onPath++;
      for (const t of TIMES) {
        const truth = w.fut[t], at = rp.whereAlong(pred, t), s = per[t];
        const d = pred.routes.map((r) => distToLine(r, truth));
        const top = pred.routes.length ? d[0] <= HIT_M : false;
        const any = d.some((x) => x <= HIT_M);
        s.top.push(+top); s.any.push(+any);
        let p = 0;
        if (any) { const i = d.indexOf(Math.min(...d)); p = pred.routes[i].p; }
        else if (rp.near(truth, OFF_M).size === 0) p = pred.offPath;
        s.logp.push(Math.log(Math.max(p, 0.01)));
        const errs = at.map((a) => Math.hypot(a.point[0] - truth[0], a.point[1] - truth[1]));
        s.markTop.push(errs.length ? errs[0] : NaN); s.markBest.push(errs.length ? Math.min(...errs) : NaN);
      }
    });
    results[quality][key] = Object.fromEntries(TIMES.map((t) => {
      const s = per[t];
      return [t, {
        top: mean(s.top), top90: dayInterval(s.top, days, mean), any: mean(s.any), any90: dayInterval(s.any, days, mean),
        logscore: mean(s.logp), markerTop: median(s.markTop.filter(isFinite)), markerBest: median(s.markBest.filter(isFinite)),
      }];
    }));
  }
  // Baselines without routes: stand still, keep the same velocity.
  for (const [key, f] of Object.entries({
    still: (h) => () => h.at(-1),
    velocity: (h) => (t) => { const a = h[0], b = h.at(-1); return [b[0] + ((b[0] - a[0]) / 60) * t, b[1] + ((b[1] - a[1]) / 60) * t]; },
  })) {
    results[quality][key] = Object.fromEntries(TIMES.map((t) => {
      const errs = windows.map((w, wi) => { const p = f(quality === 'gps' ? w.hist : meshHistory(w.hist, wi))(t); return Math.hypot(p[0] - w.fut[t][0], p[1] - w.fut[t][1]); });
      return [t, { marker: median(errs) }];
    }));
  }
}

const pct = (x) => `${Math.round(100 * x)}%`;
const g = results.gps, m = results.mesh;
const table = {
  header: ['Which way at forks', 'Top route right, 2 min', '5 min', '10 min', 'One of the shown routes, 10 min', 'Marker off by, 5 min'],
  rows: [
    ...Object.entries(VARIANTS).map(([k, v]) => [v.name, pct(g[k][120].top), pct(g[k][300].top), pct(g[k][600].top), pct(g[k][600].any), `${Math.round(g[k][300].markerBest)} m`]),
    ['Keeps the same velocity (no routes)', '–', '–', '–', '–', `${Math.round(g.velocity[300].marker)} m`],
    ['Stands still (no routes)', '–', '–', '–', '–', `${Math.round(g.still[300].marker)} m`],
  ],
};
const P = g.pop;
const summary = `On ${windows.length} moments from ${new Set(days).size} days of held-out walks in Hervanta, the top route held where the person really was ` +
  `${pct(P[300].top)} of the time after 5 minutes and ${pct(P[600].top)} after 10 minutes; one of the shown routes did ${pct(P[600].any)} of the time after 10 minutes ` +
  `(guessing at every fork: ${pct(g.uniform[600].top)} and ${pct(g.uniform[600].any)}). ${pct(onPath / windows.length)} of the moments started on a mapped path.`;
const note = `"Right" means within ${HIT_M} m of the route line. Marker: distance from the closest route's "probably here by now" marker. ` +
  `With a ±15 m Bluetooth-mesh history the model's top route was right ${pct(m.pop[300].top)} / ${pct(m.pop[600].top)} of the time after 5 / 10 min. ` +
  `90% intervals from resampling days, top route after 10 min: ${pct(P[600].top90[0])}–${pct(P[600].top90[1])}. Only 17 walks were long enough, so treat the numbers as rough.`;
const ch = read('results/choice-metrics.json');
const forkText = `A probability for each branch, from how sharp the turn is, whether the same path continues, path type, dead ends, marked hiking routes and how many other people walked each branch. ` +
  `On ${ch.n_test} real forks in Hervanta it put the most weight on the branch people really took ${pct(ch.models['map + where people walk'].top1)} of the time (guessing: ${pct(ch.models.uniform.top1)}, straightest: ${pct(ch.models.straightest.top1)}).`;
const out = { results, onPathShare: onPath / windows.length, n: windows.length, days: new Set(days).size, table, summary, note, forkText };
writeFileSync(new URL('results/metrics-routes.json', ml), JSON.stringify(out, null, 1));
console.log(summary);
for (const q of ['gps', 'mesh']) {
  console.log(`\n${q === 'gps' ? 'Clean GPS history' : 'Bluetooth mesh ±15 m history'}`);
  for (const [k, v] of Object.entries(VARIANTS)) {
    const r = results[q][k];
    console.log(`  ${v.name.padEnd(26)} top ${TIMES.map((t) => pct(r[t].top)).join(' / ')}   any ${TIMES.map((t) => pct(r[t].any)).join(' / ')}   log ${TIMES.map((t) => r[t].logscore.toFixed(2)).join(' / ')}   marker ${TIMES.map((t) => Math.round(r[t].markerBest)).join(' / ')} m`);
  }
  console.log(`  ${'same velocity'.padEnd(26)} marker ${TIMES.map((t) => Math.round(results[q].velocity[t].marker)).join(' / ')} m;  stand still ${TIMES.map((t) => Math.round(results[q].still[t].marker)).join(' / ')} m`);
}
