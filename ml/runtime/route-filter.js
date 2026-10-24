// Route filter: the route model's prediction, sharpened by whatever signals
// arrive after the Bluetooth link drops. Particles walk along the path graph
// with the learned fork probabilities and the measured pace table; a
// Bluetooth reading of the lost phone (GhostCore PeerObservation) or the lost
// phone's own step-and-compass track (GhostCore MotionRecord, synced when it
// is heard again) reweights them. No dependencies; browser and Node.
//
//   const rp = createRoutePredictor(routeModel, graph);
//   const f = createRouteFilter(rp);
//   const s = f.start(hist, accuracy);                 // when the link drops (t = 0)
//   f.advance(s, 30);                                  // walk the particles to t = 30 s
//   f.observeBluetooth(s, { listener: [x, y], listenerAcc: 5, rssi: -78 });
//   f.observeSteps(s, { dx, dy, seconds: 10 });        // summed pedometer displacement since the last call
//   const est = f.estimate(s);                         // { center, r95, share, cloud }
//
// Positions are metres in the graph's frame (x east, y north).

// MeshCore BluetoothEstimator.RadioModel.outdoors
const RADIO = { p0: -59, n: 2.5, sigma: 5, range: 60, soft: 8 };
const STEP = 2;           // s per propagation step
const PACE_TAU = 120;     // s, how long a particle keeps its pace before drifting
const OFF_TURN = 0.35;    // rad per step, heading wander off the paths
// Step tracking: how wrong a phone's compass and step length may be, how fast
// the compass error drifts, how close to a path "on the path" is, and how
// likely walking off the mapped paths is in comparison.
const PDR = { biasDeg: 10, scale: 0.08, driftDeg: 0.4, noise: 0.4, onPathM: 6, offPath: 0.08 };

function gauss(rand) {
  let u = 0;
  while (u === 0) u = rand();
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * rand());
}

export function createRouteFilter(rp, opts = {}) {
  const I = rp.internals, M = I.model, S = M.speed;
  const N = opts.particles ?? 400;
  const radio = { ...RADIO, ...(opts.radio || {}) };
  const rand = opts.random ?? Math.random;
  const offRate = -Math.log(1 - I.interp(M.offPath.t, M.offPath.on, 600)) / 600;

  // Distance walked by time t at pace score z: log-normal through the measured 10/50/90% quantiles.
  function paceCurve(bin) {
    const row = (q) => S.q[q][bin].map((v) => Math.log(Math.max(v, 0.5)));
    const l10 = row('q10'), l50 = row('q50'), l90 = row('q90');
    const sig = l10.map((v, i) => Math.max(0.05, (l90[i] - v) / (2 * 1.2816)));
    return (z, t) => (t <= 0 ? 0 : Math.exp(I.interp(S.t, l50, t) + I.interp(S.t, sig, t) * z));
  }

  function start(hist, acc) {
    const n = hist.length, last = hist[n - 1], first = hist[0];
    const v = Math.hypot(last[0] - first[0], last[1] - first[1]) / ((n - 1) * 2);
    const loc = I.locate(hist, acc);
    const total = loc.starts.reduce((a, s) => a + s.p, 0);
    const s = {
      t: 0, n: N, D: paceCurve(I.speedBin(v)),
      d: new Int32Array(N), at: new Float64Array(N), z: new Float64Array(N), walked: new Float64Array(N),
      off: new Uint8Array(N), x: new Float64Array(N), y: new Float64Array(N), th: new Float64Array(N),
      ax: new Float64Array(N), ay: new Float64Array(N), w: new Float64Array(N).fill(1 / N),
    };
    const offShare = loc.offNow || !loc.starts.length ? (loc.starts.length ? 0.6 : 1) : 0;
    for (let i = 0; i < N; i++) {
      s.z[i] = gauss(rand);
      if (rand() < offShare) {
        s.off[i] = 1; s.d[i] = -1; s.x[i] = last[0] + 3 * gauss(rand); s.y[i] = last[1] + 3 * gauss(rand);
        s.th[i] = loc.moved ? loc.th + 0.3 * gauss(rand) : 2 * Math.PI * rand();
      } else {
        let u = rand() * total, k = 0;
        while (k < loc.starts.length - 1 && u > loc.starts[k].p) u -= loc.starts[k++].p;
        s.d[i] = loc.starts[k].d; s.at[i] = loc.starts[k].s;
        const p = I.at(s.d[i], s.at[i]);
        s.x[i] = p[0]; s.y[i] = p[1];
      }
      s.ax[i] = s.x[i]; s.ay[i] = s.y[i];
    }
    return s;
  }

  // Walk particle i forward by `dist` metres along the graph (or off it).
  function move(s, i, dist) {
    if (s.off[i]) {
      s.th[i] += OFF_TURN * gauss(rand);
      s.x[i] += dist * Math.cos(s.th[i]); s.y[i] += dist * Math.sin(s.th[i]);
      return;
    }
    let d = s.d[i], at = s.at[i];
    for (let guard = 0; dist > 0 && guard < 50; guard++) {
      const rem = I.lenOf(d >> 1) - at;
      if (dist < rem) { at += dist; dist = 0; break; }
      dist -= rem;
      const tr = I.turns(d);
      if (!tr.to.length) { at = I.lenOf(d >> 1); break; }
      let u = rand(), k = 0;
      while (k < tr.to.length - 1 && u > tr.p[k]) u -= tr.p[k++];
      d = tr.to[k]; at = 0;
    }
    s.d[i] = d; s.at[i] = at;
    const p = I.at(d, at);
    s.x[i] = p[0]; s.y[i] = p[1];
  }

  // Propagate all particles to time t (seconds since the link dropped). Once
  // the lost phone's own steps are known, the steps move the particles instead.
  function advance(s, t) {
    if (s.pdr) { s.t = Math.max(s.t, t); return s; }
    const rho = Math.exp(-STEP / PACE_TAU), k = Math.sqrt(1 - rho * rho);
    while (s.t < t - 1e-9) {
      const t1 = Math.min(t, s.t + STEP), dt = t1 - s.t;
      for (let i = 0; i < s.n; i++) {
        s.z[i] = rho * s.z[i] + k * gauss(rand);
        const target = s.D(s.z[i], t1), step = target - s.walked[i];
        if (!s.off[i] && rand() < offRate * dt) {
          s.off[i] = 1; s.th[i] = 2 * Math.PI * rand();
        }
        if (step > 0) { move(s, i, step); s.walked[i] = target; }
      }
      s.t = t1;
    }
    return s;
  }

  function normalize(s) {
    let sum = 0;
    for (let i = 0; i < s.n; i++) sum += s.w[i];
    if (!(sum > 0)) { s.w.fill(1 / s.n); return; }
    let ess = 0;
    for (let i = 0; i < s.n; i++) { s.w[i] /= sum; ess += s.w[i] * s.w[i]; }
    if (1 / ess < s.n / 2) resample(s);
  }

  // Systematic resampling; copies keep their pace with a little jitter.
  function resample(s) {
    const keys = ['d', 'at', 'z', 'walked', 'off', 'x', 'y', 'th', 'ax', 'ay', ...(s.pdr ? ['bias', 'scale'] : [])];
    const old = Object.fromEntries(keys.map((key) => [key, s[key].slice()]));
    let c = s.w[0], j = 0;
    const u0 = rand() / s.n;
    for (let i = 0; i < s.n; i++) {
      const u = u0 + i / s.n;
      while (u > c && j < s.n - 1) c += s.w[++j];
      for (const key of keys) s[key][i] = old[key][j];
      s.z[i] += 0.1 * gauss(rand);
      if (s.pdr) { s.bias[i] += 0.01 * gauss(rand); s.scale[i] += 0.005 * gauss(rand); }
    }
    s.w.fill(1 / s.n);
  }

  const hearProb = (d) => 1 / (1 + Math.exp((d - radio.range) / radio.soft));

  // A phone at `listener` (± listenerAcc m) heard the lost phone at `rssi` dBm.
  function observeBluetooth(s, obs) {
    const sigma = obs.sigmaDb ?? radio.sigma, acc = obs.listenerAcc ?? 5;
    for (let i = 0; i < s.n; i++) {
      const d = Math.max(0.5, Math.hypot(s.x[i] - obs.listener[0], s.y[i] - obs.listener[1]));
      const expected = radio.p0 - 10 * radio.n * Math.log10(d);
      const sens = (10 * radio.n) / (Math.LN10 * Math.max(d, 1));
      const v = sigma * sigma + (sens * acc) ** 2;
      s.w[i] *= (Math.exp(-((obs.rssi - expected) ** 2) / (2 * v)) / Math.sqrt(v)) * hearProb(d);
    }
    normalize(s);
    return s;
  }

  // The lost phone's own pedometer and compass: displacement (dx, dy) summed
  // over the last `seconds`. The steps move every particle, each with its own
  // guess of the compass bias and step length; the map then weighs them: on a
  // path is likely, off a path stays possible (unmapped trails, open ground).
  function observeSteps(s, obs) {
    if (!s.pdr) {
      s.pdr = true;
      s.bias = new Float64Array(s.n).map(() => (PDR.biasDeg * Math.PI / 180) * gauss(rand));
      s.scale = new Float64Array(s.n).map(() => 1 + PDR.scale * gauss(rand));
    }
    const drift = (PDR.driftDeg * Math.PI / 180) * Math.sqrt(obs.seconds ?? 10);
    for (let i = 0; i < s.n; i++) {
      s.bias[i] += drift * gauss(rand);
      const c = Math.cos(s.bias[i]), sn = Math.sin(s.bias[i]), k = s.scale[i];
      s.x[i] += k * (c * obs.dx - sn * obs.dy) + PDR.noise * gauss(rand);
      s.y[i] += k * (sn * obs.dx + c * obs.dy) + PDR.noise * gauss(rand);
      const d = Math.min(I.nearestDist([s.x[i], s.y[i]], 3 * PDR.onPathM), 3 * PDR.onPathM);
      s.w[i] *= Math.exp(-(d * d) / (2 * PDR.onPathM * PDR.onPathM)) + PDR.offPath;
    }
    normalize(s);
    return s;
  }

  // Best single position: the heaviest 25 m neighbourhood, its weighted centre,
  // and the radius around it that holds 95% of the weight.
  function estimate(s, cloudSize = 80) {
    const CELL = 12, cells = new Map();
    for (let i = 0; i < s.n; i++) {
      const key = `${Math.floor(s.x[i] / CELL)},${Math.floor(s.y[i] / CELL)}`;
      cells.set(key, (cells.get(key) || 0) + s.w[i]);
    }
    let best = null, bestW = -1;
    for (const key of cells.keys()) {
      const [a, b] = key.split(',').map(Number);
      let w = 0;
      for (let da = -1; da <= 1; da++) for (let db = -1; db <= 1; db++) w += cells.get(`${a + da},${b + db}`) || 0;
      if (w > bestW) { bestW = w; best = [(a + 0.5) * CELL, (b + 0.5) * CELL]; }
    }
    let cx = 0, cy = 0, cw = 0;
    for (let i = 0; i < s.n; i++) {
      if (Math.hypot(s.x[i] - best[0], s.y[i] - best[1]) <= 25) { cx += s.w[i] * s.x[i]; cy += s.w[i] * s.y[i]; cw += s.w[i]; }
    }
    const center = cw > 0 ? [cx / cw, cy / cw] : best;
    const byDist = [...s.w.keys()].map((i) => [Math.hypot(s.x[i] - center[0], s.y[i] - center[1]), s.w[i]]).sort((a, b) => a[0] - b[0]);
    let acc = 0, r95 = byDist.length ? byDist[byDist.length - 1][0] : 0;
    for (const [d, w] of byDist) { acc += w; if (acc >= 0.95) { r95 = d; break; } }
    const cloud = [];
    for (let k = 0; k < cloudSize; k++) {
      let u = (k + 0.5) / cloudSize, i = 0;
      while (i < s.n - 1 && u > s.w[i]) u -= s.w[i++];
      cloud.push([s.x[i], s.y[i]]);
    }
    return { center, r95, share: cw, cloud };
  }

  return { start, advance, observeBluetooth, observeSteps, estimate, radio };
}
