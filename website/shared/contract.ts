export const SCHEMA_VERSION = 1;
export const MAX_BODY_BYTES = 256 * 1024;
export const MAX_DEVICES_PER_BATCH = 100;
export const DEFAULT_FRAME_ID = 'demo-room-v1';
export const DEFAULT_PORT = 3000;

export const GATEWAY_WARN_MS = 5000;
export const DEVICE_FADE_MS = 5000;
export const DEVICE_STALE_MS = 15000;

// Upload limits, mirrored by `DashboardContract` in MeshCore (Models.swift): one device breaking
// them makes validate.ts reject the whole batch, so the app checks the same values first.
/** Device, epoch, gateway and neighbor ids: non-empty after trimming, at most this many characters. */
export const MAX_ID_LENGTH = 64;
export const MAX_LABEL_LENGTH = 40;
export const MAX_ACCURACY_M = 1000;
/** Upper bound for `ageMs` and `measurementAgeMs` (one day). */
export const MAX_AGE_MS = 86_400_000;
export const MIN_RSSI_DBM = -127;
export const MAX_RSSI_DBM = 20;
/** Frame ids, as the app checks them before starting the mesh. */
export const FRAME_ID_PATTERN = /^[A-Za-z0-9._-]{1,64}$/;

export const MAX_COORDINATE = 10_000;
export const MAX_TRAIL_POINTS = 120;
export const MAX_TRAIL_AGE_MS = 30_000;
/** A trail gets a new point (at most one per second) only when the phone moved at least this far. */
export const TRAIL_MIN_STEP_M = 0.05;

export const MAX_NEIGHBORS_PER_DEVICE = 16;
/** Upper bound for a reported UWB distance; Nearby Interaction measures far less in practice. Mirrors `DashboardContract.maxUWBDistanceMeters`. */
export const MAX_UWB_DISTANCE_M = 200;
/** A reported link is drawn until its report (plus its ageMs) is older than this. */
export const LINK_EXPIRE_MS = 10_000;
export const LINK_FADE_MS = 4_000;

export type DeviceRole = 'anchor' | 'mobile' | 'gateway';
export type PositionMode = '3d' | 'floor';
export type SceneMode = 'idle' | 'live' | 'simulated';

/**
 * Where a reported position came from. `none`: the phone does not know where it is; its position
 * is a placeholder and the dashboard places it from its Bluetooth links (see DeviceSnapshot.estimate).
 * `uwb`: measured by a mounted UWB direction anchor. `fused`: dead reckoning corrected by RSSI to BLE
 * anchors, with the filter's own accuracy.
 * Absent in uploads from older app builds, which means `manual`.
 */
export type PositionSource = 'gps' | 'manual' | 'none' | 'uwb' | 'fused';

export const DEVICE_ROLES: readonly DeviceRole[] = ['anchor', 'mobile', 'gateway'];
export const POSITION_MODES: readonly PositionMode[] = ['3d', 'floor'];
export const POSITION_SOURCES: readonly PositionSource[] = ['gps', 'manual', 'none', 'uwb', 'fused'];

/**
 * Bluetooth links older than this (report age plus ageMs) are not used to place phones. Reports can
 * spend a few seconds relaying through the mesh; the app uses the same limit (`SignalMap.linkMaxAge`).
 */
export const ESTIMATE_LINK_MAX_AGE_MS = 6_000;

/**
 * Log-distance radio model: RSSI = p0 - 10 n log10(d). The single model for every RSSI distance,
 * mirrored by `RadioModel` in MeshCore. Keep the two identical.
 */
export interface RadioModel {
  /** dBm received at 1 m. */
  p0: number;
  /** Path-loss exponent. */
  n: number;
  /** dB spread of a smoothed RSSI reading, including phone-model differences. */
  sigma: number;
  /** m at which half of the one-second windows still hear the phone. */
  range: number;
  /** m over which reception fades out. */
  soft: number;
}

/** Real phones. Short-range distances from it were checked to about a meter on the Track tab. */
export const RADIO_MODEL: RadioModel = { p0: -59, n: 2.5, sigma: 5, range: 60, soft: 8 };
/** The simulator's radio (RSSI = -45 - 20 log10 d); used only in simulated mode. */
export const SIMULATED_RADIO_MODEL: RadioModel = { p0: -45, n: 2, sigma: 3, range: 6.5, soft: 0.8 };

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
  /**
   * Radius around `position` holding the true position 95 % of the time, meters. Every source
   * converts to this at the phone (GPS's ~68 % radius × 1.62, the fused filter's 1-sigma radial
   * error × 1.73), so circles from different sources compare.
   */
  accuracyMeters?: number;
  measurementAgeMs?: number;
  /** Direct BLE neighbors observed by this phone; relayed reports are not evidence of a link. */
  neighbors?: NeighborObservation[];
  positionSource?: PositionSource;
}

export interface NeighborObservation {
  id: string;
  rssi?: number;
  ageMs?: number;
  /**
   * The reporter's own fresh UWB (Nearby Interaction) distance to `id` in meters, 0 to
   * MAX_UWB_DISTANCE_M, rounded to 0.01 m. Sent by app builds on mesh protocol 5 and later.
   */
  uwbDistanceM?: number;
}

export interface NeighborSnapshot {
  id: string;
  rssi: number | null;
  ageMs: number | null;
  uwbDistanceM: number | null;
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
  /** 95 % radius, meters (see DeviceUpdate.accuracyMeters). */
  accuracyMeters: number | null;
  measurementAgeMs: number | null;
  receivedAt: number;
  trail: TrailPoint[];
  neighbors: NeighborSnapshot[];
  positionSource: PositionSource;
  /** Pinned as an anchor on the dashboard: `role` is "anchor" and `position` is the pin. */
  pinned: boolean;
  /** What the phone itself reported while the dashboard overrides it (pinned); else null. */
  reported: { role: DeviceRole; position: Vec3; positionSource: PositionSource } | null;
  /**
   * An anchor whose GPS was lost (it now reports no position) is assumed not to have moved: it is
   * drawn and used for placement at its last GPS fix, from `since` (server time of that fix).
   */
  gpsHold: { since: number; accuracyMeters: number | null } | null;
  /**
   * For `positionSource: "none"`: where the dashboard places the phone from Bluetooth RSSI.
   * When present, `position` and `accuracyMeters` already hold this estimate (r95), so views that
   * only draw positions show it; null until the phone has a link to a placed phone.
   */
  estimate: BluetoothEstimate | null;
  /**
   * The position the phone reported, when `position` was moved to agree with the signal map
   * (a phone in a group with two or more placed phones); null otherwise.
   */
  reportedPosition: Vec3 | null;
  /** This phone in the signal map; null when its report is stale. */
  signal: SignalSnapshot | null;
}

/**
 * A phone in the signal map: a layout whose distances match the Bluetooth ranges. In a "world"
 * group the layout is in the shared frame; in a "pinned" or "relative" group only distances count.
 */
export interface SignalSnapshot {
  x: number;
  z: number;
  /** 95 % radius; for a ring, around `ringCenter`. */
  r95: number;
  frame: 'world' | 'pinned' | 'relative';
  /** Connected group, numbered by each group's smallest id. */
  component: number;
  /** False when the phone has neither a link nor a position of its own. */
  placed: boolean;
  /** Direction unknown: somewhere on a ring of `ringRadius` around this phone. */
  ringCenter: string | null;
  ringRadius: number | null;
}

/** A Bluetooth link in the signal map: the measured range and the layout's distance. */
export interface SignalLinkSnapshot {
  a: string;
  b: string;
  rssi: number;
  /** Mean UWB distance from the ends that measured one, m; null for an RSSI-only link. */
  uwb: number | null;
  /** The UWB distance when there is one, else the range from RSSI, m. */
  measured: number;
  /** One-sigma error of `measured`. */
  sigma: number;
  layout: number;
}

export interface BluetoothEstimate {
  /** Radius holding 95 % of the belief, meters. */
  r95: number;
  /** Ring or two separate spots: the centre is not a good guess. */
  ambiguous: boolean;
  /** Bluetooth hops to the nearest phone with a position; null when not connected to one. */
  hops: number | null;
  /** Sample of the belief cloud on the floor plane, for drawing. */
  cloud: { x: number; z: number }[];
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
    /** Last health check with the gateway token: the phone can reach the dashboard. */
    lastCheckAt: number | null;
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
  signalMap: {
    links: SignalLinkSnapshot[];
    /** Radio model after calibration from links between precisely placed phones. */
    radio: RadioModel;
  };
}
