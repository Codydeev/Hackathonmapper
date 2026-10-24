import {
  DEVICE_STALE_MS,
  ESTIMATE_LINK_MAX_AGE_MS,
  MAX_TRAIL_AGE_MS,
  MAX_TRAIL_POINTS,
  SCHEMA_VERSION,
  type BluetoothEstimate,
  type DeviceSnapshot,
  type NeighborSnapshot,
  type PositionSource,
  type SceneMode,
  type SceneSnapshot,
  type TrailPoint,
} from '../shared/contract.ts';
import { BluetoothEstimator, RADIO, type Estimate, type Measurement, type RadioModel } from './estimator.ts';
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
  /** Bluetooth placement of a phone without a position (positionSource "none"). */
  estimate: Estimate | null;
}

interface SceneState {
  frameId: string | null;
  gatewayId: string | null;
  lastUploadAt: number | null;
  devices: Map<string, StoredDevice>;
  retiredEpochs: Map<string, Set<string>>;
  stats: { accepted: number; ignored: number; rejected: number; batches: number };
  estimator: BluetoothEstimator;
}

export interface MergeResult {
  accepted: number;
  ignored: number;
}

/** Matches the simulator's radio (RSSI = -45 - 20 log10 d, links within 6.5 m). */
const SIMULATED_RADIO: RadioModel = { p0: -45, n: 2, sigma: 3, range: 6.5, soft: 0.8 };

const emptyState = (radio: RadioModel = RADIO): SceneState => ({
  frameId: null,
  gatewayId: null,
  lastUploadAt: null,
  devices: new Map(),
  retiredEpochs: new Map(),
  stats: { accepted: 0, ignored: 0, rejected: 0, batches: 0 },
  estimator: new BluetoothEstimator({ radio }),
});

const cloneTrail = (trail: TrailPoint[]): TrailPoint[] => trail.map((point) => ({ ...point }));

function trimTrail(trail: TrailPoint[], now: number): void {
  while (trail.length > MAX_TRAIL_POINTS) trail.shift();
  while (trail.length > 0 && now - trail[0].at > MAX_TRAIL_AGE_MS) trail.shift();
}

export class SceneStore {
  private live = emptyState();
  private simulated = emptyState(SIMULATED_RADIO);
  private mode: SceneMode = 'idle';
  private simulationRunning = false;
  private revision = 0;
  private lanUrls: string[] = [];
  private uploadPort = 3000;

  setNetworkInfo(lanUrls: string[], uploadPort: number): void {
    if (lanUrls.join() !== this.lanUrls.join() || uploadPort !== this.uploadPort) this.revision += 1;
    this.lanUrls = lanUrls;
    this.uploadPort = uploadPort;
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
        if (incoming.positionSource !== existing.positionSource) existing.trail = [];
        existing.positionSource = incoming.positionSource;
        if (incoming.positionSource !== 'none') {
          existing.estimate = null;
          // A "none" position is a placeholder; estimates add their own trail points.
          existing.trail.push({ ...incoming.position, at: now });
        }
        trimTrail(existing.trail, now);
      } else {
        if (existing) {
          const set = state.retiredEpochs.get(incoming.id) ?? new Set<string>();
          set.add(existing.epochId);
          state.retiredEpochs.set(incoming.id, set);
        }
        const trail: TrailPoint[] = incoming.positionSource === 'none' ? [] : [{ ...incoming.position, at: now }];
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
          trail,
          neighbors: incoming.neighbors,
          positionSource: incoming.positionSource,
          estimate: null,
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
    else this.simulated = emptyState(SIMULATED_RADIO);
    this.revision += 1;
  }

  setMode(mode: SceneMode): void {
    this.mode = mode;
    if (mode !== 'simulated') this.simulationRunning = false;
    this.revision += 1;
  }

  resetSimulation(): void {
    this.simulated = emptyState(SIMULATED_RADIO);
    this.revision += 1;
  }

  /**
   * One second of Bluetooth placement for the displayed scene: phones that report
   * positionSource "none" are placed from the RSSI of fresh links to phones that have a position.
   */
  updateEstimates(now = Date.now()): void {
    const state = this.getActiveState();
    const fresh = [...state.devices.values()].filter((device) => now - device.receivedAt <= DEVICE_STALE_MS);
    const lost = fresh.filter((device) => device.positionSource === 'none');
    if (lost.length === 0) {
      for (const device of state.devices.values()) device.estimate = null;
      return;
    }
    const anchors = fresh
      .filter((device) => device.positionSource !== 'none')
      .map((device) => ({ id: device.id, x: device.position.x, z: device.position.z, accuracy: device.accuracyMeters }));

    // One RSSI per pair: the mean of what either end reported recently.
    const pairs = new Map<string, { a: string; b: string; sum: number; count: number }>();
    for (const device of fresh) {
      for (const neighbor of device.neighbors) {
        if (neighbor.rssi === null) continue;
        if (now - device.receivedAt + (neighbor.ageMs ?? 0) > ESTIMATE_LINK_MAX_AGE_MS) continue;
        const [a, b] = device.id < neighbor.id ? [device.id, neighbor.id] : [neighbor.id, device.id];
        const key = `${a}\n${b}`;
        const pair = pairs.get(key) ?? { a, b, sum: 0, count: 0 };
        pair.sum += neighbor.rssi;
        pair.count += 1;
        pairs.set(key, pair);
      }
    }
    const measurements: Measurement[] = [...pairs.values()].map((p) => ({ a: p.a, b: p.b, rssi: p.sum / p.count }));

    const estimates = state.estimator.update(anchors, lost.map((device) => device.id), measurements);
    for (const device of state.devices.values()) {
      const estimate = device.positionSource === 'none' ? estimates.get(device.id) ?? null : null;
      device.estimate = estimate;
      if (estimate) {
        device.trail.push({ x: estimate.x, y: 0, z: estimate.z, at: now });
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
      const estimate = device.estimate;
      const placed: BluetoothEstimate | null = estimate
        ? { r95: estimate.r95, ambiguous: estimate.ambiguous, hops: estimate.hops, cloud: estimate.cloud }
        : null;
      devices.push({
        id: device.id,
        label: device.label,
        role: device.role,
        epochId: device.epochId,
        sequence: device.sequence,
        // Estimated phones are drawn at their estimate, with r95 as their accuracy.
        position: estimate ? { x: estimate.x, y: 0, z: estimate.z } : { ...device.position },
        positionMode: estimate ? 'floor' : device.positionMode,
        accuracyMeters: estimate ? estimate.r95 : device.accuracyMeters,
        measurementAgeMs: device.measurementAgeMs,
        receivedAt: device.receivedAt,
        trail: cloneTrail(device.trail),
        neighbors: device.neighbors.map((neighbor) => ({ ...neighbor })),
        positionSource: device.positionSource,
        estimate: placed,
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
    };
  }
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
