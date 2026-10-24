// Sanity check for server/estimator.ts on known geometry (run: npx tsx scripts/estimator-check.ts).
// Mirrors the Luotsi prototype's findings: three placed neighbours pin a phone down, one leaves
// only a ring, and uncertainty grows with every Bluetooth hop. Exits non-zero on failure.

import { BluetoothEstimator, RADIO, expectedRssi, hearProb, type Measurement } from '../server/estimator.ts';

type Point = { x: number; z: number };

function rng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = Math.imul(s ^ (s >>> 15), s | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * Runs `seconds` of updates with realistic RSSI noise and returns the last estimate of `target`.
 * With `gpsUntil`, the lost phones are anchors (had GPS) for that many seconds first.
 */
function run(
  anchors: Record<string, Point>,
  lost: Record<string, Point>,
  target: string,
  seed: number,
  seconds = 60,
  gpsUntil = 0,
) {
  const random = rng(seed);
  const gauss = (): number => Math.sqrt(-2 * Math.log(Math.max(random(), 1e-12))) * Math.cos(2 * Math.PI * random());
  const estimator = new BluetoothEstimator({ seed: seed + 1 });
  const all = { ...anchors, ...lost };
  const ids = Object.keys(all);
  let last = null;
  for (let t = 0; t < seconds; t++) {
    const measurements: Measurement[] = [];
    for (let i = 0; i < ids.length; i++) {
      for (let j = i + 1; j < ids.length; j++) {
        const a = all[ids[i]], b = all[ids[j]];
        const d = Math.hypot(a.x - b.x, a.z - b.z);
        if (random() > hearProb(d)) continue;
        measurements.push({ a: ids[i], b: ids[j], rssi: expectedRssi(d) + RADIO.sigma * 0.8 * gauss() });
      }
    }
    const hasGps = t < gpsUntil ? all : anchors;
    const placed = Object.entries(hasGps).map(([id, p]) => ({ id, x: p.x, z: p.z, accuracy: 5 }));
    const unplaced = t < gpsUntil ? [] : Object.keys(lost);
    last = estimator.update(placed, unplaced, measurements).get(target) ?? null;
  }
  if (!last) throw new Error(`no estimate for ${target}`);
  const truth = all[target];
  return { error: Math.hypot(last.x - truth.x, last.z - truth.z), r95: last.r95, hops: last.hops, ambiguous: last.ambiguous };
}

const median = (values: number[]): number => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
const failures: string[] = [];
const report = (name: string, results: ReturnType<typeof run>[]) => {
  const err = median(results.map((r) => r.error));
  const r95 = median(results.map((r) => r.r95));
  const inside = results.filter((r) => r.error <= r.r95).length / results.length;
  console.log(`${name.padEnd(46)} error ${err.toFixed(1).padStart(5)} m   ±${r95.toFixed(0).padStart(3)} m (95%)   truth inside ${(inside * 100).toFixed(0)} %`);
  return { err, r95, inside };
};
const seeds = [1, 2, 3, 4, 5, 6, 7, 8];

const three = report('three anchors around the phone', seeds.map((s) =>
  run({ a: { x: 0, z: 0 }, b: { x: 50, z: 0 }, c: { x: 25, z: 45 } }, { x: { x: 22, z: 15 } }, 'x', s)));
const one = report('one anchor only (cold start ring)', seeds.map((s) =>
  run({ a: { x: 0, z: 0 } }, { x: { x: 35, z: 10 } }, 'x', s)));
const chain = report('chain: anchors → B → X (X two hops out)', seeds.map((s) =>
  run({ a: { x: 0, z: 0 }, b: { x: 0, z: 40 } }, { m: { x: 40, z: 20 }, x: { x: 80, z: 20 } }, 'x', s)));

const lostLater = report('chain, but X and B had GPS for 20 s first', seeds.map((s) =>
  run({ a: { x: 0, z: 0 }, b: { x: 0, z: 40 } }, { m: { x: 40, z: 20 }, x: { x: 80, z: 20 } }, 'x', s, 80, 20)));

if (three.err > 15) failures.push(`three anchors: median error ${three.err.toFixed(1)} m > 15 m`);
if (lostLater.err > 20) failures.push(`GPS then lost: median error ${lostLater.err.toFixed(1)} m > 20 m`);
if (lostLater.inside < 0.7) failures.push('GPS then lost: truth inside claimed area < 70 %');
if (three.inside < 0.7) failures.push('three anchors: truth inside claimed area < 70 %');
if (one.r95 < 2 * three.r95) failures.push('one anchor should stay much less certain than three');
if (chain.r95 <= three.r95) failures.push('a second hop should be less certain than a direct fix');

if (failures.length) {
  console.log(`\nFAILED\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log('\nAll checks passed.');
