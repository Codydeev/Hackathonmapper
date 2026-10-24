import {
  DEVICE_ROLES,
  MAX_COORDINATE,
  MAX_DEVICES_PER_BATCH,
  POSITION_MODES,
  SCHEMA_VERSION,
  type DeviceRole,
  type PositionMode,
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
}

export interface NormalizedBatch {
  gatewayId: string;
  frameId: string;
  devices: NormalizedDevice[];
}

export type ValidationResult =
  | { ok: true; batch: NormalizedBatch }
  | { ok: false; error: string };

const FRAME_PATTERN = /^[A-Za-z0-9._-]{1,64}$/;

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

function parseDevice(value: unknown, index: number): NormalizedDevice | string {
  const where = `devices[${index}]`;
  if (!isRecord(value)) return `${where} must be an object`;

  const id = value.id;
  if (!isBoundedString(id, 64)) return `${where}.id must be a non-empty string of at most 64 characters`;

  const epochId = value.epochId;
  if (!isBoundedString(epochId, 64)) {
    return `${where}.epochId must be a non-empty string of at most 64 characters`;
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

  if (!isOptionalMeasure(value.accuracyMeters, 1000)) {
    return `${where}.accuracyMeters must be a number between 0 and 1000`;
  }

  if (!isOptionalMeasure(value.measurementAgeMs, 86_400_000)) {
    return `${where}.measurementAgeMs must be a number between 0 and 86400000`;
  }

  if (value.label !== undefined && value.label !== null) {
    if (typeof value.label !== 'string' || value.label.length > 40) {
      return `${where}.label must be a string of at most 40 characters`;
    }
  }

  const label =
    typeof value.label === 'string' && value.label.trim().length > 0 ? value.label.trim() : null;

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
  };
}

export function validateBatch(input: unknown): ValidationResult {
  if (!isRecord(input)) return { ok: false, error: 'Body must be a JSON object' };

  if (input.schemaVersion !== SCHEMA_VERSION) {
    return { ok: false, error: `schemaVersion must be ${SCHEMA_VERSION}` };
  }

  if (!isBoundedString(input.gatewayId, 64)) {
    return { ok: false, error: 'gatewayId must be a non-empty string of at most 64 characters' };
  }

  if (typeof input.frameId !== 'string' || !FRAME_PATTERN.test(input.frameId)) {
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
