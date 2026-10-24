// Route model golden cases: what the JS runtime predicts for 16 real Hervanta
// moments with the app's graph. The Swift port is checked against these, and
// re-running this script checks the JS runtime has not drifted.
//   node ml/runtime/test-golden-routes.mjs            # check
//   node ml/runtime/test-golden-routes.mjs --write    # regenerate (needs ml/data/eval from export_routes.py --eval)

import { readFileSync, writeFileSync } from 'node:fs';
import { createRoutePredictor } from './route-model.js';

const ml = new URL('../', import.meta.url);
const read = (p) => JSON.parse(readFileSync(new URL(p, ml)));
const rp = createRoutePredictor(read('export/route-model.json'), read('export/graphs/hervanta.json'));
const TIMES = [120, 300, 600];
const r3 = (v) => Math.round(v * 1000) / 1000;

function run(c) {
  const t0 = performance.now();
  const pred = rp.predictRoutes(c.hist, c.acc);
  const ms = performance.now() - t0;
  return {
    ms,
    out: {
      offPath: r3(pred.offPath), offNow: pred.offNow, bin: pred.bin,
      routes: pred.routes.map((r) => ({ p: r3(r.p), text: r.text, turn: r.turn, n: r.line.length,
        start: r.line[0].map(r3), end: r.line[r.line.length - 1].map(r3), length: r3(r.cum[r.cum.length - 1]) })),
      at: Object.fromEntries(TIMES.map((t) => [t, rp.whereAlong(pred, t).map((a) => ({ point: a.point.map(r3), atEnd: a.atEnd }))])),
    },
  };
}

if (process.argv.includes('--write')) {
  const windows = read('data/eval/hervanta-windows.json');
  const cases = [];
  for (let i = 0; i < windows.length && cases.length < 16; i += Math.floor(windows.length / 16)) {
    const c = { hist: windows[i].hist, acc: cases.length % 3 === 2 ? 15.5 : 4 };
    c.out = run(c).out;
    cases.push(c);
  }
  writeFileSync(new URL('export/golden-routes.json', ml), JSON.stringify(cases));
  console.log(`wrote ${cases.length} route golden cases`);
} else {
  const cases = read('export/golden-routes.json');
  let worst = 0, mismatch = 0, total = 0;
  for (const c of cases) {
    const { out, ms } = run(c);
    total += ms;
    const a = c.out, b = out;
    if (a.routes.length !== b.routes.length || a.offNow !== b.offNow || a.bin !== b.bin) { mismatch++; continue; }
    a.routes.forEach((r, i) => {
      const s = b.routes[i];
      if (r.text !== s.text || r.n !== s.n) mismatch++;
      worst = Math.max(worst, Math.abs(r.p - s.p), Math.abs(r.length - s.length) / 100, ...r.end.map((v, k) => Math.abs(v - s.end[k]) / 100));
    });
    for (const t of TIMES) a.at[t].forEach((m, i) => { worst = Math.max(worst, ...m.point.map((v, k) => Math.abs(v - b.at[t][i].point[k]) / 100)); });
  }
  console.log(`${cases.length} route golden cases: ${mismatch} mismatched routes or labels, worst difference ${worst.toFixed(4)}, ${(total / cases.length).toFixed(1)} ms each`);
  if (mismatch || worst > 0.01) process.exit(1);
}
