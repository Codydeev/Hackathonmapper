// GPS drops out on a real walk: the lost phone runs the route filter
// (runtime/route-filter.js) itself, with whatever signals it still has.
// Used by live/map.html; runs in Node too (live/sim-check.mjs).
//
// Signals are simulated from the true path:
//   Bluetooth  each nearby phone adverts every 4 s; heard with the outdoor
//              model's range curve, RSSI with 5 dB noise (the same radio model
//              the filter assumes, so this is the best case for Bluetooth)
//   UWB        every 2 s within 20-50 m: 8 cm noise, 10% dropouts, 30% blocked
//              paths that read long (mean 0.8 m)
//   positions  each nearby phone's own position error drifts slowly
//              (phone GPS +-4 m, or RTK +-3 cm)
//   steps      the lost phone's pedometer and compass (step length +-6%,
//              compass bias +-7 deg, drifting), every 10 s
// The nearby phones stand or walk along the paths around the walk; where they
// are does not depend on the setting, and every random draw happens whatever
// is switched on, so settings differ only in what the phone is told.

import { createRouteFilter } from '../runtime/route-filter.js';

export const TICK = 2, T_GPS = -60, T_END = 600, MAX_PHONES = 40;
export const NONE = { steps: false, ble: false, uwb: false, phones: 0, acc: 4 };
const RADIO = { p0: -59, n: 2.5, sigma: 5, range: 60, soft: 8 };

export const mulberry32 = (a) => () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
const gauss = (r) => Math.sqrt(-2 * Math.log(1 - r())) * Math.cos(2 * Math.PI * r());

// walks: [{ hist: 31 points 2 s apart (GPS, ending at the loss), path: 601 points 1 s apart (the truth after it) }]
export function createSimulator(rp, walks) {
  const I = rp.internals, worlds = new Map();

  // Phones on the paths within 200 m of the walk, 40% standing, the rest walking 0.8-1.5 m/s.
  function world(wi) {
    if (worlds.has(wi)) return worlds.get(wi);
    const w = walks[wi], rw = mulberry32(wi * 104729 + 17);
    const pts = [...w.hist, ...w.path], xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
    const x0 = Math.min(...xs) - 200, x1 = Math.max(...xs) + 200, y0 = Math.min(...ys) - 200, y1 = Math.max(...ys) + 200;
    const phones = [];
    for (let guard = 0; phones.length < MAX_PHONES && guard < 5000; guard++) {
      const nb = [...rp.near([x0 + rw() * (x1 - x0), y0 + rw() * (y1 - y0)], 40)].sort((a, b) => a[1][0] - b[1][0]);
      if (!nb.length) continue;
      const [e, [, s]] = nb[0], back = rw() < 0.5;
      phones.push({ d: 2 * e + (back ? 1 : 0), at: back ? I.lenOf(e) - s : s, v: rw() < 0.4 ? 0 : 0.8 + 0.7 * rw(), uwbMax: 20 + 30 * rw(), phase: Math.floor(rw() * 2) });
    }
    const track = [];   // track[j][k]: phone k at t = T_GPS + j * TICK
    for (let t = T_GPS; t <= T_END; t += TICK) {
      track.push(phones.map((ph) => I.at(ph.d, ph.at)));
      for (const ph of phones) walkPhone(ph, ph.v * TICK, rw);
    }
    const out = { phones, track };
    worlds.set(wi, out);
    return out;
  }

  // Along the paths with the learned turn probabilities; back the way it came at a dead end.
  function walkPhone(ph, dist, rw) {
    for (let g = 0; dist > 0 && g < 20; g++) {
      const rem = I.lenOf(ph.d >> 1) - ph.at;
      if (dist < rem) { ph.at += dist; return; }
      dist -= rem;
      const tr = I.turns(ph.d);
      if (!tr.to.length) { ph.d ^= 1; ph.at = 0; continue; }
      let u = rw(), k = 0;
      while (k < tr.to.length - 1 && u > tr.p[k]) u -= tr.p[k++];
      ph.d = tr.to[k]; ph.at = 0;
    }
  }

  function pedometer(path, r) {
    const scale = 1 + 0.06 * gauss(r);
    let heading = (7 * Math.PI / 180) * gauss(r);
    const steps = [];
    for (let k = 1; k < path.length; k++) {
      heading += (0.2 * Math.PI / 180) * gauss(r);
      const tx = path[k][0] - path[k - 1][0], ty = path[k][1] - path[k - 1][1];
      if (Math.hypot(tx, ty) < 0.25) { steps.push([0, 0]); continue; }
      const c = Math.cos(heading), s = Math.sin(heading);
      steps.push([scale * (c * tx - s * ty) + 0.1 * gauss(r), scale * (s * tx + c * ty) + 0.1 * gauss(r)]);
    }
    return steps;   // steps[k-1]: displacement from second k-1 to k
  }

  // One run of walk wi with setting o = { steps, ble, uwb, phones, acc }.
  // Returns a frame every TICK s from the loss: the filter's estimate, its
  // error, and which phones heard (Bluetooth) or ranged (UWB) the lost phone.
  function simulate(wi, o, cloudSize = 60) {
    const w = walks[wi], path = w.path, W = world(wi), J0 = -T_GPS / TICK;
    const f = createRouteFilter(rp, { particles: 400, random: mulberry32(wi * 7 + 1) });
    const s = f.start(w.hist, 4);
    const steps = pedometer(path, mulberry32(wi * 31 + 1));
    const rb = mulberry32(wi * 31 + 3), ru = mulberry32(wi * 37 + 5), rg = mulberry32(wi * 41 + 7);
    const err = Array.from({ length: W.phones.length }, () => [gauss(rg), gauss(rg)]);
    const frames = [];
    let synced = 0;
    for (let t = 0; t <= T_END; t += TICK) {
      const truth = path[t], heard = [], ranged = [];
      if (t > 0) {
        f.advance(s, t);
        if (o.steps && t % 10 === 0) {
          let dx = 0, dy = 0;
          for (let k = synced; k < t; k++) { dx += steps[k][0]; dy += steps[k][1]; }
          f.observeSteps(s, { dx, dy, seconds: t - synced });
          synced = t;
        }
      }
      for (let k = 0; k < W.phones.length; k++) {
        for (const a of [0, 1]) err[k][a] = 0.94 * err[k][a] + 0.341 * gauss(rg);   // AR(1), unit variance, ~30 s memory
        const p = W.track[J0 + t / TICK][k], d = Math.max(0.5, Math.hypot(p[0] - truth[0], p[1] - truth[1]));
        const uHear = rb(), nBle = gauss(rb), uDrop = ru(), uBlock = ru(), uBias = ru(), nUwb = gauss(ru);
        if (t === 0 || k >= o.phones) continue;
        const listener = [p[0] + o.acc * err[k][0], p[1] + o.acc * err[k][1]];
        if (o.ble && (t / TICK + W.phones[k].phase) % 2 === 0 && uHear < 1 / (1 + Math.exp((d - RADIO.range) / RADIO.soft))) {
          f.observeBluetooth(s, { listener, listenerAcc: o.acc, rssi: RADIO.p0 - 10 * RADIO.n * Math.log10(d) + RADIO.sigma * nBle });
          heard.push(k);
        }
        if (o.uwb && d < W.phones[k].uwbMax && uDrop > 0.1) {
          f.observeRange(s, { listener, listenerAcc: o.acc, range: d + 0.08 * nUwb + (uBlock < 0.3 ? -Math.log(1 - uBias) * 0.8 : 0) });
          ranged.push(k);
        }
      }
      const e = f.estimate(s, cloudSize);
      frames.push({ c: e.center, r: e.r95, cloud: e.cloud, err: Math.hypot(e.center[0] - truth[0], e.center[1] - truth[1]), heard, ranged });
    }
    return frames;
  }

  return { world, simulate };
}
