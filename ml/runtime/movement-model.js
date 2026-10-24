// Movement model runtime. Predicts where a person is likely to be h seconds
// from now, from where they were over the last 60 s and, with a v2 model,
// from the map around them and where they planned to go. Used when a phone
// drops out of Bluetooth range: its last known track keeps moving as a
// growing cloud instead of a frozen dot. No dependencies; browser and Node.
//
//   const model = createMovementModel(await (await fetch('movement-model-v2.json')).json());
//   const map = createMapLayer(rgbaPixels, mapMeta);          // optional, v2 only
//   const hist = historyFromTrack(track, now, model.spec);    // track: [{t, x, y}], metres, seconds
//   const pred = model.predict(hist, accuracyMeters, 60, { map, destination: [x, y] });
//   const dots = model.sample(pred, 300);                     // [[x, y], ...] for drawing
//
// Positions are metres in a flat frame. With a map they must be in the map's
// frame: toXY(lat, lon, mapMeta) converts GPS coordinates. Without a map any
// frame works (east/north, or the demo room's x/z). Predictions come back in
// the same frame.

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

// GPS coordinates to the map's metre frame (x east, y north).
export function toXY(lat, lon, meta) {
  const R = 6371000, rad = Math.PI / 180;
  return [R * Math.cos(meta.lat0 * rad) * (lon - meta.lon0) * rad, R * (lat - meta.lat0) * rad];
}

// The map's metre frame back to GPS coordinates, for drawing on a map view.
export function toLatLon(x, y, meta) {
  const R = 6371000, deg = 180 / Math.PI;
  return [meta.lat0 + (y / R) * deg, meta.lon0 + (x / (R * Math.cos(meta.lat0 / deg))) * deg];
}

// pixels: the map image's bytes (R paths, G roads, B water), `stride` bytes
// per pixel (4 for canvas ImageData, 3 for raw RGB). meta: its frame.
export function createMapLayer(pixels, meta, stride = 4) {
  return { pixels, meta, stride };
}

const silu = (v) => v / (1 + Math.exp(-v));

export function createMovementModel(spec) {
  const N = spec.histN;
  const v2 = spec.version >= 2;

  function dense(layers, x, lastLinear = true) {
    let v = x;
    layers.forEach((l, li) => {
      const out = new Array(l.b.length);
      for (let o = 0; o < l.b.length; o++) {
        const row = l.w[o];
        let s = l.b[o];
        for (let i = 0; i < v.length; i++) s += row[i] * v[i];
        out[o] = lastLinear && li === layers.length - 1 ? s : silu(s);
      }
      v = out;
    });
    return v;
  }

  function conv(input, C, H, W, layer) {
    // PyTorch Conv2d (cross-correlation) + SiLU. input: Float64Array C*H*W.
    const { w, b, stride, pad } = layer, K = w[0][0].length, O = b.length;
    const Ho = Math.floor((H + 2 * pad - K) / stride) + 1, Wo = Math.floor((W + 2 * pad - K) / stride) + 1;
    const out = new Float64Array(O * Ho * Wo);
    for (let o = 0; o < O; o++) for (let y = 0; y < Ho; y++) for (let x = 0; x < Wo; x++) {
      let s = b[o];
      for (let c = 0; c < C; c++) {
        const wk = w[o][c];
        for (let ky = 0; ky < K; ky++) {
          const iy = y * stride - pad + ky;
          if (iy < 0 || iy >= H) continue;
          for (let kx = 0; kx < K; kx++) {
            const ix = x * stride - pad + kx;
            if (ix < 0 || ix >= W) continue;
            s += wk[ky][kx] * input[(c * H + iy) * W + ix];
          }
        }
      }
      out[(o * Ho + y) * Wo + x] = silu(s);
    }
    return { out, C: O, H: Ho, W: Wo };
  }

  // The map patch the model sees: rows from far ahead to behind, columns
  // from left to right, rotated so the walking direction points up.
  function samplePatch(map, origin, th) {
    const { size: P, res, ahead } = spec.patch, m = map.meta, px = map.pixels, st = map.stride;
    const out = new Float64Array(3 * P * P);
    const c = Math.cos(th), s = Math.sin(th);
    const at = (row, col, ch) => (row < 0 || col < 0 || row >= m.height || col >= m.width) ? 0
      : px[(row * m.width + col) * st + ch] / 255;
    for (let r = 0; r < P; r++) for (let k = 0; k < P; k++) {
      const u = ahead + (P / 2 - (r + 0.5)) * res, v = (P / 2 - (k + 0.5)) * res;
      const x = origin[0] + c * u - s * v, y = origin[1] + s * u + c * v;
      const col = (x - m.xMin) / m.res - 0.5, row = (m.yMax - y) / m.res - 0.5;
      const c0 = Math.floor(col), r0 = Math.floor(row), fc = col - c0, fr = row - r0;
      for (let ch = 0; ch < 3; ch++) {
        out[(ch * P + r) * P + k] = (1 - fr) * ((1 - fc) * at(r0, c0, ch) + fc * at(r0, c0 + 1, ch))
          + fr * ((1 - fc) * at(r0 + 1, c0, ch) + fc * at(r0 + 1, c0 + 1, ch));
      }
    }
    return out;
  }

  function mapEmbedding(patch) {
    const P = spec.patch.size;
    let t = { out: patch, C: 3, H: P, W: P };
    for (const layer of spec.cnn) t = conv(t.out, t.C, t.H, t.W, layer);
    return dense([spec.cnnFc], Array.from(t.out), false);
  }

  // Everything that does not depend on h: run once when the link drops.
  function prepare(hist, acc, opts = {}) {
    const [ox, oy] = hist[N - 1];
    const d = hist.map(([x, y]) => [x - ox, y - oy]);
    let th = 0, has = 0;
    for (const k of spec.headingLookback) {
      const vx = -d[N - 1 - k][0], vy = -d[N - 1 - k][1];
      if (Math.hypot(vx, vy) >= spec.headingMin) { th = Math.atan2(vy, vx); has = 1; break; }
    }
    const c = Math.cos(th), s = Math.sin(th);
    const past = [];
    for (let i = 0; i < N - 1; i++) {
      const [dx, dy] = d[i];
      past.push((c * dx + s * dy) / spec.posScale, (-s * dx + c * dy) / spec.posScale);
    }
    const prep = { past, acc, has, th, origin: [ox, oy], extra: [], emb: [] };
    if (v2) {
      const dest = opts.destination;
      if (dest) {
        const dx = dest[0] - ox, dy = dest[1] - oy, u = c * dx + s * dy, v = -s * dx + c * dy;
        const dist = Math.max(Math.hypot(u, v), 1e-6);
        prep.extra.push(u / dist, v / dist, Math.log1p(dist) / Math.log1p(spec.destFar), 1);
      } else prep.extra.push(0, 0, 0, 0);
      prep.extra.push(opts.map ? 1 : 0);
      prep.emb = opts.map ? mapEmbedding(samplePatch(opts.map, prep.origin, th)) : new Array(spec.cnnFc.b.length).fill(0);
    }
    return prep;
  }

  // Where they may be h seconds after `prep` was made.
  function predictPrepared(prep, h) {
    h = Math.min(spec.hMax, Math.max(spec.hMin, h));
    const x = [...prep.past, Math.log(h) / Math.log(spec.hMax), Math.sqrt(h / spec.hMax), prep.acc / spec.accScale,
      prep.has, ...prep.extra, ...prep.emb];
    const p = dense(spec.layers, x);
    const scale = spec.horizonScale[0] + spec.horizonScale[1] * h;
    const c = Math.cos(prep.th), s = Math.sin(prep.th), [ox, oy] = prep.origin;
    const logits = [], means = [], covs = [];
    for (let k = 0; k < spec.K; k++) {
      const q = p.slice(6 * k, 6 * k + 6);
      logits.push(q[0]);
      const mx = q[1] * scale, my = q[2] * scale;
      const sx = spec.stdFloor + Math.exp(Math.min(3, Math.max(-7, q[3]))) * scale;
      const sy = spec.stdFloor + Math.exp(Math.min(3, Math.max(-7, q[4]))) * scale;
      const r = 0.95 * Math.tanh(q[5]);
      means.push([ox + c * mx - s * my, oy + s * mx + c * my]);
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

  // hist: spec.histN positions [x, y], spec.histStep s apart, oldest first.
  // acc: accuracyMeters of those positions. h: seconds ahead (hMin..hMax).
  // opts (v2): { map, destination: [x, y] }, both optional.
  // Returns { weights, means: [[x, y]], covs: [[xx, xy, yy]] } in hist's frame.
  function predict(hist, acc, h, opts = {}) {
    return predictPrepared(prepare(hist, acc, opts), h);
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

  return { spec, predict, prepare, predictPrepared, samplePatch, density, sample };
}
