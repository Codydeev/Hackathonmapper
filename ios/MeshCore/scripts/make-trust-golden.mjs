// Golden replays of the Luotsi trust engine for the Swift port (MeshCore TrustEngineTests).
// Usage: node make-golden.mjs <out.json>
//
// Pass 1 runs the simulated campus walker + attacker (like test/scenarios.mjs) and records every
// engine input, rounded to 9 significant digits. Pass 2 replays exactly those rounded inputs
// through a fresh JS engine and snapshots engine.state(t) once per second, so the Swift test can
// replay the very same numbers and must reach the very same states.

import { writeFileSync } from 'node:fs';
// The Luotsi prototype (gps-katoaa repo) is the reference implementation; point LUOTSI_JS at its js/.
const LUOTSI = process.env.LUOTSI_JS || '/Users/silaswang/Projects/gps-katoaa/.claude/worktrees/luotsi/js';
const { createEngine } = await import(`${LUOTSI}/engine.js`);
const { createWalker, ORIGIN } = await import(`${LUOTSI}/sim.js`);
const { createAttacker, PULKOVO } = await import(`${LUOTSI}/attacker.js`);
const { makeFrame, rng } = await import(`${LUOTSI}/geo.js`);

const DT = 0.1;
const frame = makeFrame(ORIGIN.lat, ORIGIN.lon);
const r9 = (v) => Number(v.toPrecision(9));
const r2 = (v) => Math.round(v * 100) / 100;

const FIX = 0, STEP = 1, MOTION = 2, TICK = 3, LANDMARK = 4, HEADING = 5;

// ---- pass 1: record inputs ---------------------------------------------------

function record({ seed, duration, attack, landmarkAt, headingEvery, pause }) {
  const walker = createWalker({ frame, seed, pause });
  const attacker = createAttacker(frame, { seed: seed + 100 });
  const events = [];
  const marks = []; // {i: index of the tick event, truth}
  let k = 0, steps = 0;
  // A step before any compass reading: the engine must ignore it.
  if (headingEvery) events.push([STEP, r9(DT / 2), null]);
  for (let t = DT; t <= duration; t += DT) {
    k++;
    if (attack && Math.abs(t - attack.at) < DT / 2) attacker.start(attack.mode, t, attack.opts);
    if (attack && Math.abs(t - (attack.at + attack.secs)) < DT / 2) attacker.stop();
    const { events: evs, truth } = walker.advance(DT);
    for (const e of evs) {
      if (e.type === 'step') {
        steps++;
        // Some steps arrive as a compass update followed by a step without a heading.
        if (headingEvery && steps % headingEvery === 0) {
          events.push([HEADING, r9(e.t), r9(e.heading)]);
          events.push([STEP, r9(e.t), null]);
        } else {
          events.push([STEP, r9(e.t), r9(e.heading)]);
        }
      } else if (e.type === 'motion') {
        events.push([MOTION, r9(e.t), e.still ? 1 : 0]);
      } else if (e.type === 'fix') {
        const f = attacker.apply(e);
        if (f) events.push([FIX, r9(f.t), r9(f.x), r9(f.y), r9(f.acc)]);
      }
    }
    if (landmarkAt !== undefined && Math.abs(t - landmarkAt) < DT / 2) {
      events.push([LANDMARK, r9(t), r9(truth.x), r9(truth.y), 6]);
    }
    events.push([TICK, r9(t)]);
    if (k % Math.round(1 / DT) === 0) marks.push({ i: events.length - 1, truth: [r2(truth.x), r2(truth.y)] });
  }
  return { events, marks };
}

// ---- pass 2: replay through the JS engine -------------------------------------

const LANDMARK_LABEL = 'the point you marked';

function replay(events, marks) {
  const engine = createEngine();
  const snaps = [];
  // Witness details and reasons repeat a lot: store each distinct string once.
  const strings = [], index = new Map();
  const str = (text) => {
    if (!index.has(text)) { index.set(text, strings.length); strings.push(text); }
    return index.get(text);
  };
  let m = 0, lastSeen = null;
  for (let i = 0; i < events.length; i++) {
    const e = events[i];
    switch (e[0]) {
      case FIX: engine.onFix({ t: e[1], x: e[2], y: e[3], acc: e[4] }); break;
      case STEP: engine.onStep(e[2] === null ? { t: e[1] } : { t: e[1], heading: e[2] }); break;
      case MOTION: engine.onMotion({ t: e[1], still: e[2] === 1 }); break;
      case TICK: engine.tick(e[1]); break;
      case LANDMARK: engine.landmark({ t: e[1], x: e[2], y: e[3], sigma: e[4], label: LANDMARK_LABEL }); break;
      case HEADING: engine.onHeading({ heading: e[2] }); break;
      default: throw new Error('bad event');
    }
    if (m < marks.length && marks[m].i === i) {
      const t = e[1];
      const s = engine.state(t);
      // Log entries added since the previous snapshot (the log itself keeps only 80).
      const from = lastSeen ? s.events.indexOf(lastSeen) + 1 : 0;
      if (lastSeen && from === 0) throw new Error('more than 80 log entries between snapshots');
      const log = s.events.slice(from).map((l) => [l.t, l.kind, l.text]);
      if (s.events.length) lastSeen = s.events[s.events.length - 1];
      if (s.witnesses.map((w) => w.id).join() !== 'signal,speed,body,still,course,agree') throw new Error('witness order');
      snaps.push({
        i, t,
        verdict: s.verdict,
        trust: s.trust,
        reason: str(s.reason),
        est: s.est ? [s.est.x, s.est.y, s.est.sigma] : null,
        used: s.fix ? s.fix.used : false,
        dr: s.dr ? [s.dr.meters, s.dr.seconds] : null,
        walked: s.walked,
        cal: [s.cal.stepLength, s.cal.headingOffset, s.cal.blocks],
        count: s.events.length,
        witnesses: s.witnesses.map((w) => [w.score, str(w.detail)]),
        log,
        truth: marks[m].truth,
      });
      m++;
    }
  }
  if (m !== marks.length) throw new Error('missed snapshots');
  return { snapshots: snaps, strings };
}

// Order-sensitive fingerprint of every number in the inputs, so the Swift side can prove it
// decoded the JSON to the identical doubles.
function fingerprint(events) {
  const view = new DataView(new ArrayBuffer(8));
  let h = 0n;
  const mask = (1n << 64n) - 1n;
  for (const e of events) {
    for (const v of e) {
      if (v === null) continue;
      view.setFloat64(0, v);
      h = (((h << 1n) | (h >> 63n)) & mask) ^ view.getBigUint64(0);
    }
  }
  return h.toString(16).padStart(16, '0');
}

const SCENARIOS = [
  { name: 'clean', seed: 3, duration: 400, pause: { at: 0.1, secs: 30 } },
  { name: 'drag', seed: 5, duration: 330, attack: { mode: 'drag', at: 150, secs: 150 } },
  { name: 'teleport', seed: 7, duration: 260, attack: { mode: 'teleport', at: 150, secs: 60 } },
  { name: 'jam', seed: 9, duration: 260, attack: { mode: 'jam', at: 150, secs: 60 }, headingEvery: 4 },
  {
    name: 'stealth-drag', seed: 11, duration: 420,
    attack: { mode: 'drag', at: 100, secs: 220, opts: { dragRate: 0.2, dragDir: 200 } },
    landmarkAt: 400,
  },
];

const out = {
  dt: DT,
  landmarkLabel: LANDMARK_LABEL,
  witnessIds: ['signal', 'speed', 'body', 'still', 'course', 'agree'],
  witnessLabels: (() => { const e = createEngine(); e.tick(0); return e.state(0).witnesses.map((w) => w.label); })(),
  scenarios: [],
};
for (const sc of SCENARIOS) {
  const { events, marks } = record(sc);
  const replayed = JSON.parse(JSON.stringify(events)); // exactly what the Swift side will read
  const { snapshots, strings } = replay(replayed, marks);
  out.scenarios.push({
    name: sc.name,
    seed: sc.seed,
    attack: sc.attack ? { mode: sc.attack.mode, at: sc.attack.at, secs: sc.attack.secs } : null,
    fingerprint: fingerprint(replayed),
    strings,
    events: replayed,
    snapshots,
  });
}

// ---- attacker goldens ------------------------------------------------------------

const hex = (() => {
  const view = new DataView(new ArrayBuffer(8));
  return (v) => { view.setFloat64(0, v); return view.getBigUint64(0).toString(16).padStart(16, '0'); };
})();

{
  const seed = 42;
  const fake = frame.toLocal(PULKOVO.lat, PULKOVO.lon);
  const r = rng(seed);
  const next = Array.from({ length: 16 }, () => hex(r()));
  const g = rng(seed);
  const gauss = Array.from({ length: 16 }, () => hex(g.gauss()));
  const attacker = createAttacker(frame, { seed });
  const ops = [];
  const apply = (t, x, y, acc) => {
    const f = attacker.apply({ t, x, y, acc });
    ops.push({ op: 'apply', t: hex(t), x: hex(x), y: hex(y), acc: hex(acc), out: f ? [hex(f.x), hex(f.y), hex(f.acc)] : null });
  };
  const start = (mode, t, opts) => {
    attacker.start(mode, t, opts);
    ops.push({ op: 'start', mode, t: hex(t), dragRate: opts?.dragRate ?? null, dragDir: opts?.dragDir ?? null });
  };
  const elapsed = (t) => ops.push({ op: 'elapsed', t: hex(t), value: hex(attacker.elapsed(t)) });
  apply(1, 12.5, -40.25, 4.5); // no attack: passthrough
  elapsed(2);
  start('jam', 10);
  for (let t = 10; t <= 14; t += 0.5) apply(t, 30 + t, -20 + 0.3 * t, 4);
  elapsed(12.25);
  attacker.stop(); ops.push({ op: 'stop' });
  elapsed(13);
  start('teleport', 20);
  for (let t = 20; t < 26; t += 1) apply(t, 50 + t, 10 - t, 3.5);
  start('drag', 30);
  for (let t = 30; t < 36; t += 1.25) apply(t, 5 + t, 7 - 0.5 * t, 5);
  start('drag', 40, { dragRate: 0.3, dragDir: 120 });
  for (let t = 40; t < 46; t += 1.5) apply(t, -t, 2 * t, 6);
  start('drag', 50, { dragRate: 0 }); // 0 is falsy in JS: rate and direction stay 0.3 m/s, 120°
  for (let t = 50; t < 53; t += 1) apply(t, t, t, 7);
  attacker.stop(); ops.push({ op: 'stop' });
  apply(60, 1, 2, 3);
  out.attacker = { seed, fake: [hex(fake.x), hex(fake.y)], next, gauss, ops };
}

const json = JSON.stringify(out);
writeFileSync(process.argv[2], json);

// ---- coverage report (stderr) ----------------------------------------------------
for (const sc of out.scenarios) {
  const verdicts = {};
  for (const s of sc.snapshots) verdicts[s.verdict] = (verdicts[s.verdict] || 0) + 1;
  console.error(`\n== ${sc.name}: ${sc.events.length} events, ${sc.snapshots.length} snapshots`, JSON.stringify(verdicts));
  for (const s of sc.snapshots) for (const l of s.log) console.error(`  ${l[0].toFixed(1).padStart(6)} ${l[1].padEnd(4)} ${l[2]}`);
  const still = sc.snapshots.filter((s) => s.witnesses[3][0] !== null).length;
  console.error(`  still witness active in ${still} snapshots; ${sc.strings.length} distinct strings`);
}
console.error(`\n${(json.length / 1024).toFixed(0)} KB`);
