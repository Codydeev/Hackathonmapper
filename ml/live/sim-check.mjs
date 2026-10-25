// The GPS-loss simulation of live/map.html, headless: median error over all
// its walks for a few settings.   node ml/live/sim-check.mjs
import { readFileSync } from 'node:fs';
import { createRoutePredictor } from '../runtime/route-model.js';
import { createSimulator, NONE, TICK } from './sim.js';

const ml = new URL('../', import.meta.url);
const read = (p) => JSON.parse(readFileSync(new URL(p, ml)));
const rp = createRoutePredictor(read('export/route-model.json'), read('export/graphs/hervanta-pop-from-fold0.json'));
const walks = read('live/map-data.json').sim;
const sim = createSimulator(rp, walks);

const SETTINGS = {
  'prediction only': NONE,
  'steps': { ...NONE, steps: true },
  'Bluetooth, 12 phones': { ...NONE, ble: true, phones: 12 },
  'steps + Bluetooth, 12 phones': { ...NONE, steps: true, ble: true, phones: 12 },
  'steps + Bluetooth, 40 phones': { ...NONE, steps: true, ble: true, phones: 40 },
  'steps + UWB, 12 phones (GPS)': { ...NONE, steps: true, uwb: true, phones: 12 },
  'steps + UWB, 12 phones (RTK)': { ...NONE, steps: true, uwb: true, phones: 12, acc: 0.03 },
};
const T = [60, 120, 300, 600];
const med = (a) => { const s = [...a].sort((x, y) => x - y); return s[s.length >> 1]; };
console.log(`${walks.length} walks; median error (m) at ${T.map((t) => `${t / 60} min`).join(' / ')}, share under 10 m at 10 min, ms per run`);
for (const [name, o] of Object.entries(SETTINGS)) {
  const t0 = performance.now(), rows = walks.map((_, wi) => sim.simulate(wi, o, 1).map((f) => f.err));
  const ms = (performance.now() - t0) / walks.length;
  const cells = T.map((t) => med(rows.map((r) => r[t / TICK])).toFixed(1).padStart(6));
  const under = rows.filter((r) => r[600 / TICK] < 10).length / rows.length;
  console.log(`${name.padEnd(30)}${cells.join('')}   ${(100 * under).toFixed(0).padStart(3)}%   ${ms.toFixed(0)} ms`);
}
