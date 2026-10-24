// Places phones that have no position (positionSource "none") from the Bluetooth signal strength
// (RSSI) of the links they and their neighbours report, hop by hop from phones that do have one.
// TypeScript port of the particle filter tested in the Luotsi prototype (gps-katoaa js/mesh.js).
//
// Each phone's belief is a weighted cloud of particles on the floor plane (x east, z north):
//   - anchor (GPS or manual position): a cloud around that position
//   - lost phone with history: last cloud, spread a little each second, kept from drifting by
//     the RSSI of every heard neighbour (sampled from that neighbour's own cloud, so uncertainty
//     grows with every hop) and by the phones it can NOT hear
//   - lost phone with no history: a ring around the first neighbour it hears. RSSI gives
//     distance, not direction: one neighbour leaves a ring, two leave two spots, three a point.

export interface RadioModel {
  /** dBm received at 1 m. */
  p0: number;
  /** Path-loss exponent. */
  n: number;
  /** dB spread of a one-second averaged RSSI reading, including phone-model differences. */
  sigma: number;
  /** m at which half of the one-second windows still hear the phone. */
  range: number;
  /** m over which reception fades out. */
  soft: number;
}

/** Defaults for phones outdoors with some foliage; calibrate with measured RSSI-vs-distance. */
export const RADIO: RadioModel = { p0: -59, n: 2.5, sigma: 5, range: 60, soft: 8 };

export const expectedRssi = (d: number, r: RadioModel = RADIO): number =>
  r.p0 - 10 * r.n * Math.log10(Math.max(0.5, d));
export const rssiToDistance = (rssi: number, r: RadioModel = RADIO): number => 10 ** ((r.p0 - rssi) / (10 * r.n));
export const hearProb = (d: number, r: RadioModel = RADIO): number => 1 / (1 + Math.exp((d - r.range) / r.soft));

export interface Measurement {
  a: string;
  b: string;
  rssi: number;
}

export interface Estimate {
  x: number;
  z: number;
  /** Radius around (x, z) holding 95 % of the belief. */
  r95: number;
  /** Ring or two separate spots: the centre is not a good guess. */
  ambiguous: boolean;
  /** Hops to the nearest anchor; null when not connected to one. */
  hops: number | null;
  /** A sample of the particle cloud for drawing. */
  cloud: { x: number; z: number }[];
}

interface Link {
  to: string;
  rssi: number;
}

interface Node {
  id: string;
  anchor: { x: number; y: number; sigma: number } | null;
  px: Float64Array;
  py: Float64Array;
  w: Float64Array;
  cdf: Float64Array | null;
  ready: boolean;
  cold: boolean;
  coldAge: number;
  est: { x: number; y: number; r95: number; ambiguous: boolean } | null;
  hops: number;
  links: Link[];
}

interface Options {
  particles: number;
  samples: number;
  temper: number;
  silence: number;
  reset: number;
  resetFor: number;
  sideways: number;
  jitter: number;
  cloudPoints: number;
  radio: RadioModel;
  seed: number;
}

const DEFAULTS: Options = {
  particles: 600,
  samples: 6, // neighbour particles averaged per likelihood
  temper: 0.15, // readings of the same link a second apart are strongly correlated
  silence: 0.85, // max weight of "I can't hear you, so I'm probably not next to you"
  reset: 0.03, // cold-start phones: fraction re-drawn on rings each second...
  resetFor: 15, // ...during their first seconds only
  sideways: 0.3, // weight of a neighbour no closer to an anchor and no surer than us
  jitter: 0.8, // m per second a phone may move without us knowing (no step data)
  cloudPoints: 150,
  radio: RADIO,
  seed: 5,
};

/** Seeded PRNG (mulberry32) with a Gaussian helper, so estimates are repeatable in tests. */
function rng(seed: number): { next: () => number; gauss: () => number } {
  let s = seed >>> 0;
  const next = (): number => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const gauss = (): number => {
    const u = Math.max(next(), 1e-12);
    const v = next();
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
  };
  return { next, gauss };
}

export class BluetoothEstimator {
  private readonly o: Options;
  private readonly N: number;
  private readonly rand: { next: () => number; gauss: () => number };
  private readonly nodes = new Map<string, Node>();

  constructor(options: Partial<Options> = {}) {
    this.o = { ...DEFAULTS, ...options };
    this.N = this.o.particles;
    this.rand = rng(this.o.seed);
  }

  /**
   * One second of evidence. `anchors` are phones with a position; `lost` are phones without one;
   * every other id is forgotten.
   */
  update(
    anchors: { id: string; x: number; z: number; accuracy: number | null }[],
    lost: string[],
    measurements: Measurement[],
  ): Map<string, Estimate> {
    const keep = new Set([...anchors.map((a) => a.id), ...lost]);
    for (const id of this.nodes.keys()) if (!keep.has(id)) this.nodes.delete(id);
    for (const id of keep) if (!this.nodes.has(id)) this.nodes.set(id, this.newNode(id));
    for (const id of lost) this.nodes.get(id)!.anchor = null;
    for (const a of anchors) {
      // Accuracy is a ~68 % radius; never trust a fix to better than 2 m here.
      this.nodes.get(a.id)!.anchor = { x: a.x, y: a.z, sigma: Math.max(2, a.accuracy ?? 5) };
    }
    this.step(measurements);

    const out = new Map<string, Estimate>();
    for (const id of lost) {
      const n = this.nodes.get(id)!;
      if (!n.ready || !n.est) continue;
      out.set(id, {
        x: n.est.x,
        z: n.est.y,
        r95: n.est.r95,
        ambiguous: n.est.ambiguous,
        hops: Number.isFinite(n.hops) ? n.hops : null,
        cloud: this.sampleCloud(n),
      });
    }
    return out;
  }

  private newNode(id: string): Node {
    const N = this.N;
    return {
      id,
      anchor: null,
      px: new Float64Array(N),
      py: new Float64Array(N),
      w: new Float64Array(N).fill(1 / N),
      cdf: null,
      ready: false,
      cold: false,
      coldAge: 0,
      est: null,
      hops: Infinity,
      links: [],
    };
  }

  private g(): number {
    return this.rand.gauss();
  }

  private buildCdf(n: Node): void {
    const c = n.cdf ?? new Float64Array(this.N);
    let s = 0;
    for (let k = 0; k < this.N; k++) {
      s += n.w[k];
      c[k] = s;
    }
    n.cdf = c;
  }

  private pick(n: Node): number {
    if (!n.cdf) return (this.rand.next() * this.N) | 0;
    const u = this.rand.next() * n.cdf[this.N - 1];
    let lo = 0;
    let hi = this.N - 1;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (n.cdf[mid] < u) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  }

  private ringSample(n: Node, k: number, nb: Node, rssi: number): void {
    const q = this.pick(nb);
    const d = rssiToDistance(rssi + this.o.radio.sigma * this.g(), this.o.radio);
    const th = this.rand.next() * 2 * Math.PI;
    n.px[k] = nb.px[q] + d * Math.sin(th);
    n.py[k] = nb.py[q] + d * Math.cos(th);
  }

  private summarize(n: Node): void {
    const N = this.N;
    let mx = 0;
    let my = 0;
    let sw = 0;
    for (let k = 0; k < N; k++) {
      mx += n.w[k] * n.px[k];
      my += n.w[k] * n.py[k];
      sw += n.w[k];
    }
    mx /= sw;
    my /= sw;
    const dist = new Float64Array(N);
    for (let k = 0; k < N; k++) dist[k] = Math.hypot(n.px[k] - mx, n.py[k] - my);
    const idx = Array.from({ length: N }, (_, k) => k).sort((a, b) => dist[a] - dist[b]);
    let r95 = dist[idx[N - 1]];
    let acc = 0;
    for (const k of idx) {
      acc += n.w[k] / sw;
      if (acc >= 0.95) {
        r95 = dist[k];
        break;
      }
    }
    // A ring or two separate blobs has almost no weight near its centre.
    let core = 0;
    for (let k = 0; k < N; k++) if (dist[k] < 0.25 * r95) core += n.w[k] / sw;
    n.est = { x: mx, y: my, r95, ambiguous: r95 > 15 && core < 0.05 };
  }

  private resample(n: Node): void {
    const N = this.N;
    const nx = new Float64Array(N);
    const ny = new Float64Array(N);
    let sum = 0;
    for (let k = 0; k < N; k++) sum += n.w[k];
    const step = sum / N;
    let u = this.rand.next() * step;
    let c = n.w[0];
    let i = 0;
    for (let k = 0; k < N; k++) {
      while (u > c && i < N - 1) {
        i += 1;
        c += n.w[i];
      }
      nx[k] = n.px[i] + 0.5 * this.g();
      ny[k] = n.py[i] + 0.5 * this.g();
      u += step;
    }
    n.px.set(nx);
    n.py.set(ny);
    n.w.fill(1 / N);
  }

  private sampleCloud(n: Node): { x: number; z: number }[] {
    const points: { x: number; z: number }[] = [];
    for (let i = 0; i < this.o.cloudPoints; i += 1) {
      const k = this.pick(n);
      points.push({ x: n.px[k], z: n.py[k] });
    }
    return points;
  }

  private step(measurements: Measurement[]): void {
    const { N, o } = this;
    const radio = o.radio;
    for (const n of this.nodes.values()) n.links = [];
    for (const m of measurements) {
      const a = this.nodes.get(m.a);
      const b = this.nodes.get(m.b);
      if (!a || !b || a === b) continue;
      a.links.push({ to: b.id, rssi: m.rssi });
      b.links.push({ to: a.id, rssi: m.rssi });
    }

    // Anchors: a cloud around their position.
    for (const n of this.nodes.values()) {
      if (!n.anchor) continue;
      for (let k = 0; k < N; k++) {
        n.px[k] = n.anchor.x + n.anchor.sigma * this.g();
        n.py[k] = n.anchor.y + n.anchor.sigma * this.g();
      }
      n.w.fill(1 / N);
      n.cdf = null;
      n.ready = true;
      n.cold = false;
    }

    // Hop count from the nearest anchor.
    for (const n of this.nodes.values()) n.hops = n.anchor ? 0 : Infinity;
    const queue = [...this.nodes.values()].filter((n) => n.anchor);
    while (queue.length) {
      const n = queue.shift()!;
      for (const l of n.links) {
        const m = this.nodes.get(l.to)!;
        if (m.hops > n.hops + 1) {
          m.hops = n.hops + 1;
          queue.push(m);
        }
      }
    }

    // Lost phones, closest to an anchor first so information flows outward.
    const lost = [...this.nodes.values()].filter((n) => !n.anchor).sort((a, b) => a.hops - b.hops);
    const logw = new Float64Array(N);
    for (const n of lost) {
      if (n.ready) {
        for (let k = 0; k < N; k++) {
          n.px[k] += o.jitter * this.g();
          n.py[k] += o.jitter * this.g();
        }
      }

      const known = n.links.filter((l) => this.nodes.get(l.to)!.ready);
      if (!n.ready) {
        if (!known.length) continue;
        const first = known.reduce((a, b) => (this.nodes.get(a.to)!.hops <= this.nodes.get(b.to)!.hops ? a : b));
        for (let k = 0; k < N; k++) this.ringSample(n, k, this.nodes.get(first.to)!, first.rssi);
        n.w.fill(1 / N);
        n.ready = true;
        n.cold = true;
        n.coldAge = 0;
      } else if (n.cold && known.length && ++n.coldAge < o.resetFor) {
        const resets = Math.round(o.reset * N);
        for (let r = 0; r < resets; r++) {
          const l = known[(this.rand.next() * known.length) | 0];
          const k = (this.rand.next() * N) | 0;
          this.ringSample(n, k, this.nodes.get(l.to)!, l.rssi);
          n.w[k] = 1 / N;
        }
      }

      // Weigh: every heard neighbour, and every settled phone we cannot hear.
      const heard = new Set(n.links.map((l) => l.to));
      const silent = [...this.nodes.values()].filter(
        (m) => m !== n && m.ready && !heard.has(m.id) && m.est !== null && m.est.r95 < 2 * radio.range,
      );
      if (known.length || silent.length) {
        for (let k = 0; k < N; k++) {
          let lw = 0;
          for (const l of known) {
            const nb = this.nodes.get(l.to)!;
            let p = 0;
            for (let s = 0; s < o.samples; s++) {
              const q = this.pick(nb);
              const d = Math.hypot(n.px[k] - nb.px[q], n.py[k] - nb.py[q]);
              const z = (l.rssi - expectedRssi(d, radio)) / radio.sigma;
              p += Math.exp(-0.5 * z * z);
            }
            const upstream = nb.hops < n.hops || (nb.est !== null && n.est !== null && nb.est.r95 < 0.7 * n.est.r95);
            lw += (upstream ? 1 : o.sideways) * Math.log(p / o.samples + 1e-12);
          }
          for (const m of silent) {
            let p = 0;
            for (let s = 0; s < o.samples; s++) {
              const q = this.pick(m);
              p += 1 - o.silence * hearProb(Math.hypot(n.px[k] - m.px[q], n.py[k] - m.py[q]), radio);
            }
            lw += Math.log(p / o.samples);
          }
          logw[k] = Math.log(n.w[k] + 1e-300) + o.temper * lw;
        }
        let max = -Infinity;
        for (let k = 0; k < N; k++) if (logw[k] > max) max = logw[k];
        let sum = 0;
        for (let k = 0; k < N; k++) {
          n.w[k] = Math.exp(logw[k] - max);
          sum += n.w[k];
        }
        let ess = 0;
        for (let k = 0; k < N; k++) {
          n.w[k] /= sum;
          ess += n.w[k] * n.w[k];
        }
        if (1 / ess < N / 2) this.resample(n);
      }
      this.buildCdf(n);
      this.summarize(n);
      if (n.cold && n.est && n.est.r95 < 20) n.cold = false; // ring resolved: stop re-seeding
    }
    for (const n of this.nodes.values()) if (n.anchor) this.summarize(n);
  }
}
