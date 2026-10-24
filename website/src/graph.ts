import {
  LINK_EXPIRE_MS,
  LINK_FADE_MS,
  MAX_NEIGHBORS_PER_DEVICE,
  type DeviceSnapshot,
} from '../shared/contract.ts';

/** How much newer the other end's report must be before its silence about a link counts. */
const CONTRADICTION_GRACE_MS = 3_000;
/** RSSI mapped to link quality 0 and 1. */
const RSSI_WEAK = -95;
const RSSI_STRONG = -55;
/** Quality factor for a link only one end reports. */
const ONE_SIDED_QUALITY = 0.6;

/**
 * - `confirmed`: both ends report the link.
 * - `one-sided`: one end reports it and the other end's report can't tell (not yet sent, stale,
 *   full neighbor list, or no neighbors reported at all).
 */
export type LinkStatus = 'confirmed' | 'one-sided';

export interface MeshEdge {
  /** Device IDs, `a < b`. */
  a: string;
  b: string;
  /** Milliseconds since either end last heard the other directly. */
  age: number;
  fresh: boolean;
  status: LinkStatus;
  /**
   * Mean of both directions' RSSI. Each direction includes one phone's transmit and the other's
   * receive gain, so the mean cancels most of the difference between phone radios.
   */
  rssi: number | null;
  /** |RSSI a→b − RSSI b→a| when both ends report RSSI; large values hint at a radio offset. */
  asymmetryDb: number | null;
  /** 0–1 from RSSI, lowered for one-sided links; 0.5 when no RSSI is known. */
  quality: number;
}

interface Observation {
  reporter: DeviceSnapshot;
  /** Server time when the reporter last heard the other end directly. */
  heardAt: number;
  rssi: number | null;
}

interface PairEvidence {
  a: string;
  b: string;
  fromA?: Observation;
  fromB?: Observation;
}

/**
 * Builds the mesh graph from the direct-neighbor lists phones report, never from proximity.
 *
 * Phones report at different times and through relays, so the two ends of a link rarely agree
 * exactly. Each end's observation is matched with the other's, a link is dropped when the other
 * end's newer report leaves it out (the link closed), and both directions' RSSI are combined.
 */
export function buildMeshGraph(devices: readonly DeviceSnapshot[], serverNow: number): MeshEdge[] {
  const byId = new Map(devices.map((device) => [device.id, device]));
  const pairs = new Map<string, PairEvidence>();

  for (const device of devices) {
    for (const neighbor of device.neighbors) {
      if (neighbor.id === device.id || !byId.has(neighbor.id)) continue;
      const heardAt = device.receivedAt - (neighbor.ageMs ?? 0);
      if (serverNow - heardAt > LINK_EXPIRE_MS) continue;
      const [a, b] = device.id < neighbor.id ? [device.id, neighbor.id] : [neighbor.id, device.id];
      const key = `${a}|${b}`;
      const pair = pairs.get(key) ?? { a, b };
      const observation: Observation = { reporter: device, heardAt, rssi: neighbor.rssi };
      if (device.id === a) pair.fromA = observation;
      else pair.fromB = observation;
      pairs.set(key, pair);
    }
  }

  const edges: MeshEdge[] = [];
  for (const pair of pairs.values()) {
    const observations = [pair.fromA, pair.fromB].filter((entry): entry is Observation => entry !== undefined);
    if (observations.length === 1) {
      const [only] = observations;
      const other = byId.get(only.reporter.id === pair.a ? pair.b : pair.a);
      if (other && contradicts(other, only.heardAt, serverNow)) continue;
    }

    const heardAt = Math.max(...observations.map((entry) => entry.heardAt));
    const age = Math.max(0, serverNow - heardAt);
    const rssis = observations.map((entry) => entry.rssi).filter((value): value is number => value !== null);
    const rssi = rssis.length > 0 ? rssis.reduce((sum, value) => sum + value, 0) / rssis.length : null;
    const status: LinkStatus = observations.length === 2 ? 'confirmed' : 'one-sided';
    const base =
      rssi === null ? 0.5 : Math.min(1, Math.max(0, (rssi - RSSI_WEAK) / (RSSI_STRONG - RSSI_WEAK)));
    edges.push({
      a: pair.a,
      b: pair.b,
      age,
      fresh: age <= LINK_FADE_MS,
      status,
      rssi,
      asymmetryDb: rssis.length === 2 ? Math.abs(rssis[0] - rssis[1]) : null,
      quality: status === 'confirmed' ? base : base * ONE_SIDED_QUALITY,
    });
  }

  // Confirmed and fresher links first, so a renderer cap drops the weakest evidence.
  return edges.sort(
    (left, right) => Number(right.status === 'confirmed') - Number(left.status === 'confirmed') || left.age - right.age,
  );
}

/**
 * The other end has reported since the link was last heard, its report is current, and it lists
 * other neighbors but not this one: the link has closed. A device listing no neighbors at all
 * may not report them, and a full list may have cut this one, so neither counts as evidence.
 */
function contradicts(other: DeviceSnapshot, heardAt: number, serverNow: number): boolean {
  return (
    other.receivedAt - heardAt > CONTRADICTION_GRACE_MS &&
    serverNow - other.receivedAt <= LINK_EXPIRE_MS &&
    other.neighbors.length > 0 &&
    other.neighbors.length < MAX_NEIGHBORS_PER_DEVICE
  );
}

/** Edges touching one device, keyed by the other end. */
export function edgesOf(edges: readonly MeshEdge[], id: string): Map<string, MeshEdge> {
  const result = new Map<string, MeshEdge>();
  for (const edge of edges) {
    if (edge.a === id) result.set(edge.b, edge);
    else if (edge.b === id) result.set(edge.a, edge);
  }
  return result;
}
