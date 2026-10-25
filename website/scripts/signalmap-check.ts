// Checks shared/signalmap.ts on known geometry (run: npx tsx scripts/signalmap-check.ts).
// With --write-golden it also writes the cases MeshCore's SignalMapTests replay, so the Swift port
// and this one stay identical.
import { writeFileSync } from 'node:fs';
import { RADIO_MODEL, type RadioModel } from '../shared/contract.ts';
import {
  calibrateRadio,
  solveSignalMap,
  type SignalLink,
  type SignalMapInput,
  type SignalPrior,
} from '../shared/signalmap.ts';

type Point = { x: number; z: number };

let seed = 7;
const random = (): number => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
};
const gauss = (): number => Math.sqrt(-2 * Math.log(random() + 1e-12)) * Math.cos(2 * Math.PI * random());
const rssiAt = (radio: RadioModel, d: number, noise = 0): number => radio.p0 - 10 * radio.n * Math.log10(Math.max(d, 0.3)) + noise;
const dist = (p: Point, q: Point): number => Math.hypot(p.x - q.x, p.z - q.z);

function linksFor(truth: Record<string, Point>, pairs: Array<[string, string]>, noiseDb = 0): SignalLink[] {
  return pairs.map(([a, b]) => ({ a, b, rssi: Math.round(rssiAt(RADIO_MODEL, dist(truth[a], truth[b]), noiseDb * gauss()) * 10) / 10 }));
}

let failures = 0;
function check(name: string, ok: boolean, detail: string): void {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}: ${detail}`);
  if (!ok) failures += 1;
}

const cases: Array<{ name: string; input: SignalMapInput }> = [];
function run(name: string, input: SignalMapInput) {
  cases.push({ name, input });
  return solveSignalMap(input);
}

// 1. Three phones, no positions: the layout reproduces the measured triangle exactly.
{
  const truth = { a: { x: 0, z: 0 }, b: { x: 3, z: 0 }, c: { x: 0, z: 4 } };
  const result = run('triangle-relative', {
    ids: ['a', 'b', 'c'],
    links: linksFor(truth, [['a', 'b'], ['a', 'c'], ['b', 'c']]),
    priors: [],
    radio: RADIO_MODEL,
  });
  const worst = Math.max(...result.links.map((l) => Math.abs(l.layout - l.measured)));
  check('triangle', worst < 0.01 && result.nodes.every((n) => n.frame === 'relative'), `max |layout - measured| ${worst.toFixed(4)} m`);
}

// 2. Five phones in a room, noisy RSSI, no positions: map distances vs true distances.
{
  const truth: Record<string, Point> = { a: { x: 0, z: 0 }, b: { x: 4, z: 1 }, c: { x: 2, z: 5 }, d: { x: 6, z: 6 }, e: { x: -2, z: 4 } };
  const ids = Object.keys(truth);
  const pairs: Array<[string, string]> = [];
  for (let i = 0; i < ids.length; i += 1) for (let j = i + 1; j < ids.length; j += 1) pairs.push([ids[i], ids[j]]);
  seed = 11;
  const links = linksFor(truth, pairs, 3);
  const result = run('room-noisy-relative', { ids, links, priors: [], radio: RADIO_MODEL });
  const pos = new Map(result.nodes.map((n) => [n.id, n]));
  const errors = pairs.map(([a, b]) => Math.abs(dist(pos.get(a)!, pos.get(b)!) - dist(truth[a], truth[b])));
  const fit = result.links.map((l) => Math.abs(l.layout - l.measured));
  check('room relative', errors.reduce((s, e) => s + e, 0) / errors.length < 1.5,
    `mean pair-distance error ${(errors.reduce((s, e) => s + e, 0) / errors.length).toFixed(2)} m, mean |layout-measured| ${(fit.reduce((s, e) => s + e, 0) / fit.length).toFixed(2)} m`);
}

// 3. One GPS phone (±15 m) and a phone 2 m from it: pinned, a ring of 2 m around the GPS phone.
{
  const truth = { gps: { x: 100, z: 50 }, lost: { x: 102, z: 50 } };
  const result = run('one-anchor-ring', {
    ids: ['gps', 'lost'],
    links: linksFor(truth, [['gps', 'lost']]),
    priors: [{ id: 'gps', x: 100, z: 50, r95: 15 }],
    radio: RADIO_MODEL,
  });
  const lost = result.nodes.find((n) => n.id === 'lost')!;
  check('ring', lost.ringCenter === 'gps' && Math.abs(lost.ringRadius! - 2) < 0.05 && lost.hops === 1,
    `ring around ${lost.ringCenter}, radius ${lost.ringRadius?.toFixed(2)} m, frame ${lost.frame}`);
}

// 4. Two manual anchors 10 m apart, two lost phones: world frame, positions near the truth.
{
  const truth: Record<string, Point> = { a1: { x: 0, z: 0 }, a2: { x: 10, z: 0 }, p: { x: 4, z: 3 }, q: { x: 7, z: 5 } };
  seed = 5;
  const result = run('two-anchors-world', {
    ids: Object.keys(truth),
    links: linksFor(truth, [['a1', 'p'], ['a2', 'p'], ['p', 'q'], ['a2', 'q'], ['a1', 'q']], 2),
    priors: [
      { id: 'a1', x: 0, z: 0, r95: 0.5 },
      { id: 'a2', x: 10, z: 0, r95: 0.5 },
    ],
    radio: RADIO_MODEL,
  });
  const p = result.nodes.find((n) => n.id === 'p')!;
  const q = result.nodes.find((n) => n.id === 'q')!;
  // Two anchors leave a mirror ambiguity across their line; compare with the closer image.
  const err = (n: Point, t: Point) => Math.min(dist(n, t), dist(n, { x: t.x, z: -t.z }));
  check('world', p.frame === 'world' && err(p, truth.p) < 2 && err(q, truth.q) < 2.5,
    `p off ${err(p, truth.p).toFixed(2)} m (r95 ${p.r95.toFixed(1)}), q off ${err(q, truth.q).toFixed(2)} m (r95 ${q.r95.toFixed(1)})`);
}

// 5. GPS phones placed 12 m wrong, linked to a precise anchor: the map keeps the radio's distances.
{
  const truth: Record<string, Point> = { anchor: { x: 0, z: 0 }, g1: { x: 2, z: 0 }, g2: { x: 0, z: 3 }, g3: { x: 25, z: 25 } };
  const result = run('gps-pulled-to-ranges', {
    ids: Object.keys(truth),
    links: linksFor(truth, [['anchor', 'g1'], ['anchor', 'g2'], ['g1', 'g2']]),
    priors: [
      { id: 'anchor', x: 0, z: 0, r95: 0.5 },
      { id: 'g1', x: 12, z: 6, r95: 20 },
      { id: 'g2', x: -9, z: 10, r95: 20 },
      { id: 'g3', x: 25, z: 25, r95: 8 },
    ],
    radio: RADIO_MODEL,
  });
  const pos = new Map(result.nodes.map((n) => [n.id, n]));
  const before = Math.abs(dist({ x: 12, z: 6 }, { x: 0, z: 0 }) - 2);
  const after = Math.abs(dist(pos.get('g1')!, pos.get('anchor')!) - 2);
  check('cooperative', after < 0.3 && dist(pos.get('g3')!, truth.g3) < 1e-6,
    `anchor–g1 distance error ${before.toFixed(1)} m from GPS alone, ${after.toFixed(2)} m on the map; unlinked g3 unchanged`);
}

// 6. Stability: a second solve warm-started from the first barely moves.
{
  const truth: Record<string, Point> = { a: { x: 0, z: 0 }, b: { x: 4, z: 1 }, c: { x: 2, z: 5 }, d: { x: 6, z: 6 } };
  seed = 3;
  const input: SignalMapInput = {
    ids: Object.keys(truth),
    links: linksFor(truth, [['a', 'b'], ['a', 'c'], ['b', 'c'], ['b', 'd'], ['c', 'd']], 2),
    priors: [],
    radio: RADIO_MODEL,
  };
  const first = solveSignalMap(input);
  const second = solveSignalMap({ ...input, previous: new Map(first.nodes.map((n) => [n.id, { x: n.x, z: n.z }])) });
  const moved = Math.max(...first.nodes.map((n, i) => dist(n, second.nodes[i])));
  check('stable', moved < 0.01, `largest move between seconds ${moved.toFixed(5)} m`);
  cases.push({ name: 'warm-start', input: { ...input, previous: new Map(first.nodes.map((n) => [n.id, { x: n.x + 0.5, z: n.z }])) } });
}

// 7. Calibration from links between precisely placed phones recovers the room's radio.
{
  const room: RadioModel = { ...RADIO_MODEL, p0: -63, n: 2.2 };
  const anchors: Record<string, Point> = { a: { x: 0, z: 0 }, b: { x: 2, z: 0 }, c: { x: 9, z: 1 }, d: { x: 1, z: 7 }, e: { x: 8, z: 8 } };
  const ids = Object.keys(anchors);
  const links: SignalLink[] = [];
  for (let i = 0; i < ids.length; i += 1) {
    for (let j = i + 1; j < ids.length; j += 1) links.push({ a: ids[i], b: ids[j], rssi: rssiAt(room, dist(anchors[ids[i]], anchors[ids[j]])) });
  }
  const priors = new Map<string, SignalPrior>(ids.map((id) => [id, { id, ...anchors[id], r95: 0.5 }]));
  const fitted = calibrateRadio(RADIO_MODEL, links, priors);
  // Few links at 5 dB spread can't separate p0 from n, but the ranges they give must improve.
  const rangeError = (radio: RadioModel): number => {
    const probes = [1, 2, 4, 8, 12];
    return probes.reduce((sum, d) => sum + Math.abs(Math.pow(10, (radio.p0 - rssiAt(room, d)) / (10 * radio.n)) - d) / d, 0) / probes.length;
  };
  check('calibration', rangeError(fitted) < rangeError(RADIO_MODEL) / 2,
    `p0 ${fitted.p0.toFixed(2)} (true ${room.p0}), n ${fitted.n.toFixed(3)} (true ${room.n}); mean range error ${(100 * rangeError(RADIO_MODEL)).toFixed(0)} % → ${(100 * rangeError(fitted)).toFixed(0)} %`);
  cases.push({ name: 'calibrated', input: { ids, links, priors: [...priors.values()], radio: RADIO_MODEL, calibrate: true } });
}

// 8. Disconnected phone with no position: unplaced. Two groups numbered by smallest id.
{
  const result = run('unplaced-and-groups', {
    ids: ['z-alone', 'b', 'a', 'c', 'd'],
    links: [{ a: 'a', b: 'b', rssi: -65 }, { a: 'c', b: 'd', rssi: -70 }],
    priors: [],
    radio: RADIO_MODEL,
  });
  const alone = result.nodes.find((n) => n.id === 'z-alone')!;
  check('groups', !alone.placed && result.nodes.find((n) => n.id === 'c')!.component === 1,
    `alone placed=${alone.placed}, components ${result.nodes.map((n) => `${n.id}:${n.component}`).join(' ')}`);
}

// UWB distances (Nearby Interaction, ~0.1 m spread) on some links, rounded to 0.01 m as the phones send them.
function withUwb(links: SignalLink[], truth: Record<string, Point>, measured: Array<[string, string]>, noise = 0.1): SignalLink[] {
  const has = new Set(measured.map(([a, b]) => `${a}\n${b}`));
  return links.map((link) =>
    has.has(`${link.a}\n${link.b}`)
      ? { ...link, uwb: Math.round(Math.max(0, dist(truth[link.a], truth[link.b]) + noise * gauss()) * 100) / 100 }
      : link,
  );
}

// 9. The noisy room from case 2, now with UWB on every link: map distances follow UWB, not RSSI.
{
  const truth: Record<string, Point> = { a: { x: 0, z: 0 }, b: { x: 4, z: 1 }, c: { x: 2, z: 5 }, d: { x: 6, z: 6 }, e: { x: -2, z: 4 } };
  const ids = Object.keys(truth);
  const pairs: Array<[string, string]> = [];
  for (let i = 0; i < ids.length; i += 1) for (let j = i + 1; j < ids.length; j += 1) pairs.push([ids[i], ids[j]]);
  seed = 11;
  const rssiOnly = linksFor(truth, pairs, 3);
  seed = 13;
  const links = withUwb(rssiOnly, truth, pairs);
  const result = run('room-uwb-relative', { ids, links, priors: [], radio: RADIO_MODEL });
  const pos = new Map(result.nodes.map((n) => [n.id, n]));
  const errors = pairs.map(([a, b]) => Math.abs(dist(pos.get(a)!, pos.get(b)!) - dist(truth[a], truth[b])));
  const mean = errors.reduce((s, e) => s + e, 0) / errors.length;
  check('uwb room', mean < 0.2 && result.links.every((l) => l.uwb !== null && l.sigma === 0.3),
    `mean pair-distance error ${mean.toFixed(3)} m with UWB (case 2 without UWB: see "room relative")`);
}

// 10. One GPS phone and a lost phone 3 m away whose RSSI reads far: the ring radius is the UWB distance.
{
  const truth = { gps: { x: 100, z: 50 }, lost: { x: 103, z: 50 } };
  seed = 17;
  const links = withUwb([{ a: 'gps', b: 'lost', rssi: rssiAt(RADIO_MODEL, 8) }], truth, [['gps', 'lost']], 0.05);
  const result = run('uwb-ring', { ids: ['gps', 'lost'], links, priors: [{ id: 'gps', x: 100, z: 50, r95: 15 }], radio: RADIO_MODEL });
  const lost = result.nodes.find((n) => n.id === 'lost')!;
  const gps = result.nodes.find((n) => n.id === 'gps')!;
  // A UWB link to a phone with no position adds nothing to where the GPS phone is: its circle
  // stays its own 15 m, not the ~11 m it showed while the link counted as if the other end were fixed.
  check('uwb ring', lost.ringCenter === 'gps' && Math.abs(lost.ringRadius! - 3) < 0.15 && lost.r95 < 3.8 && Math.abs(gps.r95 - 15) < 0.01,
    `ring radius ${lost.ringRadius?.toFixed(2)} m (RSSI alone says 8 m), r95 ${lost.r95.toFixed(2)} m; GPS phone r95 ${gps.r95.toFixed(2)} m`);
}

// 11. Calibration from UWB truth: phones without any position still teach the radio its p0 and n.
{
  const room: RadioModel = { ...RADIO_MODEL, p0: -63, n: 2.2 };
  const truth: Record<string, Point> = { a: { x: 0, z: 0 }, b: { x: 1.5, z: 0 }, c: { x: 4, z: 1 }, d: { x: 1, z: 6 }, e: { x: 7, z: 3 } };
  const ids = Object.keys(truth);
  const pairs: Array<[string, string]> = [];
  for (let i = 0; i < ids.length; i += 1) for (let j = i + 1; j < ids.length; j += 1) pairs.push([ids[i], ids[j]]);
  seed = 19;
  const links = withUwb(pairs.map(([a, b]) => ({ a, b, rssi: rssiAt(room, dist(truth[a], truth[b])) })), truth, pairs, 0.05);
  const result = run('uwb-calibration', { ids, links, priors: [], radio: RADIO_MODEL, calibrate: true });
  const rangeError = (radio: RadioModel): number => {
    const probes = [1, 2, 4, 8, 12];
    return probes.reduce((sum, d) => sum + Math.abs(Math.pow(10, (radio.p0 - rssiAt(room, d)) / (10 * radio.n)) - d) / d, 0) / probes.length;
  };
  check('uwb calibration', rangeError(result.radio) < rangeError(RADIO_MODEL) / 2,
    `p0 ${result.radio.p0.toFixed(2)}, n ${result.radio.n.toFixed(3)}; mean range error ${(100 * rangeError(RADIO_MODEL)).toFixed(0)} % → ${(100 * rangeError(result.radio)).toFixed(0)} %`);
}

// 12. Two anchors, a rigid UWB triangle of lost phones with only noisy RSSI to the anchors: the
// triangle keeps its UWB shape and the solve converges (stiff UWB links need the rigid-group step;
// one phone at a time, a warm restart still moved it 2 m). Where the triangle sits comes from the
// noisy RSSI to the anchors, so its error is about what the same links give without UWB.
{
  const truth: Record<string, Point> = { a1: { x: 0, z: 0 }, a2: { x: 10, z: 0 }, p: { x: 4, z: 3 }, q: { x: 6, z: 4 }, r: { x: 5, z: 6 } };
  seed = 23;
  const rssiPairs: Array<[string, string]> = [['a1', 'p'], ['a1', 'q'], ['a1', 'r'], ['a2', 'p'], ['a2', 'q'], ['a2', 'r']];
  const uwbPairs: Array<[string, string]> = [['p', 'q'], ['p', 'r'], ['q', 'r']];
  const rssiOnly = linksFor(truth, [...rssiPairs, ...uwbPairs], 2);
  const links = withUwb(rssiOnly, truth, uwbPairs);
  const input: SignalMapInput = {
    ids: Object.keys(truth),
    links,
    priors: [
      { id: 'a1', x: 0, z: 0, r95: 0.5 },
      { id: 'a2', x: 10, z: 0, r95: 0.5 },
    ],
    radio: RADIO_MODEL,
  };
  const result = run('uwb-cluster-world', input);
  const again = solveSignalMap({ ...input, previous: new Map(result.nodes.map((n) => [n.id, { x: n.x, z: n.z }])) });
  const moved = Math.max(...result.nodes.map((n, i) => dist(n, again.nodes[i])));
  const pos = new Map(result.nodes.map((n) => [n.id, n]));
  const shape = Math.max(...uwbPairs.map(([a, b]) => Math.abs(dist(pos.get(a)!, pos.get(b)!) - dist(truth[a], truth[b]))));
  const err = (n: Point, t: Point) => Math.min(dist(n, t), dist(n, { x: t.x, z: -t.z }));
  const worst = (nodes: ReadonlyMap<string, Point>) => Math.max(...['p', 'q', 'r'].map((id) => err(nodes.get(id)!, truth[id])));
  const without = new Map(solveSignalMap({ ...input, links: rssiOnly }).nodes.map((n) => [n.id, n]));
  check('uwb cluster', shape < 0.25 && moved < 1e-3 && pos.get('p')!.frame === 'world',
    `UWB shape error ${shape.toFixed(3)} m, warm restart moves ${moved.toFixed(5)} m, worst position error ${worst(pos).toFixed(2)} m (${worst(without).toFixed(2)} m without UWB)`);
  // The triangle is placed only as well as its RSSI links to the anchors place it, so its circles
  // must say so (each member's local circle alone was about 1 m around spots 4-5 m off).
  const cover = ['p', 'q', 'r'].map((id) => ({ id, off: dist(pos.get(id)!, truth[id]), r95: pos.get(id)!.r95 }));
  check('uwb cluster circles', cover.every((c) => c.off <= c.r95),
    cover.map((c) => `${c.id} ${c.off.toFixed(2)} m off, r95 ${c.r95.toFixed(2)} m`).join('; '));
}

if (process.argv.includes('--write-golden')) {
  const golden = cases.map(({ name, input }) => ({
    name,
    input: { ...input, previous: input.previous ? Object.fromEntries(input.previous) : null, calibrate: input.calibrate ?? false },
    output: solveSignalMap(input),
  }));
  const path = new URL('../../ios/MeshCore/Tests/MeshCoreTests/signalmap-golden.json', import.meta.url);
  writeFileSync(path, JSON.stringify(golden, null, 1) + '\n');
  console.log(`wrote ${golden.length} golden cases to ${path.pathname}`);
}

if (failures > 0) {
  console.error(`${failures} check(s) failed`);
  process.exit(1);
}
