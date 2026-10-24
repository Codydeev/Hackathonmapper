// Checks the JS runtime against predictions made by the trained PyTorch model.
//   node ml/runtime/test-golden.mjs

import { readFileSync } from 'node:fs';
import { createMovementModel, historyFromTrack } from './movement-model.js';

const dir = new URL('../export/', import.meta.url);
const model = createMovementModel(JSON.parse(readFileSync(new URL('movement-model.json', dir))));
const cases = JSON.parse(readFileSync(new URL('golden.json', dir)));

let worst = 0;
for (const c of cases) {
  const p = model.predict(c.hist, c.acc, c.h);
  c.weights.forEach((w, k) => {
    worst = Math.max(worst, Math.abs(p.weights[k] - w) / 1e-3,
      ...p.means[k].map((v, i) => Math.abs(v - c.means[k][i]) / (1e-2 + 1e-4 * Math.abs(c.means[k][i]))),
      ...p.covs[k].map((v, i) => Math.abs(v - c.covs[k][i]) / (1e-2 + 1e-3 * Math.abs(c.covs[k][i]))));
  });
}
console.log(`${cases.length} golden cases, worst error ${worst.toFixed(3)} of tolerance`);
if (worst > 1) process.exit(1);

// historyFromTrack: a walker heading east at 1 m/s, reported every 1.3 s.
const track = Array.from({ length: 60 }, (_, i) => ({ t: 100 + 1.3 * i, x: 1.3 * i, y: 0 }));
const now = track.at(-1).t;
const hist = historyFromTrack(track, now, model.spec);
const ok = hist.length === 31 && Math.abs(hist[30][0] - track.at(-1).x) < 1e-9 && Math.abs(hist[0][0] - (track.at(-1).x - 60)) < 1e-9;
console.log(`historyFromTrack ${ok ? 'ok' : 'WRONG'}`);
// Density should integrate to ~1 over a grid, and samples should sit where the density is.
const pred = model.predict(hist, 5, 60);
let mass = 0;
for (let x = -100; x <= 300; x += 2) for (let y = -200; y <= 200; y += 2) mass += model.density(pred, x, y) * 4;
const dots = model.sample(pred, 4000);
const mx = dots.reduce((a, d) => a + d[0], 0) / dots.length;
const ex = pred.weights.reduce((a, w, k) => a + w * pred.means[k][0], 0);
console.log(`density mass ${mass.toFixed(3)}, sample mean x ${mx.toFixed(1)} vs ${ex.toFixed(1)} m (walker at ${hist[30][0].toFixed(1)} m heading east)`);
if (!ok || Math.abs(mass - 1) > 0.02 || Math.abs(mx - ex) > 4) process.exit(1);
