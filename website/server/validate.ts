import {
  DEVICE_ROLES,
  FRAME_ID_PATTERN,
  MAX_ACCURACY_M,
  MAX_AGE_MS,
  MAX_COORDINATE,
  MAX_DEVICES_PER_BATCH,
  MAX_ID_LENGTH,
  MAX_LABEL_LENGTH,
  MAX_NEIGHBORS_PER_DEVICE,
  MAX_RSSI_DBM,
  MAX_UWB_DISTANCE_M,
  MIN_RSSI_DBM,
  POSITION_MODES,
  POSITION_SOURCES,
  SCHEMA_VERSION,
  type DeviceRole,
  type NeighborSnapshot,
  type PositionMode,
  type PositionSource,
  type Vec3,
} from '../shared/contract.ts';

export interface NormalizedDevice {
  id: string;
  label: string | null;
  epochId: string;
  sequence: number;
  role: DeviceRole;
  position: Vec3;
  positionMode: PositionMode;
  accuracyMeters: number | null;
  measurementAgeMs: number | null;
  neighbors: NeighborSnapshot[];
  positionSource: PositionSource;
}

export interface NormalizedBatch {
  gatewayId: string;
  frameId: string;
  devices: NormalizedDevice[];
}

export type ValidationResult =
  | { ok: true; batch: NormalizedBatch }
  | { ok: false; error: string };

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

const isFiniteNumber = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value);

const isBoundedString = (value: unknown, max: number): value is string =>
  typeof value === 'string' && value.trim().length > 0 && value.length <= max;

const isOptionalMeasure = (value: unknown, max: number): value is number | undefined =>
  value === undefined || (isFiniteNumber(value) && value >= 0 && value <= max);

function parsePosition(value: unknown, where: string): Vec3 | string {
  if (!isRecord(value)) return `${where}.position must be an object`;
  const { x, y, z } = value;
  if (!isFiniteNumber(x) || !isFiniteNumber(y) || !isFiniteNumber(z)) {
    return `${where}.position must contain finite x, y, z numbers`;
  }
  if (Math.abs(x) > MAX_COORDINATE || Math.abs(y) > MAX_COORDINATE || Math.abs(z) > MAX_COORDINATE) {
    return `${where}.position coordinates must be within ±${MAX_COORDINATE} m`;
  }
  return { x, y, z };
}

function parseNeighbors(value: unknown, selfId: string, where: string): NeighborSnapshot[] | string {
  if (value === undefined) return [];
  if (!Array.isArray(value)) return `${where}.neighbors must be an array`;
  if (value.length > MAX_NEIGHBORS_PER_DEVICE) {
    return `${where}.neighbors must contain at most ${MAX_NEIGHBORS_PER_DEVICE} entries`;
  }

  const neighbors: NeighborSnapshot[] = [];
  const seen = new Set<string>();
  for (let index = 0; index < value.length; index += 1) {
    const entry = value[index];
    const at = `${where}.neighbors[${index}]`;
    if (!isRecord(entry)) return `${at} must be an object`;
    if (!isBoundedString(entry.id, MAX_ID_LENGTH)) {
      return `${at}.id must be a non-empty string of at most ${MAX_ID_LENGTH} characters`;
    }
    const id = entry.id.trim();
    if (id === selfId) return `${at}.id must not be the reporting device`;
    if (seen.has(id)) return `${at}.id "${id}" is listed twice`;
    seen.add(id);
    if (entry.rssi !== undefined && !(isFiniteNumber(entry.rssi) && entry.rssi >= MIN_RSSI_DBM && entry.rssi <= MAX_RSSI_DBM)) {
      return `${at}.rssi must be a number between ${MIN_RSSI_DBM} and ${MAX_RSSI_DBM} dBm`;
    }
    if (!isOptionalMeasure(entry.ageMs, MAX_AGE_MS)) {
      return `${at}.ageMs must be a number between 0 and ${MAX_AGE_MS}`;
    }
    if (!isOptionalMeasure(entry.uwbDistanceM, MAX_UWB_DISTANCE_M)) {
      return `${at}.uwbDistanceM must be a number between 0 and ${MAX_UWB_DISTANCE_M}`;
    }
    neighbors.push({
      id,
      rssi: typeof entry.rssi === 'number' ? entry.rssi : null,
      ageMs: typeof entry.ageMs === 'number' ? entry.ageMs : null,
      uwbDistanceM: typeof entry.uwbDistanceM === 'number' ? entry.uwbDistanceM : null,
    });
  }
  return neighbors;
}

function parseDevice(value: unknown, index: number): NormalizedDevice | string {
  const where = `devices[${index}]`;
  if (!isRecord(value)) return `${where} must be an object`;

  const id = value.id;
  if (!isBoundedString(id, MAX_ID_LENGTH)) {
    return `${where}.id must be a non-empty string of at most ${MAX_ID_LENGTH} characters`;
  }

  const epochId = value.epochId;
  if (!isBoundedString(epochId, MAX_ID_LENGTH)) {
    return `${where}.epochId must be a non-empty string of at most ${MAX_ID_LENGTH} characters`;
  }

  const sequence = value.sequence;
  if (typeof sequence !== 'number' || !Number.isSafeInteger(sequence) || sequence < 0) {
    return `${where}.sequence must be a non-negative safe integer`;
  }

  const role = value.role;
  if (typeof role !== 'string' || !DEVICE_ROLES.includes(role as DeviceRole)) {
    return `${where}.role must be one of ${DEVICE_ROLES.join(', ')}`;
  }

  const positionMode = value.positionMode;
  if (typeof positionMode !== 'string' || !POSITION_MODES.includes(positionMode as PositionMode)) {
    return `${where}.positionMode must be one of ${POSITION_MODES.join(', ')}`;
  }

  const position = parsePosition(value.position, where);
  if (typeof position === 'string') return position;

  if (positionMode === 'floor' && Math.abs(position.y) > 1e-9) {
    return `${where}.position.y must be 0 when positionMode is "floor"`;
  }

  if (!isOptionalMeasure(value.accuracyMeters, MAX_ACCURACY_M)) {
    return `${where}.accuracyMeters must be a number between 0 and ${MAX_ACCURACY_M}`;
  }

  if (!isOptionalMeasure(value.measurementAgeMs, MAX_AGE_MS)) {
    return `${where}.measurementAgeMs must be a number between 0 and ${MAX_AGE_MS}`;
  }

  if (value.label !== undefined && value.label !== null) {
    if (typeof value.label !== 'string' || value.label.length > MAX_LABEL_LENGTH) {
      return `${where}.label must be a string of at most ${MAX_LABEL_LENGTH} characters`;
    }
  }

  const label =
    typeof value.label === 'string' && value.label.trim().length > 0 ? value.label.trim() : null;

  const neighbors = parseNeighbors(value.neighbors, id.trim(), where);
  if (typeof neighbors === 'string') return neighbors;

  const positionSource = value.positionSource ?? 'manual';
  if (typeof positionSource !== 'string' || !POSITION_SOURCES.includes(positionSource as PositionSource)) {
    return `${where}.positionSource must be one of ${POSITION_SOURCES.join(', ')}`;
  }

  return {
    id: id.trim(),
    label,
    epochId,
    sequence,
    role: role as DeviceRole,
    position,
    positionMode: positionMode as PositionMode,
    accuracyMeters: typeof value.accuracyMeters === 'number' ? value.accuracyMeters : null,
    measurementAgeMs: typeof value.measurementAgeMs === 'number' ? value.measurementAgeMs : null,
    neighbors,
    positionSource: positionSource as PositionSource,
  };
}

export function validateBatch(input: unknown): ValidationResult {
  if (!isRecord(input)) return { ok: false, error: 'Body must be a JSON object' };

  if (input.schemaVersion !== SCHEMA_VERSION) {
    return { ok: false, error: `schemaVersion must be ${SCHEMA_VERSION}` };
  }

  if (!isBoundedString(input.gatewayId, MAX_ID_LENGTH)) {
    return { ok: false, error: `gatewayId must be a non-empty string of at most ${MAX_ID_LENGTH} characters` };
  }

  if (typeof input.frameId !== 'string' || !FRAME_ID_PATTERN.test(input.frameId)) {
    return {
      ok: false,
      error: 'frameId must be 1-64 characters of letters, digits, dot, underscore or dash',
    };
  }

  if (input.units !== 'm') return { ok: false, error: 'units must be "m"' };

  if (!Array.isArray(input.devices)) return { ok: false, error: 'devices must be an array' };

  if (input.devices.length === 0) return { ok: false, error: 'devices must not be empty' };

  if (input.devices.length > MAX_DEVICES_PER_BATCH) {
    return { ok: false, error: `devices must contain at most ${MAX_DEVICES_PER_BATCH} entries` };
  }

  const devices: NormalizedDevice[] = [];
  const seen = new Set<string>();

  for (let index = 0; index < input.devices.length; index += 1) {
    const parsed = parseDevice(input.devices[index], index);
    if (typeof parsed === 'string') return { ok: false, error: parsed };
    if (seen.has(parsed.id)) {
      return { ok: false, error: `Duplicate device id "${parsed.id}" in batch` };
    }
    seen.add(parsed.id);
    devices.push(parsed);
  }

  return {
    ok: true,
    batch: { gatewayId: input.gatewayId.trim(), frameId: input.frameId, devices },
  };
}
