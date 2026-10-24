import {
  DEVICE_STALE_MS,
  ESTIMATE_LINK_MAX_AGE_MS,
  MAX_TRAIL_AGE_MS,
  MAX_TRAIL_POINTS,
  RADIO_MODEL,
  SCHEMA_VERSION,
  SIMULATED_RADIO_MODEL,
  type BluetoothEstimate,
  type DeviceSnapshot,
  type NeighborSnapshot,
  type PositionSource,
  type RadioModel,
  type SceneMode,
  type SceneSnapshot,
  type SignalLinkSnapshot,
  type TrailPoint,
} from '../shared/contract.ts';
import {
  placeInWorld,
  ringPoints,
  solveSignalMap,
  type SignalLink,
  type SignalNode,
  type WorldPlacement,
} from '../shared/signalmap.ts';
import type { NormalizedBatch } from './validate.ts';

interface StoredDevice {
  id: string;
  label: string | null;
  role: DeviceSnapshot['role'];
  epochId: string;
  sequence: number;
  position: { x: number; y: number; z: number };
  positionMode: DeviceSnapshot['positionMode'];
  accuracyMeters: number | null;
  measurementAgeMs: number | null;
  receivedAt: number;
  trail: TrailPoint[];
  neighbors: NeighborSnapshot[];
  positionSource: PositionSource;
  /** This phone in the last signal map; null while its report is stale. */
  signal: SignalNode | null;
  /** Where real-world views draw it, consistent with the signal map; null when unknown. */
  placement: WorldPlacement | null;
}

interface SceneState {
  frameId: string | null;
  gatewayId: string | null;
  lastUploadAt: number | null;
  devices: Map<string, StoredDevice>;
  retiredEpochs: Map<string, Set<string>>;
  stats: { accepted: number; ignored: number; rejected: number; batches: number };
  radio: RadioModel;
  /** Last signal-map layout, so the picture stays put from one second to the next. */
  layout: Map<string, { x: number; z: number }>;
  signalLinks: SignalLinkSnapshot[];
  calibratedRadio: RadioModel;
}

export interface MergeResult {
  accepted: number;
  ignored: number;
}

const emptyState = (radio: RadioModel = RADIO_MODEL): SceneState => ({
  frameId: null,
  gatewayId: null,
  lastUploadAt: null,
  devices: new Map(),
  retiredEpochs: new Map(),
  stats: { accepted: 0, ignored: 0, rejected: 0, batches: 0 },
  radio,
  layout: new Map(),
  signalLinks: [],
  calibratedRadio: { ...radio },
});

const cloneTrail = (trail: TrailPoint[]): TrailPoint[] => trail.map((point) => ({ ...point }));

function trimTrail(trail: TrailPoint[], now: number): void {
  while (trail.length > MAX_TRAIL_POINTS) trail.shift();
  while (trail.length > 0 && now - trail[0].at > MAX_TRAIL_AGE_MS) trail.shift();
}

export class SceneStore {
  private live = emptyState();
  private simulated = emptyState(SIMULATED_RADIO_MODEL);
  private mode: SceneMode = 'idle';
  private simulationRunning = false;
  private revision = 0;
  private lanUrls: string[] = [];
  private uploadPort = 3000;
  private publicUrl: string | null = null;

  setNetworkInfo(lanUrls: string[], uploadPort: number): void {
    if (lanUrls.join() !== this.lanUrls.join() || uploadPort !== this.uploadPort) this.revision += 1;
    this.lanUrls = lanUrls;
    this.uploadPort = uploadPort;
  }

  getPublicUrl(): string | null {
    return this.publicUrl;
  }

  setPublicUrl(url: string | null): void {
    this.publicUrl = url;
    this.revision += 1;
  }

  getMode(): SceneMode {
    return this.mode;
  }

  isSimulationRunning(): boolean {
    return this.simulationRunning;
  }

  setSimulationRunning(running: boolean): void {
    this.simulationRunning = running;
    this.revision += 1;
  }

  getActiveState(): SceneState {
    return this.mode === 'simulated' ? this.simulated : this.live;
  }

  mergeLive(batch: NormalizedBatch, now = Date.now()): MergeResult {
    if (this.mode === 'idle') this.mode = 'live';
    return this.merge(this.live, batch, now, 'live');
  }

  mergeSimulated(batch: NormalizedBatch, now = Date.now()): MergeResult {
    return this.merge(this.simulated, batch, now, 'simulated');
  }

  recordRejected(): void {
    this.getActiveState().stats.rejected += 1;
    this.revision += 1;
  }

  private merge(
    state: SceneState,
    batch: NormalizedBatch,
    now: number,
    target: Exclude<SceneMode, 'idle'>,
  ): MergeResult {
    if (this.mode !== target) {
      // Keep stray traffic out of the scene that is not currently being displayed.
      return { accepted: 0, ignored: batch.devices.length };
    }

    if (state.frameId !== null && state.frameId !== batch.frameId) {
      throw new FrameMismatchError(state.frameId, batch.frameId);
    }
    state.frameId = batch.frameId;
    state.gatewayId = batch.gatewayId;
    state.lastUploadAt = now;
    state.stats.batches += 1;

    let accepted = 0;
    let ignored = 0;

    for (const incoming of batch.devices) {
      const existing = state.devices.get(incoming.id);
      const retired = state.retiredEpochs.get(incoming.id);

      if (retired?.has(incoming.epochId)) {
        ignored += 1;
        state.stats.ignored += 1;
        continue;
      }

      if (existing && existing.epochId === incoming.epochId) {
        if (incoming.sequence <= existing.sequence) {
          ignored += 1;
          state.stats.ignored += 1;
          continue;
        }
        existing.sequence = incoming.sequence;
        existing.position = incoming.position;
        existing.positionMode = incoming.positionMode;
        existing.accuracyMeters = incoming.accuracyMeters;
        existing.measurementAgeMs = incoming.measurementAgeMs;
        existing.neighbors = incoming.neighbors;
        if (incoming.label !== null) existing.label = incoming.label;
        existing.role = incoming.role;
        existing.receivedAt = now;
        // Trails follow the drawn position, which updateEstimates adds once a second.
        if (incoming.positionSource !== existing.positionSource) existing.trail = [];
        existing.positionSource = incoming.positionSource;
        trimTrail(existing.trail, now);
      } else {
        if (existing) {
          const set = state.retiredEpochs.get(incoming.id) ?? new Set<string>();
          set.add(existing.epochId);
          state.retiredEpochs.set(incoming.id, set);
        }
        state.devices.set(incoming.id, {
          id: incoming.id,
          label: incoming.label,
          role: incoming.role,
          epochId: incoming.epochId,
          sequence: incoming.sequence,
          position: incoming.position,
          positionMode: incoming.positionMode,
          accuracyMeters: incoming.accuracyMeters,
          measurementAgeMs: incoming.measurementAgeMs,
          receivedAt: now,
          trail: [],
          neighbors: incoming.neighbors,
          positionSource: incoming.positionSource,
          signal: null,
          placement: null,
        });
      }

      accepted += 1;
      state.stats.accepted += 1;
    }

    this.revision += 1;
    return { accepted, ignored };
  }

  reset(mode: 'live' | 'simulated'): void {
    this.mode = mode;
    if (mode === 'live') this.live = emptyState();
    else this.simulated = emptyState(SIMULATED_RADIO_MODEL);
    this.revision += 1;
  }

  setMode(mode: SceneMode): void {
    this.mode = mode;
    if (mode !== 'simulated') this.simulationRunning = false;
    this.revision += 1;
  }

  resetSimulation(): void {
    this.simulated = emptyState(SIMULATED_RADIO_MODEL);
    this.revision += 1;
  }

  /**
   * One second of the signal map for the displayed scene: every fresh phone is laid out so that
   * distances match its Bluetooth ranges, with reported positions as priors (shared/signalmap.ts).
   * Phones without a position are placed from it, and phones with one move to agree with it when
   * their group is anchored in the world, so distances on the map match the radio.
   */
  updateEstimates(now = Date.now()): void {
    const state = this.getActiveState();
    const fresh = [...state.devices.values()].filter((device) => now - device.receivedAt <= DEVICE_STALE_MS);
    const freshIds = new Set(fresh.map((device) => device.id));

    // Each end's report is a link; the solver averages the two.
    const links: SignalLink[] = [];
    for (const device of fresh) {
      for (const neighbor of device.neighbors) {
        if (neighbor.rssi === null || !freshIds.has(neighbor.id)) continue;
        if (now - device.receivedAt + (neighbor.ageMs ?? 0) > ESTIMATE_LINK_MAX_AGE_MS) continue;
        if (usedByFusion(device, state.devices.get(neighbor.id)!)) continue;
        links.push({ a: device.id, b: neighbor.id, rssi: neighbor.rssi });
      }
    }
    const result = solveSignalMap({
      ids: fresh.map((device) => device.id),
      links,
      priors: fresh
        .filter((device) => device.positionSource !== 'none')
        .map((device) => ({ id: device.id, x: device.position.x, z: device.position.z, r95: device.accuracyMeters })),
      radio: state.radio,
      previous: state.layout,
      calibrate: true,
    });
    state.layout = new Map(result.nodes.map((node) => [node.id, { x: node.x, z: node.z }]));
    state.signalLinks = result.links.map((link) => ({ ...link }));
    state.calibratedRadio = result.radio;

    const nodes = new Map(result.nodes.map((node) => [node.id, node]));
    for (const device of state.devices.values()) {
      const node = nodes.get(device.id) ?? null;
      device.signal = node;
      device.placement = node ? placeInWorld(node, nodes) : null;
      const drawn = drawnPosition(device);
      if (drawn && freshIds.has(device.id)) {
        device.trail.push({ ...drawn.position, at: now });
        trimTrail(device.trail, now);
      }
    }
    this.revision += 1;
  }

  snapshot(now = Date.now()): SceneSnapshot {
    const state = this.getActiveState();
    const devices: DeviceSnapshot[] = [];

    for (const device of state.devices.values()) {
      trimTrail(device.trail, now);
      const drawn = drawnPosition(device);
      const placement = device.placement;
      const node = device.signal;
      const estimate: BluetoothEstimate | null =
        device.positionSource === 'none' && placement
          ? { r95: placement.r95, ambiguous: placement.ambiguous, hops: node?.hops ?? null, cloud: ringPoints(placement) }
          : null;
      devices.push({
        id: device.id,
        label: device.label,
        role: device.role,
        epochId: device.epochId,
        sequence: device.sequence,
        position: drawn ? drawn.position : { ...device.position },
        positionMode: drawn ? drawn.positionMode : device.positionMode,
        accuracyMeters: drawn ? drawn.accuracy : device.accuracyMeters,
        measurementAgeMs: device.measurementAgeMs,
        receivedAt: device.receivedAt,
        trail: cloneTrail(device.trail),
        neighbors: device.neighbors.map((neighbor) => ({ ...neighbor })),
        positionSource: device.positionSource,
        estimate,
        reportedPosition: drawn?.moved ? { ...device.position } : null,
        signal: node
          ? {
              x: node.x,
              z: node.z,
              r95: node.r95,
              frame: node.frame,
              component: node.component,
              placed: node.placed,
              ringCenter: node.ringCenter,
              ringRadius: node.ringRadius,
            }
          : null,
      });
    }

    devices.sort((a, b) => a.id.localeCompare(b.id));

    return {
      schemaVersion: SCHEMA_VERSION,
      revision: this.revision,
      serverTime: now,
      mode: this.mode,
      simulationRunning: this.simulationRunning,
      frameId: state.frameId,
      units: 'm',
      gateway: { id: state.gatewayId, lastUploadAt: state.lastUploadAt },
      devices,
      stats: { ...state.stats },
      lanUrls: this.lanUrls,
      uploadPort: this.uploadPort,
      publicUrl: this.publicUrl,
      signalMap: { links: state.signalLinks.map((link) => ({ ...link })), radio: { ...state.calibratedRadio } },
    };
  }
}

/**
 * A fused phone's position already uses the RSSI of its links to anchor phones (FusionEngine);
 * using those links again in the signal map would count the same evidence twice.
 */
function usedByFusion(a: StoredDevice, b: StoredDevice): boolean {
  return (a.positionSource === 'fused' && b.role === 'anchor') || (b.positionSource === 'fused' && a.role === 'anchor');
}

/** A drawn position this far from the report counts as moved, and the report is shown with it. */
const MOVED_REPORT_M = 0.5;

interface DrawnPosition {
  position: { x: number; y: number; z: number };
  positionMode: DeviceSnapshot['positionMode'];
  accuracy: number | null;
  /** True when the signal map moved a reported position. */
  moved: boolean;
}

/**
 * Where world views draw a device. A phone without a position goes to its signal-map placement,
 * if it has one. A phone with a position that has Bluetooth links moves to its signal-map spot,
 * which agrees with both its report and its links, so distances on the map are the measured ones
 * (a ±20 m GPS phone 2 m from a fixed anchor is drawn 2 m from it). Without links it stays put.
 */
function drawnPosition(device: StoredDevice): DrawnPosition | null {
  const placement = device.placement;
  if (device.positionSource === 'none') {
    return placement
      ? { position: { x: placement.x, y: 0, z: placement.z }, positionMode: 'floor', accuracy: placement.r95, moved: false }
      : null;
  }
  if (placement && (device.signal?.degree ?? 0) > 0) {
    const shift = Math.hypot(placement.x - device.position.x, placement.z - device.position.z);
    return {
      position: { x: placement.x, y: device.position.y, z: placement.z },
      positionMode: device.positionMode,
      accuracy: placement.r95,
      moved: shift > MOVED_REPORT_M,
    };
  }
  return { position: { ...device.position }, positionMode: device.positionMode, accuracy: device.accuracyMeters, moved: false };
}

export class FrameMismatchError extends Error {
  constructor(
    readonly expected: string,
    readonly received: string,
  ) {
    super(
      `frameId "${received}" does not match active frame "${expected}". ` +
        'Use a new frameId and reset the dashboard before mixing coordinate systems.',
    );
    this.name = 'FrameMismatchError';
  }
}

export const isStale = (snapshot: DeviceSnapshot, now: number): boolean =>
  now - snapshot.receivedAt > DEVICE_STALE_MS;
