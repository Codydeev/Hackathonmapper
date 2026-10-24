/**
 * GhostCore shared contract, TypeScript mirror of
 * ios/MeshCore/Sources/MeshCore/Contract/GhostCoreContract.swift. Keep the two in step: both must
 * accept every file in contract/fixtures/ and refuse every file in contract/fixtures/invalid/ with
 * the same failing field (check: npx tsx scripts/ghostcore-check.ts).
 *
 * Every record carries: `timestamp` (Unix seconds on the producing phone's clock; never subtract two
 * phones' clocks), `frameId` (metres, x east, y up, z north), `source`, a type-specific uncertainty
 * (positions: `r95`, the 95 % horizontal radius), `freshness` and `provenance`.
 *
 * Nothing here is wired into the dashboard upload path yet; DeviceUpdate in contract.ts is unchanged.
 */

import type { PositionSource, Vec3 } from './contract.ts';

export const GHOSTCORE_CONTRACT_VERSION = 1;
export const GHOSTCORE_LIMITS = {
  maxInputs: 16,
  maxContributors: 16,
  maxEvidence: 16,
  maxCandidates: 8,
  maxCloudPoints: 128,
  maxRawSamples: 16,
  maxObservationsPerMessage: 16,
  maxTextLength: 160,
  maxAlgorithmLength: 64,
  maxHorizonSeconds: 3600,
  maxCoordinate: 10_000,
  maxRadius: 10_000,
  maxRelayBytes: 3072,
  maxIdLength: 64,
  maxPathLength: 8,
} as const;

export const EVIDENCE_SOURCES = ['gnss', 'bluetooth', 'uwb', 'inertial', 'manual', 'fusion', 'prediction'] as const;
export type EvidenceSource = (typeof EVIDENCE_SOURCES)[number];

export interface FloorVector {
  x: number;
  z: number;
}

export interface Freshness {
  /** Seconds already elapsed when handed on; each relay adds its hold time. */
  ageAtHandoff: number;
  /** Seconds of age after which the record must not be shown or used as current. */
  maxAge: number;
}

export interface ProvenanceInput {
  source: EvidenceSource;
  id?: string;
  age?: number;
  used: boolean;
  reason?: string;
}

export interface Provenance {
  producerId: string;
  /** "name@version" */
  algorithm: string;
  inputs: ProvenanceInput[];
  /** Producer first, then every device that contributed upstream. */
  contributors: string[];
  gnssDependent: boolean;
  simulated: boolean;
}

export interface FloorCovariance {
  xx: number;
  xz: number;
  zz: number;
}

export interface PositionUncertainty {
  r95: number;
  ambiguous: boolean;
  covariance?: FloorCovariance;
  vertical95?: number;
}

interface RecordBase {
  timestamp: number;
  frameId: string;
  source: EvidenceSource;
  freshness: Freshness;
  provenance: Provenance;
}

export const PEER_CHANNELS = ['connection', 'advertisement'] as const;
export const PEER_LINK_STATES = ['ready', 'connecting', 'advertisementOnly', 'lost'] as const;

export interface PeerObservation extends RecordBase {
  observerId: string;
  peerId?: string;
  channel: (typeof PEER_CHANNELS)[number];
  linkState: (typeof PEER_LINK_STATES)[number];
  rawRSSI: number[];
  window: number;
  smoothedRSSI?: number;
  uncertainty: { stdDevDb?: number; sampleCount: number };
  txPower?: number;
  peerModel?: string;
}

export const POSITION_KINDS = ['measured', 'estimated', 'predicted', 'declared', 'unavailable'] as const;
export const POSITION_METHODS = [
  'gnss', 'uwb', 'multilateration', 'proximity', 'particle', 'deadReckoning', 'fusion', 'manual', 'prediction', 'none',
] as const;
export type PositionKind = (typeof POSITION_KINDS)[number];
export type PositionMethod = (typeof POSITION_METHODS)[number];

export interface PositionEstimate extends RecordBase {
  subjectId: string;
  kind: PositionKind;
  method: PositionMethod;
  position?: Vec3;
  positionMode: 'floor' | '3d';
  uncertainty: PositionUncertainty;
  candidates?: FloorVector[];
  heading?: number;
  headingSigma?: number;
  velocity?: FloorVector;
  lastAbsoluteAt?: number;
}

export const INTEGRITY_STATUSES = ['trusted', 'degraded', 'suspect', 'rejected', 'unavailable', 'insufficientEvidence'] as const;
export const INTEGRITY_REASONS = [
  'noFix', 'staleFix', 'invalidFix', 'timestampInconsistent', 'degradedAccuracy', 'accuracyInconsistent',
  'impossibleSpeed', 'impossibleAcceleration', 'positionJump', 'inertialDisagreement', 'slowDrift',
  'peerDisagreement', 'independentEvidenceDisagreement', 'peerEvidenceNotIndependent', 'insufficientEvidence',
  'continuityLost', 'recovering',
] as const;
export type IntegrityStatus = (typeof INTEGRITY_STATUSES)[number];
export type IntegrityReason = (typeof INTEGRITY_REASONS)[number];

export interface IntegrityEvidence {
  check: string;
  observed?: number;
  threshold?: number;
  unit?: string;
  score: number;
  independent: boolean;
  reason?: IntegrityReason;
}

/** Phone data can show GNSS is inconsistent; it cannot prove spoofing, so there is no such status. */
export interface IntegrityAssessment extends RecordBase {
  subjectId: string;
  status: IntegrityStatus;
  trustScore: number;
  uncertainty: { lower: number; upper: number };
  reasons: IntegrityReason[];
  evidence: IntegrityEvidence[];
  evaluatedFix?: PositionEstimate;
  minimumDetectableOffsetMeters?: number;
  summary?: string;
}

export const MOTION_METHODS = ['pedometer', 'stepDetector', 'deviceMotion', 'visualOdometry'] as const;

export interface MotionObservation extends RecordBase {
  subjectId: string;
  interval: number;
  method: (typeof MOTION_METHODS)[number];
  steps?: number;
  displacement?: FloorVector;
  heading?: number;
  stationary: boolean;
  uncertainty: { displacementR95?: number; headingSigma?: number };
}

export const PREDICTION_METHODS = ['stationary', 'constantVelocity', 'kalman', 'movementModel'] as const;

export interface Prediction extends RecordBase {
  subjectId: string;
  method: (typeof PREDICTION_METHODS)[number];
  lastObservedAt: number;
  lastObservedPosition: Vec3;
  center: Vec3;
  uncertainty: PositionUncertainty;
  /** Local only; never in a RelayMessage. */
  cloud?: FloorVector[];
}

export type RelayPayload =
  | { type: 'position'; position: PositionEstimate }
  | { type: 'integrity'; integrity: IntegrityAssessment }
  | { type: 'prediction'; prediction: Prediction }
  | { type: 'observations'; observations: PeerObservation[] };

/** `source`, uncertainty and `provenance` are the payload's own. */
export interface RelayMessage {
  messageId: string;
  originId: string;
  epochId: string;
  sequence: number;
  timestamp: number;
  frameId: string;
  hopsRemaining: number;
  path: string[];
  freshness: Freshness;
  payload: RelayPayload;
}

export type GhostRecordType =
  | 'PeerObservation' | 'PositionEstimate' | 'IntegrityAssessment' | 'MotionObservation' | 'Prediction' | 'RelayMessage';

export const SIGMA_TO_95 = Math.sqrt(-2 * Math.log(0.05));
const SIGMA_TO_68 = Math.sqrt(-2 * Math.log(0.32));
export const r95FromSigma = (sigma: number): number => sigma * SIGMA_TO_95;
/** iOS horizontalAccuracy is treated as a 68 % radius. */
export const r95FromRadius68 = (radius: number): number => (radius * SIGMA_TO_95) / SIGMA_TO_68;

export function ageOf(freshness: Freshness, receivedAt: number, now: number): number {
  return freshness.ageAtHandoff + Math.max(0, now - receivedAt);
}

export function isStale(freshness: Freshness, receivedAt: number, now: number): boolean {
  return ageOf(freshness, receivedAt, now) > freshness.maxAge;
}

/** Same mapping as PositionEstimate.dashboardSource in Swift. */
export function dashboardSource(estimate: Pick<PositionEstimate, 'kind' | 'method'>): PositionSource {
  if (estimate.kind === 'measured') return estimate.method === 'gnss' ? 'gps' : 'manual';
  return estimate.kind === 'declared' ? 'manual' : 'none';
}

// ---- validation ------------------------------------------------------------------------------
// `validateRecord` returns null for a valid record, 'decode' where Swift's decoder would fail (wrong
// type, missing field, unknown enum value), or the name of the first contract rule that failed,
// matching GhostCoreContractError.invalid(field) in Swift.

class Invalid extends Error {
  constructor(readonly field: string) {
    super(field);
  }
}

function need(condition: boolean, field: string): void {
  if (!condition) throw new Invalid(field);
}

type Json = Record<string, unknown>;
const isObj = (v: unknown): v is Json => typeof v === 'object' && v !== null && !Array.isArray(v);
const num = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);
const opt = (v: unknown, test: (x: unknown) => boolean): boolean => v === undefined || v === null || test(v);
const isIn = (list: readonly string[]) => (v: unknown): boolean => typeof v === 'string' && list.includes(v);
const utf16 = (v: string): number => v.length;
const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

const isId = (v: unknown): boolean => typeof v === 'string' && v.length > 0 && utf16(v) <= GHOSTCORE_LIMITS.maxIdLength && v === v.trim();
export const isFrameId = (v: unknown): boolean => typeof v === 'string' && /^[A-Za-z0-9._-]{1,64}$/.test(v);
const isCoordinate = (v: unknown): boolean => num(v) && Math.abs(v) <= GHOSTCORE_LIMITS.maxCoordinate;
const isRadius = (v: unknown): boolean => num(v) && v >= 0 && v <= GHOSTCORE_LIMITS.maxRadius;
const isText = (v: unknown): boolean => opt(v, (x) => typeof x === 'string' && utf16(x) <= GHOSTCORE_LIMITS.maxTextLength);

/** Shape checks that Swift's Codable performs while decoding. */
function decodable(ok: boolean): asserts ok {
  if (!ok) throw new Invalid('decode');
}

function decodeVec3(v: unknown): void {
  decodable(isObj(v) && num(v.x) && num(v.y) && num(v.z));
}

function decodeFloor(v: unknown): void {
  decodable(isObj(v) && num(v.x) && num(v.z));
}

function checkBase(r: Json, sources: readonly string[] = EVIDENCE_SOURCES): void {
  decodable(num(r.timestamp) && typeof r.frameId === 'string' && isIn(sources)(r.source));
  const f = r.freshness;
  decodable(isObj(f) && num(f.ageAtHandoff) && num(f.maxAge));
  const p = r.provenance;
  decodable(isObj(p) && typeof p.producerId === 'string' && typeof p.algorithm === 'string' && Array.isArray(p.inputs)
    && Array.isArray(p.contributors) && typeof p.gnssDependent === 'boolean' && typeof p.simulated === 'boolean');
  for (const input of p.inputs as unknown[]) {
    decodable(isObj(input) && isIn(EVIDENCE_SOURCES)(input.source) && typeof input.used === 'boolean');
  }
}

function validateBase(r: Json): void {
  need((r.timestamp as number) > 0, 'timestamp');
  need(isFrameId(r.frameId), 'frameId');
  const f = r.freshness as Freshness;
  need(f.ageAtHandoff >= 0, 'freshness.ageAtHandoff');
  need(f.maxAge > 0 && f.maxAge <= 86_400, 'freshness.maxAge');
  const p = r.provenance as Provenance;
  need(isId(p.producerId), 'provenance.producerId');
  need(p.algorithm.length > 0 && utf16(p.algorithm) <= GHOSTCORE_LIMITS.maxAlgorithmLength, 'provenance.algorithm');
  need(p.inputs.length <= GHOSTCORE_LIMITS.maxInputs, 'provenance.inputs');
  for (const input of p.inputs) {
    need(opt(input.id, isId), 'provenance.inputs.id');
    need(opt(input.age, (a) => num(a) && a >= 0), 'provenance.inputs.age');
    need(isText(input.reason), 'provenance.inputs.reason');
  }
  need(p.contributors[0] === p.producerId && p.contributors.length <= GHOSTCORE_LIMITS.maxContributors
    && new Set(p.contributors).size === p.contributors.length && p.contributors.every(isId), 'provenance.contributors');
}

function checkUncertainty(u: unknown): void {
  decodable(isObj(u) && num(u.r95) && typeof u.ambiguous === 'boolean');
  if (isObj(u) && u.covariance != null) {
    const c = u.covariance;
    decodable(isObj(c) && num(c.xx) && num(c.xz) && num(c.zz));
  }
}

function validateUncertainty(u: PositionUncertainty): void {
  need(isRadius(u.r95), 'uncertainty.r95');
  const c = u.covariance;
  need(!c || (c.xx >= 0 && c.zz >= 0 && c.xx * c.zz - c.xz * c.xz >= -1e-9 * Math.max(1, c.xx * c.zz)), 'uncertainty.covariance');
  need(opt(u.vertical95, isRadius), 'uncertainty.vertical95');
}

function peerObservation(r: Json): void {
  checkBase(r);
  decodable(typeof r.observerId === 'string' && opt(r.peerId, (v) => typeof v === 'string')
    && isIn(PEER_CHANNELS)(r.channel) && isIn(PEER_LINK_STATES)(r.linkState)
    && Array.isArray(r.rawRSSI) && r.rawRSSI.every(num) && num(r.window)
    && isObj(r.uncertainty) && Number.isInteger(r.uncertainty.sampleCount));
  validateBase(r);
  const o = r as unknown as PeerObservation;
  const rssi = (v: unknown) => num(v) && v >= -127 && v <= 20;
  need(o.source === 'bluetooth', 'source');
  need(isId(o.observerId) && o.provenance.producerId === o.observerId, 'observerId');
  need(opt(o.peerId, (v) => isId(v) && v !== o.observerId), 'peerId');
  need(o.rawRSSI.length <= GHOSTCORE_LIMITS.maxRawSamples && o.rawRSSI.every(rssi), 'rawRSSI');
  need(o.window >= 0 && o.window <= 60, 'window');
  need(opt(o.smoothedRSSI, rssi), 'smoothedRSSI');
  need(opt(o.uncertainty.stdDevDb, (v) => num(v) && v >= 0 && v <= 60), 'uncertainty.stdDevDb');
  need(o.uncertainty.sampleCount >= o.rawRSSI.length, 'uncertainty.sampleCount');
  need(opt(o.txPower, (v) => Number.isInteger(v) && (v as number) >= -127 && (v as number) <= 20), 'txPower');
  need(opt(o.peerModel, (v) => typeof v === 'string' && v.length > 0 && utf16(v) <= 32), 'peerModel');
}

function positionEstimate(r: Json): void {
  checkBase(r);
  decodable(typeof r.subjectId === 'string' && isIn(POSITION_KINDS)(r.kind) && isIn(POSITION_METHODS)(r.method)
    && isIn(['floor', '3d'])(r.positionMode));
  checkUncertainty(r.uncertainty);
  if (r.position != null) decodeVec3(r.position);
  if (r.velocity != null) decodeFloor(r.velocity);
  if (r.candidates != null) {
    decodable(Array.isArray(r.candidates));
    (r.candidates as unknown[]).forEach(decodeFloor);
  }
  validateBase(r);
  const e = r as unknown as PositionEstimate;
  need(isId(e.subjectId), 'subjectId');
  validateUncertainty(e.uncertainty);
  switch (e.kind) {
    case 'measured':
      need((e.method === 'gnss' || e.method === 'uwb') && e.source === e.method, 'kind.measured');
      break;
    case 'estimated':
      need(['multilateration', 'proximity', 'particle', 'deadReckoning', 'fusion'].includes(e.method)
        && ['bluetooth', 'uwb', 'inertial', 'fusion'].includes(e.source), 'kind.estimated');
      break;
    case 'predicted':
      need(e.method === 'prediction' && e.source === 'prediction', 'kind.predicted');
      break;
    case 'declared':
      need(e.method === 'manual' && e.source === 'manual', 'kind.declared');
      break;
    case 'unavailable':
      need(e.method === 'none' && e.position == null, 'kind.unavailable');
      break;
  }
  if (e.position != null) {
    need([e.position.x, e.position.y, e.position.z].every(isCoordinate), 'position');
    need(e.positionMode === '3d' || e.position.y === 0, 'positionMode');
  } else {
    need(e.kind === 'unavailable', 'position');
  }
  need(e.method !== 'gnss' || e.provenance.gnssDependent, 'provenance.gnssDependent');
  if (e.candidates != null) {
    need(e.uncertainty.ambiguous && e.candidates.length <= GHOSTCORE_LIMITS.maxCandidates
      && e.candidates.every((c) => isCoordinate(c.x) && isCoordinate(c.z)), 'candidates');
  }
  need(opt(e.heading, num), 'heading');
  need(opt(e.headingSigma, (v) => num(v) && v >= 0), 'headingSigma');
  need(opt(e.velocity, (v) => Math.hypot((v as FloorVector).x, (v as FloorVector).z) <= 100), 'velocity');
  need(opt(e.lastAbsoluteAt, (v) => num(v) && v <= e.timestamp + 1), 'lastAbsoluteAt');
}

function integrityAssessment(r: Json): void {
  checkBase(r);
  decodable(typeof r.subjectId === 'string' && isIn(INTEGRITY_STATUSES)(r.status) && num(r.trustScore)
    && isObj(r.uncertainty) && num(r.uncertainty.lower) && num(r.uncertainty.upper)
    && Array.isArray(r.reasons) && r.reasons.every(isIn(INTEGRITY_REASONS)) && Array.isArray(r.evidence));
  for (const item of r.evidence as unknown[]) {
    decodable(isObj(item) && typeof item.check === 'string' && num(item.score) && typeof item.independent === 'boolean'
      && opt(item.reason, isIn(INTEGRITY_REASONS)));
  }
  validateBase(r);
  const a = r as unknown as IntegrityAssessment;
  need(isId(a.subjectId), 'subjectId');
  need(a.trustScore >= 0 && a.trustScore <= 1, 'trustScore');
  need(a.uncertainty.lower >= 0 && a.uncertainty.lower <= a.trustScore && a.trustScore <= a.uncertainty.upper
    && a.uncertainty.upper <= 1, 'uncertainty');
  need(a.reasons.length <= INTEGRITY_REASONS.length && new Set(a.reasons).size === a.reasons.length, 'reasons');
  need(!['suspect', 'rejected', 'degraded'].includes(a.status) || a.reasons.length > 0, 'reasons.required');
  need(a.evidence.length <= GHOSTCORE_LIMITS.maxEvidence, 'evidence');
  for (const item of a.evidence) {
    need(item.check.length > 0 && utf16(item.check) <= 48, 'evidence.check');
    need(item.score >= 0 && item.score <= 1, 'evidence.score');
    need(opt(item.observed, num) && opt(item.threshold, num), 'evidence.value');
    need(opt(item.unit, (v) => typeof v === 'string' && utf16(v) <= 16), 'evidence.unit');
  }
  if (a.evaluatedFix != null) {
    positionEstimate(a.evaluatedFix as unknown as Json);
    need(a.evaluatedFix.method === 'gnss' && a.evaluatedFix.subjectId === a.subjectId
      && a.evaluatedFix.frameId === a.frameId, 'evaluatedFix');
  }
  need(a.status !== 'unavailable' || a.evaluatedFix == null, 'evaluatedFix.unavailable');
  need(opt(a.minimumDetectableOffsetMeters, isRadius), 'minimumDetectableOffsetMeters');
  need(isText(a.summary), 'summary');
}

function motionObservation(r: Json): void {
  checkBase(r);
  decodable(typeof r.subjectId === 'string' && num(r.interval) && isIn(MOTION_METHODS)(r.method)
    && typeof r.stationary === 'boolean' && isObj(r.uncertainty) && opt(r.steps, Number.isInteger));
  if (r.displacement != null) decodeFloor(r.displacement);
  validateBase(r);
  const m = r as unknown as MotionObservation;
  need(isId(m.subjectId), 'subjectId');
  need(m.source === 'inertial' || m.source === 'fusion', 'source');
  need(m.interval > 0 && m.interval <= 60, 'interval');
  need(opt(m.steps, (v) => (v as number) >= 0 && (v as number) <= 1000), 'steps');
  need(opt(m.displacement, (v) => Math.hypot((v as FloorVector).x, (v as FloorVector).z) <= 12 * m.interval), 'displacement');
  need(opt(m.heading, (v) => num(v) && Math.abs(v) <= 2 * Math.PI), 'heading');
  need(!m.stationary || (m.steps ?? 0) === 0, 'stationary');
  need(opt(m.uncertainty.displacementR95, isRadius), 'uncertainty.displacementR95');
  need(opt(m.uncertainty.headingSigma, (v) => num(v) && v >= 0), 'uncertainty.headingSigma');
}

function prediction(r: Json): void {
  checkBase(r);
  decodable(typeof r.subjectId === 'string' && isIn(PREDICTION_METHODS)(r.method) && num(r.lastObservedAt));
  decodeVec3(r.lastObservedPosition);
  decodeVec3(r.center);
  checkUncertainty(r.uncertainty);
  if (r.cloud != null) {
    decodable(Array.isArray(r.cloud));
    (r.cloud as unknown[]).forEach(decodeFloor);
  }
  validateBase(r);
  const p = r as unknown as Prediction;
  const horizon = p.timestamp - p.lastObservedAt;
  need(p.source === 'prediction', 'source');
  need(isId(p.subjectId), 'subjectId');
  need(p.lastObservedAt > 0 && horizon >= 0 && horizon <= GHOSTCORE_LIMITS.maxHorizonSeconds, 'horizon');
  for (const [field, v] of [['lastObservedPosition', p.lastObservedPosition], ['center', p.center]] as const) {
    need([v.x, v.y, v.z].every(isCoordinate), field);
  }
  validateUncertainty(p.uncertainty);
  need(opt(p.cloud, (c) => (c as FloorVector[]).length <= GHOSTCORE_LIMITS.maxCloudPoints
    && (c as FloorVector[]).every((v) => isCoordinate(v.x) && isCoordinate(v.z))), 'cloud');
}

function payloadRecord(payload: RelayPayload): Json | undefined {
  switch (payload.type) {
    case 'position': return payload.position as unknown as Json;
    case 'integrity': return payload.integrity as unknown as Json;
    case 'prediction': return payload.prediction as unknown as Json;
    case 'observations': return payload.observations[0] as unknown as Json | undefined;
  }
}

function relayMessage(r: Json): void {
  decodable(typeof r.messageId === 'string' && typeof r.originId === 'string' && typeof r.epochId === 'string'
    && Number.isInteger(r.sequence) && num(r.timestamp) && typeof r.frameId === 'string'
    && Number.isInteger(r.hopsRemaining) && Array.isArray(r.path) && r.path.every((v) => typeof v === 'string')
    && isObj(r.freshness) && num(r.freshness.ageAtHandoff) && num(r.freshness.maxAge) && isObj(r.payload));
  const payload = r.payload as RelayPayload;
  const decoders: Record<string, (x: Json) => void> = {
    position: positionEstimate, integrity: integrityAssessment, prediction, observations: peerObservation,
  };
  decodable(typeof payload.type === 'string' && payload.type in decoders);
  // Decode the payload's shape first (as Swift does), then validate the envelope, then the payload.
  const body = (payload as unknown as Json)[payload.type];
  const records = payload.type === 'observations' ? (Array.isArray(body) ? body : null) : [body];
  decodable(records !== null && records.every(isObj));
  const decodeOnly = (record: Json, check: (x: Json) => void) => {
    try {
      check(record);
    } catch (error) {
      if (error instanceof Invalid && error.field === 'decode') throw error;
    }
  };
  for (const record of records as Json[]) decodeOnly(record, decoders[payload.type]);
  const m = r as unknown as RelayMessage;
  const first = payloadRecord(payload);
  need((m.timestamp as number) > 0, 'timestamp');
  need(isFrameId(m.frameId), 'frameId');
  need(m.freshness.ageAtHandoff >= 0, 'freshness.ageAtHandoff');
  need(m.freshness.maxAge > 0 && m.freshness.maxAge <= 86_400, 'freshness.maxAge');
  if (first) validateBase({ ...first, timestamp: m.timestamp, frameId: m.frameId, freshness: m.freshness });
  need(UUID.test(m.messageId), 'messageId');
  need(isId(m.originId), 'originId');
  need(UUID.test(m.epochId), 'epochId');
  need(m.sequence >= 0 && m.sequence <= Number.MAX_SAFE_INTEGER, 'sequence');
  need(m.hopsRemaining >= 0 && m.hopsRemaining <= 8, 'hopsRemaining');
  need(m.path.length <= GHOSTCORE_LIMITS.maxPathLength && new Set(m.path).size === m.path.length
    && m.path.every((id) => isId(id) && id !== m.originId), 'path');
  need(first?.frameId === m.frameId, 'payload.frameId');
  need((first?.provenance as Provenance | undefined)?.producerId === m.originId, 'payload.producerId');
  if (payload.type === 'prediction') need(payload.prediction.cloud == null, 'payload.cloud');
  if (payload.type === 'observations') {
    need(payload.observations.length > 0 && payload.observations.length <= GHOSTCORE_LIMITS.maxObservationsPerMessage,
      'payload.observations');
  }
  for (const record of records as Json[]) decoders[payload.type](record);
}

const VALIDATORS: Record<GhostRecordType, (r: Json) => void> = {
  PeerObservation: peerObservation,
  PositionEstimate: positionEstimate,
  IntegrityAssessment: integrityAssessment,
  MotionObservation: motionObservation,
  Prediction: prediction,
  RelayMessage: relayMessage,
};

/** null when valid; otherwise 'decode' or the first failing contract field, as in Swift. */
export function validateRecord(type: GhostRecordType, value: unknown): string | null {
  try {
    decodable(isObj(value));
    VALIDATORS[type](value as Json);
    return null;
  } catch (error) {
    if (error instanceof Invalid) return error.field;
    throw error;
  }
}
