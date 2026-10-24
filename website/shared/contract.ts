export const SCHEMA_VERSION = 1;
export const MAX_BODY_BYTES = 256 * 1024;
export const MAX_DEVICES_PER_BATCH = 100;
export const DEFAULT_FRAME_ID = 'demo-room-v1';
export const DEFAULT_PORT = 3000;

export const GATEWAY_WARN_MS = 5000;
export const DEVICE_FADE_MS = 5000;
export const DEVICE_STALE_MS = 15000;

export const MAX_COORDINATE = 10_000;
export const MAX_TRAIL_POINTS = 120;
export const MAX_TRAIL_AGE_MS = 30_000;

export const MAX_NEIGHBORS_PER_DEVICE = 16;
/** A reported link is drawn until its report (plus its ageMs) is older than this. */
export const LINK_EXPIRE_MS = 10_000;
export const LINK_FADE_MS = 4_000;

export type DeviceRole = 'anchor' | 'mobile' | 'gateway';
export type PositionMode = '3d' | 'floor';
export type SceneMode = 'idle' | 'live' | 'simulated';

export const DEVICE_ROLES: readonly DeviceRole[] = ['anchor', 'mobile', 'gateway'];
export const POSITION_MODES: readonly PositionMode[] = ['3d', 'floor'];

export interface Vec3 {
  x: number;
  y: number;
  z: number;
}

export interface DeviceUpdate {
  id: string;
  label?: string;
  epochId: string;
  sequence: number;
  role: DeviceRole;
  position: Vec3;
  positionMode: PositionMode;
  accuracyMeters?: number;
  measurementAgeMs?: number;
  /** Direct BLE neighbors observed by this phone; relayed reports are not evidence of a link. */
  neighbors?: NeighborObservation[];
}

export interface NeighborObservation {
  id: string;
  rssi?: number;
  ageMs?: number;
}

export interface NeighborSnapshot {
  id: string;
  rssi: number | null;
  ageMs: number | null;
}

export interface UpdateBatch {
  schemaVersion: number;
  gatewayId: string;
  frameId: string;
  units: 'm';
  devices: DeviceUpdate[];
}

export interface TrailPoint extends Vec3 {
  at: number;
}

export interface DeviceSnapshot {
  id: string;
  label: string | null;
  role: DeviceRole;
  epochId: string;
  sequence: number;
  position: Vec3;
  positionMode: PositionMode;
  accuracyMeters: number | null;
  measurementAgeMs: number | null;
  receivedAt: number;
  trail: TrailPoint[];
  neighbors: NeighborSnapshot[];
}

export interface SceneSnapshot {
  schemaVersion: number;
  revision: number;
  serverTime: number;
  mode: SceneMode;
  simulationRunning: boolean;
  frameId: string | null;
  units: 'm';
  gateway: {
    id: string | null;
    lastUploadAt: number | null;
  };
  devices: DeviceSnapshot[];
  stats: {
    accepted: number;
    ignored: number;
    rejected: number;
    batches: number;
  };
  lanUrls: string[];
  uploadPort: number;
  /** Public https origin while `npm run tunnel` is running, else null. */
  publicUrl: string | null;
}
