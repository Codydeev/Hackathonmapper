import type { RadioModel } from './contract.ts';

// Signal map: lays phones out on the floor plane so that their distances match the Bluetooth
// ranges measured between them (RSSI turned into meters with the shared radio model). Phones that
// report a position (GPS, UWB, manual, fused) pull the layout towards it with their own accuracy,
// so one solver serves both views:
//   - "relative": no placed phone in the group; distances are right, orientation is arbitrary.
//   - "pinned": one placed phone; distances from it are right, directions are not known.
//   - "world": two or more placed phones far enough apart; the layout is in the shared frame.
// Distances read off any view therefore agree with the radio, instead of being the difference
// of two absolute positions that each carry GPS error.
//
// Mirrored line by line by `SignalMap.swift` in MeshCore; `signalmap-golden.json` keeps them equal.

export interface SignalLink {
  a: string;
  b: string;
  /** Mean RSSI of the link in dBm (both directions averaged by the caller). */
  rssi: number;
}

export interface SignalPrior {
  id: string;
  x: number;
  z: number;
  /** Reported 95 % radius in meters; null when unknown. */
  r95: number | null;
}

export type SignalFrame = 'world' | 'pinned' | 'relative';

export interface SignalNode {
  id: string;
  x: number;
  z: number;
  /** False for a phone with neither a link nor a position of its own: it has no place yet. */
  placed: boolean;
  /** 95 % radius around (x, z); for a ring, around `ringCenter`. */
  r95: number;
  hasPrior: boolean;
  /** Index of the connected group, in order of each group's smallest id. */
  component: number;
  frame: SignalFrame;
  degree: number;
  /** Direction unknown: the phone is somewhere on a circle of `ringRadius` around `ringCenter`. */
  ringCenter: string | null;
  ringRadius: number | null;
  /** Links to the nearest phone with a position; null when the group has none. */
  hops: number | null;
}

export interface SignalEdge {
  a: string;
  b: string;
  rssi: number;
  /** Distance from RSSI, m. */
  measured: number;
  /** One-sigma error of `measured`, m. */
  sigma: number;
  /** Distance in the solved layout, m. */
  layout: number;
}

export interface SignalMapResult {
  nodes: SignalNode[];
  links: SignalEdge[];
  /** The radio model after calibration from links between precisely placed phones. */
  radio: RadioModel;
}

export interface SignalMapInput {
  ids: readonly string[];
  links: readonly SignalLink[];
  priors: readonly SignalPrior[];
  radio: RadioModel;
  /** Last layout, for a stable picture from one second to the next. */
  previous?: ReadonlyMap<string, { x: number; z: number }> | null;
  /** Fit p0 and n from links between phones placed to within `calibrationMaxR95`. */
  calibrate?: boolean;
}

export const SIGNAL_MAP_LIMITS = {
  sweeps: 300,
  tolerance: 1e-6,
  minDistance: 0.3,
  maxDistance: 500,
  minPriorSigma: 0.3,
  /** Assumed 95 % radius of a position reported without accuracy. */
  defaultPriorR95: 5,
  calibrationMaxR95: 3,
  maxR95: 1000,
  /** A group counts as anchored in the world when its rotation is known to about 20 degrees. */
  maxWorldRotationSigma: 0.35,
} as const;

/** 95 % radius of a 2-D Gaussian per unit of its per-axis sigma: sqrt(-2 ln 0.05). */
export const R95_PER_SIGMA = 2.4477468306808166;

const SQRT_HALF = 0.7071067811865476;
/** Deterministic directions for first placement; no trigonometry, so both ports agree exactly. */
const DIRECTIONS: ReadonlyArray<readonly [number, number]> = [
  [0, 1],
  [SQRT_HALF, SQRT_HALF],
  [1, 0],
  [SQRT_HALF, -SQRT_HALF],
  [0, -1],
  [-SQRT_HALF, -SQRT_HALF],
  [-1, 0],
  [-SQRT_HALF, SQRT_HALF],
];

/** Median distance for an RSSI, clamped to the range the model can mean anything over. */
export function rangeForRssi(radio: RadioModel, rssi: number): number {
  const d = Math.pow(10, (radio.p0 - rssi) / (10 * radio.n));
  return Math.min(SIGNAL_MAP_LIMITS.maxDistance, Math.max(SIGNAL_MAP_LIMITS.minDistance, d));
}

/** One-sigma error of a range: RSSI spread is log-normal, so it grows in proportion to distance. */
export function rangeSigma(radio: RadioModel, distance: number): number {
  return (distance * Math.LN10 * radio.sigma) / (10 * radio.n);
}

export function priorSigma(r95: number | null): number {
  return Math.max(SIGNAL_MAP_LIMITS.minPriorSigma, (r95 ?? SIGNAL_MAP_LIMITS.defaultPriorR95) / R95_PER_SIGMA);
}

/**
 * Fits p0 and n from links whose two ends both report a precise position (known distance), with
 * priors that keep a fit from few links close to `radio`.
 */
export function calibrateRadio(
  radio: RadioModel,
  links: readonly SignalLink[],
  priors: ReadonlyMap<string, SignalPrior>,
): RadioModel {
  const p0Weight = 1 / 36; // prior sigma 6 dB
  const nWeight = 1 / 2.25; // prior sigma 1.5
  const w = 1 / (radio.sigma * radio.sigma);
  let s1 = 0;
  let sx = 0;
  let sxx = 0;
  let sy = 0;
  let sxy = 0;
  let count = 0;
  for (const link of links) {
    const a = priors.get(link.a);
    const b = priors.get(link.b);
    if (!a || !b) continue;
    const limit = SIGNAL_MAP_LIMITS.calibrationMaxR95;
    if (a.r95 === null || b.r95 === null || a.r95 > limit || b.r95 > limit) continue;
    const dx = a.x - b.x;
    const dz = a.z - b.z;
    const distance = Math.sqrt(dx * dx + dz * dz);
    if (distance < 0.5) continue;
    const x = -10 * Math.log10(distance);
    s1 += w;
    sx += w * x;
    sxx += w * x * x;
    sy += w * link.rssi;
    sxy += w * x * link.rssi;
    count += 1;
  }
  if (count === 0) return { ...radio };
  const a11 = s1 + p0Weight;
  const a12 = sx;
  const a22 = sxx + nWeight;
  const b1 = sy + p0Weight * radio.p0;
  const b2 = sxy + nWeight * radio.n;
  const det = a11 * a22 - a12 * a12;
  if (!(det > 0)) return { ...radio };
  const p0 = (b1 * a22 - a12 * b2) / det;
  const n = (a11 * b2 - a12 * b1) / det;
  return { ...radio, p0: Math.min(-20, Math.max(-100, p0)), n: Math.min(5, Math.max(1.5, n)) };
}

interface Adjacent {
  other: string;
  distance: number;
  weight: number;
}

export function solveSignalMap(input: SignalMapInput): SignalMapResult {
  const ids = [...new Set(input.ids)].sort();
  const index = new Map(ids.map((id, i) => [id, i]));
  const priors = new Map<string, SignalPrior>();
  for (const prior of input.priors) if (index.has(prior.id)) priors.set(prior.id, prior);

  // One link per pair; duplicates are averaged.
  const pairs = new Map<string, { a: string; b: string; sum: number; count: number }>();
  for (const link of input.links) {
    if (link.a === link.b || !index.has(link.a) || !index.has(link.b) || !Number.isFinite(link.rssi)) continue;
    const [a, b] = link.a < link.b ? [link.a, link.b] : [link.b, link.a];
    const key = `${a}\n${b}`;
    const pair = pairs.get(key) ?? { a, b, sum: 0, count: 0 };
    pair.sum += link.rssi;
    pair.count += 1;
    pairs.set(key, pair);
  }
  const links: SignalLink[] = [...pairs.keys()]
    .sort()
    .map((key) => pairs.get(key)!)
    .map((pair) => ({ a: pair.a, b: pair.b, rssi: pair.sum / pair.count }));

  const radio = input.calibrate ? calibrateRadio(input.radio, links, priors) : { ...input.radio };

  const adjacency = new Map<string, Adjacent[]>(ids.map((id) => [id, []]));
  for (const link of links) {
    const distance = rangeForRssi(radio, link.rssi);
    const sigma = rangeSigma(radio, distance);
    const weight = 1 / (sigma * sigma);
    adjacency.get(link.a)!.push({ other: link.b, distance, weight });
    adjacency.get(link.b)!.push({ other: link.a, distance, weight });
  }
  for (const list of adjacency.values()) list.sort((p, q) => (p.other < q.other ? -1 : p.other > q.other ? 1 : 0));

  // Connected groups, numbered in order of their smallest id.
  const component = new Map<string, number>();
  const groups: string[][] = [];
  for (const id of ids) {
    if (component.has(id)) continue;
    const group: string[] = [];
    const queue = [id];
    component.set(id, groups.length);
    while (queue.length > 0) {
      const u = queue.shift()!;
      group.push(u);
      for (const edge of adjacency.get(u)!) {
        if (component.has(edge.other)) continue;
        component.set(edge.other, groups.length);
        queue.push(edge.other);
      }
    }
    groups.push(group.sort());
  }

  // Start from the last layout, then reported positions, then spread out from placed phones.
  const position = new Map<string, { x: number; z: number }>();
  for (const id of ids) {
    const last = input.previous?.get(id);
    const prior = priors.get(id);
    if (last && Number.isFinite(last.x) && Number.isFinite(last.z)) position.set(id, { x: last.x, z: last.z });
    else if (prior) position.set(id, { x: prior.x, z: prior.z });
  }
  let placements = 0;
  for (const group of groups) {
    const queue = group.filter((id) => position.has(id));
    if (queue.length === 0) {
      position.set(group[0], { x: 0, z: 0 });
      queue.push(group[0]);
    }
    while (queue.length > 0) {
      const u = queue.shift()!;
      const from = position.get(u)!;
      for (const edge of adjacency.get(u)!) {
        if (position.has(edge.other)) continue;
        const [dx, dz] = DIRECTIONS[placements % DIRECTIONS.length];
        placements += 1;
        position.set(edge.other, { x: from.x + edge.distance * dx, z: from.z + edge.distance * dz });
        queue.push(edge.other);
      }
    }
  }

  // Stress majorization, one phone at a time: move each phone to the weighted mean of where its
  // links and its own reported position say it should be.
  for (let sweep = 0; sweep < SIGNAL_MAP_LIMITS.sweeps; sweep += 1) {
    let maxMove = 0;
    for (const id of ids) {
      const p = position.get(id)!;
      let sumX = 0;
      let sumZ = 0;
      let total = 0;
      const prior = priors.get(id);
      if (prior) {
        const sigma = priorSigma(prior.r95);
        const lambda = 1 / (sigma * sigma);
        sumX += lambda * prior.x;
        sumZ += lambda * prior.z;
        total += lambda;
      }
      for (const edge of adjacency.get(id)!) {
        const q = position.get(edge.other)!;
        const dx = p.x - q.x;
        const dz = p.z - q.z;
        const dist = Math.sqrt(dx * dx + dz * dz);
        let ux: number;
        let uz: number;
        if (dist < 1e-9) {
          [ux, uz] = DIRECTIONS[(index.get(id)! + index.get(edge.other)!) % DIRECTIONS.length];
        } else {
          ux = dx / dist;
          uz = dz / dist;
        }
        sumX += edge.weight * (q.x + edge.distance * ux);
        sumZ += edge.weight * (q.z + edge.distance * uz);
        total += edge.weight;
      }
      if (total === 0) continue;
      const x = sumX / total;
      const z = sumZ / total;
      maxMove = Math.max(maxMove, Math.abs(x - p.x), Math.abs(z - p.z));
      position.set(id, { x, z });
    }
    if (maxMove < SIGNAL_MAP_LIMITS.tolerance) break;
  }

  // The most precise placed phone of each group: the point the group turns about.
  const pins = groups.map((group) => {
    let best: string | null = null;
    for (const id of group) {
      const prior = priors.get(id);
      if (prior && (best === null || priorSigma(prior.r95) < priorSigma(priors.get(best)!.r95))) best = id;
    }
    return best;
  });
  // How well the other placed phones fix the group's rotation about the pin: each pulls with its
  // precision times its squared distance from the pin. Two precise anchors 10 m apart fix it to
  // about a degree; a ±20 m GPS phone 2 m away fixes nothing.
  const rotationSigma = groups.map((group, c) => {
    const pin = pins[c];
    if (pin === null) return Infinity;
    const center = position.get(pin)!;
    let information = 0;
    for (const id of group) {
      const prior = priors.get(id);
      if (id === pin || !prior) continue;
      const sigma = priorSigma(prior.r95);
      const p = position.get(id)!;
      const dx = p.x - center.x;
      const dz = p.z - center.z;
      information += (dx * dx + dz * dz) / (sigma * sigma);
    }
    return information > 0 ? 1 / Math.sqrt(information) : Infinity;
  });
  const frames: SignalFrame[] = groups.map((_, c) => {
    if (pins[c] === null) return 'relative';
    return rotationSigma[c] < SIGNAL_MAP_LIMITS.maxWorldRotationSigma ? 'world' : 'pinned';
  });

  // Hops from the nearest placed phone.
  const hops = new Map<string, number>();
  const hopQueue = ids.filter((id) => priors.has(id));
  for (const id of hopQueue) hops.set(id, 0);
  while (hopQueue.length > 0) {
    const u = hopQueue.shift()!;
    for (const edge of adjacency.get(u)!) {
      if (hops.has(edge.other)) continue;
      hops.set(edge.other, hops.get(u)! + 1);
      hopQueue.push(edge.other);
    }
  }

  const nodes: SignalNode[] = ids.map((id) => {
    const p = position.get(id)!;
    const c = component.get(id)!;
    const frame = frames[c];
    const edges = adjacency.get(id)!;
    const prior = priors.get(id);
    const node: SignalNode = {
      id,
      x: p.x,
      z: p.z,
      placed: true,
      r95: 0,
      hasPrior: prior !== undefined,
      component: c,
      frame,
      degree: edges.length,
      ringCenter: null,
      ringRadius: null,
      hops: hops.get(id) ?? null,
    };
    if (!prior && edges.length === 0) {
      node.placed = false;
      node.r95 = SIGNAL_MAP_LIMITS.maxR95;
      return node;
    }
    if (!prior && edges.length === 1) {
      // One link gives a distance, not a direction.
      const edge = edges[0];
      node.ringCenter = edge.other;
      node.ringRadius = edge.distance;
      node.r95 = Math.min(SIGNAL_MAP_LIMITS.maxR95, edge.distance + 1.96 * rangeSigma(radio, edge.distance));
      return node;
    }
    // Local uncertainty from the information each link and the prior give.
    let a = 0;
    let b = 0;
    let d = 0;
    if (prior) {
      const sigma = priorSigma(prior.r95);
      a += 1 / (sigma * sigma);
      d += 1 / (sigma * sigma);
    }
    for (const edge of edges) {
      const q = position.get(edge.other)!;
      const dx = p.x - q.x;
      const dz = p.z - q.z;
      const dist = Math.sqrt(dx * dx + dz * dz);
      if (dist < 1e-9) continue;
      const ux = dx / dist;
      const uz = dz / dist;
      a += edge.weight * ux * ux;
      b += edge.weight * ux * uz;
      d += edge.weight * uz * uz;
    }
    const det = a * d - b * b;
    let r95 = det > 1e-12 * (a + d) * (a + d) ? R95_PER_SIGMA * Math.sqrt((a + d) / det / 2) : SIGNAL_MAP_LIMITS.maxR95;
    const pin = pins[c];
    if (pin !== null && id !== pin) {
      const q = position.get(pin)!;
      const dx = p.x - q.x;
      const dz = p.z - q.z;
      const fromPin = Math.sqrt(dx * dx + dz * dz);
      if (frame === 'pinned') {
        // The group can still turn about its pin: the distance is known, the direction is not.
        node.ringCenter = pin;
        node.ringRadius = fromPin;
        r95 += fromPin;
      } else {
        // Anchored, but the remaining rotation error grows with distance from the pin.
        const across = R95_PER_SIGMA * fromPin * rotationSigma[c];
        r95 = Math.sqrt(r95 * r95 + across * across);
      }
    }
    node.r95 = Math.min(SIGNAL_MAP_LIMITS.maxR95, r95);
    return node;
  });

  const edgesOut: SignalEdge[] = links.map((link) => {
    const p = position.get(link.a)!;
    const q = position.get(link.b)!;
    const dx = p.x - q.x;
    const dz = p.z - q.z;
    const measured = rangeForRssi(radio, link.rssi);
    return {
      a: link.a,
      b: link.b,
      rssi: link.rssi,
      measured,
      sigma: rangeSigma(radio, measured),
      layout: Math.sqrt(dx * dx + dz * dz),
    };
  });

  return { nodes, links: edgesOut, radio };
}

/** Where a real-world map may draw a phone, consistent with the signal map. */
export interface WorldPlacement {
  /** Best guess; its distance to the ring centre (and to linked phones) is the measured one. */
  x: number;
  z: number;
  /** 95 % radius around (x, z), meters; for a ring it covers the whole ring. */
  r95: number;
  /** Direction unknown: the phone is somewhere on a ring of `ringRadius` around (ringX, ringZ). */
  ambiguous: boolean;
  ringX: number | null;
  ringZ: number | null;
  ringRadius: number | null;
}

/**
 * A node's spot on a real-world map: its layout position, which keeps every Bluetooth distance,
 * plus the ring around its centre when only the distance is known. A "relative" group has no
 * place in the world (show it on the signal map instead).
 */
export function placeInWorld(node: SignalNode, nodes: ReadonlyMap<string, SignalNode>, depth = 0): WorldPlacement | null {
  if (!node.placed || node.frame === 'relative' || depth > 4) return null;
  if (node.ringCenter !== null && node.ringRadius !== null) {
    const center = nodes.get(node.ringCenter);
    const placed = center ? placeInWorld(center, nodes, depth + 1) : null;
    if (!placed) return null;
    return {
      x: node.x,
      z: node.z,
      r95: Math.min(SIGNAL_MAP_LIMITS.maxR95, node.ringRadius + node.r95 + (placed.ambiguous ? placed.r95 : 0)),
      ambiguous: true,
      ringX: placed.x,
      ringZ: placed.z,
      ringRadius: node.ringRadius,
    };
  }
  return { x: node.x, z: node.z, r95: node.r95, ambiguous: false, ringX: null, ringZ: null, ringRadius: null };
}

/** Points on a placement's ring, for maps that draw clouds; empty when the spot is known. */
export function ringPoints(placement: WorldPlacement, count = 24): { x: number; z: number }[] {
  if (!placement.ambiguous || placement.ringRadius === null || placement.ringX === null || placement.ringZ === null) return [];
  const points: { x: number; z: number }[] = [];
  for (let k = 0; k < count; k += 1) {
    const angle = (2 * Math.PI * k) / count;
    points.push({ x: placement.ringX + placement.ringRadius * Math.sin(angle), z: placement.ringZ + placement.ringRadius * Math.cos(angle) });
  }
  return points;
}
