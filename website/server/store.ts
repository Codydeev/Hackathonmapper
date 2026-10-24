import {
  DEVICE_STALE_MS,
  MAX_TRAIL_AGE_MS,
  MAX_TRAIL_POINTS,
  SCHEMA_VERSION,
  type DeviceSnapshot,
  type SceneMode,
  type SceneSnapshot,
  type TrailPoint,
} from '../shared/contract.ts';
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
}

interface SceneState {
  frameId: string | null;
  gatewayId: string | null;
  lastUploadAt: number | null;
  devices: Map<string, StoredDevice>;
  retiredEpochs: Map<string, Set<string>>;
  stats: { accepted: number; ignored: number; rejected: number; batches: number };
}

export interface MergeResult {
  accepted: number;
  ignored: number;
}

const emptyState = (): SceneState => ({
  frameId: null,
  gatewayId: null,
  lastUploadAt: null,
  devices: new Map(),
  retiredEpochs: new Map(),
  stats: { accepted: 0, ignored: 0, rejected: 0, batches: 0 },
});

const cloneTrail = (trail: TrailPoint[]): TrailPoint[] => trail.map((point) => ({ ...point }));

function trimTrail(trail: TrailPoint[], now: number): void {
  while (trail.length > MAX_TRAIL_POINTS) trail.shift();
  while (trail.length > 0 && now - trail[0].at > MAX_TRAIL_AGE_MS) trail.shift();
}

export class SceneStore {
  private live = emptyState();
  private simulated = emptyState();
  private mode: SceneMode = 'idle';
  private simulationRunning = false;
  private revision = 0;
  private lanUrls: string[] = [];
  private uploadPort = 3000;

  setNetworkInfo(lanUrls: string[], uploadPort: number): void {
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
        if (incoming.label !== null) existing.label = incoming.label;
        existing.role = incoming.role;
        existing.receivedAt = now;
        existing.trail.push({ ...incoming.position, at: now });
        trimTrail(existing.trail, now);
      } else {
        if (existing) {
          const set = state.retiredEpochs.get(incoming.id) ?? new Set<string>();
          set.add(existing.epochId);
          state.retiredEpochs.set(incoming.id, set);
        }
        const trail: TrailPoint[] = [{ ...incoming.position, at: now }];
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
    else this.simulated = emptyState();
    this.revision += 1;
  }

  setMode(mode: SceneMode): void {
    this.mode = mode;
    if (mode !== 'simulated') this.simulationRunning = false;
    this.revision += 1;
  }

  resetSimulation(): void {
    this.simulated = emptyState();
    this.revision += 1;
  }

  snapshot(now = Date.now()): SceneSnapshot {
    const state = this.getActiveState();
    const devices: DeviceSnapshot[] = [];

    for (const device of state.devices.values()) {
      trimTrail(device.trail, now);
      devices.push({
        id: device.id,
        label: device.label,
        role: device.role,
        epochId: device.epochId,
        sequence: device.sequence,
        position: { ...device.position },
        positionMode: device.positionMode,
        accuracyMeters: device.accuracyMeters,
        measurementAgeMs: device.measurementAgeMs,
        receivedAt: device.receivedAt,
        trail: cloneTrail(device.trail),
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
