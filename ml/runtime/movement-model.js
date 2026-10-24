// Movement model runtime. Predicts where a person is likely to be h seconds
// from now, from where they were over the last 60 s. Used when a phone drops
// out of Bluetooth range: its last known track keeps moving as a growing cloud
// instead of a frozen dot. No dependencies; works in the browser and Node.
//
//   const model = createMovementModel(await (await fetch('movement-model.json')).json());
//   const hist = historyFromTrack(track, now, model.spec);   // track: [{t, x, y}], metres, seconds
//   const pred = model.predict(hist, accuracyMeters, 60);    // where in 60 s?
//   const dots = model.sample(pred, 300);                    // [[x, y], ...] for drawing
//
// Positions are metres in any flat frame (east/north, or the demo room's x/z).
// The prediction comes back in the same frame.

export function historyFromTrack(track, now, spec) {
  // Positions every histStep seconds ending at `now`, oldest first, linearly
  // interpolated. Before the first report the person is assumed to have been
  // standing at the first position; after the last report, at the last one.
  const out = [];
  let j = 0;
  for (let i = spec.histN - 1; i >= 0; i--) {
    const t = now - i * spec.histStep;
    while (j < track.length - 1 && track[j + 1].t <= t) j++;
    const a = track[j], b = track[Math.min(j + 1, track.length - 1)];
    if (t <= a.t || a === b) out.push([a.x, a.y]);
    else if (t >= b.t) out.push([b.x, b.y]);
    else {
      const f = (t - a.t) / (b.t - a.t);
      out.push([a.x + f * (b.x - a.x), a.y + f * (b.y - a.y)]);
    }
  }
  return out;
}

const silu = (v) => v / (1 + Math.exp(-v));

export function createMovementModel(spec) {
  const layers = spec.layers.map((l) => ({ w: l.w, b: l.b }));
  const N = spec.histN;

  function forward(x) {
    let v = x;
    layers.forEach((l, li) => {
      const out = new Array(l.b.length);
      for (let o = 0; o < l.b.length; o++) {
        const row = l.w[o];
        let s = l.b[o];
        for (let i = 0; i < v.length; i++) s += row[i] * v[i];
        out[o] = li < layers.length - 1 ? silu(s) : s;
      }
      v = out;
    });
    return v;
  }

  function features(hist, acc, h) {
    const [ox, oy] = hist[N - 1];
    const d = hist.map(([x, y]) => [x - ox, y - oy]);
    let th = 0, has = 0;
    for (const k of spec.headingLookback) {
      const vx = -d[N - 1 - k][0], vy = -d[N - 1 - k][1];
      if (Math.hypot(vx, vy) >= spec.headingMin) { th = Math.atan2(vy, vx); has = 1; break; }
    }
    const c = Math.cos(th), s = Math.sin(th);
    const x = [];
    for (let i = 0; i < N - 1; i++) {
      const [dx, dy] = d[i];
      x.push((c * dx + s * dy) / spec.posScale, (-s * dx + c * dy) / spec.posScale);
    }
    x.push(Math.log(h) / Math.log(spec.hMax), Math.sqrt(h / spec.hMax), acc / spec.accScale, has);
    return { x, th, origin: [ox, oy] };
  }

  // hist: spec.histN positions [x, y], spec.histStep s apart, oldest first.
  // acc: accuracyMeters of those positions. h: seconds ahead (hMin..hMax).
  // Returns { weights, means: [[x, y]], covs: [[xx, xy, yy]] } in hist's frame.
  function predict(hist, acc, h) {
    h = Math.min(spec.hMax, Math.max(spec.hMin, h));
    const { x, th, origin } = features(hist, acc, h);
    const p = forward(x);
    const scale = spec.horizonScale[0] + spec.horizonScale[1] * h;
    const c = Math.cos(th), s = Math.sin(th);
    const logits = [], means = [], covs = [];
    for (let k = 0; k < spec.K; k++) {
      const q = p.slice(6 * k, 6 * k + 6);
      logits.push(q[0]);
      const mx = q[1] * scale, my = q[2] * scale;
      const sx = spec.stdFloor + Math.exp(Math.min(3, Math.max(-7, q[3]))) * scale;
      const sy = spec.stdFloor + Math.exp(Math.min(3, Math.max(-7, q[4]))) * scale;
      const r = 0.95 * Math.tanh(q[5]);
      means.push([origin[0] + c * mx - s * my, origin[1] + s * mx + c * my]);
      const xx = sx * sx, yy = sy * sy, xy = r * sx * sy;
      covs.push([c * c * xx - 2 * c * s * xy + s * s * yy,
                 c * s * (xx - yy) + (c * c - s * s) * xy,
                 s * s * xx + 2 * c * s * xy + c * c * yy]);
    }
    const m = Math.max(...logits);
    const e = logits.map((l) => Math.exp(l - m));
    const z = e.reduce((a, b) => a + b, 0);
    return { weights: e.map((v) => v / z), means, covs };
  }

  // Probability density (per square metre) at (x, y).
  function density(pred, x, y) {
    let p = 0;
    pred.weights.forEach((w, k) => {
      const [xx, xy, yy] = pred.covs[k];
      const det = xx * yy - xy * xy;
      const dx = x - pred.means[k][0], dy = y - pred.means[k][1];
      const q = (yy * dx * dx - 2 * xy * dx * dy + xx * dy * dy) / det;
      p += w * Math.exp(-q / 2) / (2 * Math.PI * Math.sqrt(det));
    });
    return p;
  }

  // n random positions from the prediction, for drawing a cloud or seeding a
  // particle filter.
  function sample(pred, n, random = Math.random) {
    const out = [];
    for (let i = 0; i < n; i++) {
      let u = random(), k = 0;
      while (k < spec.K - 1 && u > pred.weights[k]) u -= pred.weights[k++];
      const [xx, xy, yy] = pred.covs[k];
      const l11 = Math.sqrt(xx), l21 = xy / l11, l22 = Math.sqrt(Math.max(0, yy - l21 * l21));
      const r = Math.sqrt(-2 * Math.log(1 - random())), a = 2 * Math.PI * random();
      const z1 = r * Math.cos(a), z2 = r * Math.sin(a);
      out.push([pred.means[k][0] + l11 * z1, pred.means[k][1] + l21 * z1 + l22 * z2]);
    }
    return out;
  }

  return { spec, predict, density, sample };
}
