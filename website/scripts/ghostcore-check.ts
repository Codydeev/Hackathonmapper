// Contract check for shared/ghostcore.ts (run: npx tsx scripts/ghostcore-check.ts). Every fixture in
// contract/fixtures/ must validate, and every one in contract/fixtures/invalid/ must fail on the same
// field as ContractTests.swift expects. Exits non-zero on failure.

import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  dashboardSource, isStale, r95FromRadius68, r95FromSigma, validateRecord, type GhostRecordType, type PositionEstimate,
} from '../shared/ghostcore.ts';

const root = join(dirname(fileURLToPath(import.meta.url)), '../../contract/fixtures');
let failures = 0;

function check(ok: boolean, label: string): void {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}`);
  if (!ok) failures += 1;
}

function typeFor(name: string): GhostRecordType {
  const prefix = name.split('-')[0];
  const types: Record<string, GhostRecordType> = {
    peer: 'PeerObservation', position: 'PositionEstimate', integrity: 'IntegrityAssessment',
    motion: 'MotionObservation', prediction: 'Prediction',
  };
  return types[prefix] ?? 'RelayMessage';
}

const valid = readdirSync(root).filter((n) => n.endsWith('.json')).sort();
check(valid.length === 9, `9 valid fixtures (found ${valid.length})`);
for (const name of valid) {
  const result = validateRecord(typeFor(name), JSON.parse(readFileSync(join(root, name), 'utf8')));
  check(result === null, `${name} is valid${result ? ` (failed: ${result})` : ''}`);
}

const invalid = readdirSync(join(root, 'invalid')).filter((n) => n.endsWith('.json')).sort();
check(invalid.length === 10, `10 invalid fixtures (found ${invalid.length})`);
for (const name of invalid) {
  const fixture = JSON.parse(readFileSync(join(root, 'invalid', name), 'utf8')) as {
    type: GhostRecordType; expect: string; record: unknown;
  };
  const result = validateRecord(fixture.type, fixture.record);
  check(result === fixture.expect, `${name} refused on ${fixture.expect} (got ${result})`);
}

const relay = readFileSync(join(root, 'relay-integrity.json'));
check(relay.length > 0 && JSON.stringify(JSON.parse(relay.toString())).length <= 3072, 'relay-integrity fits 3 KiB');
check(Math.abs(r95FromSigma(1) - 2.4477) < 1e-4, 'r95 from sigma');
check(Math.abs(r95FromRadius68(10) - 16.21) < 0.01, 'r95 from a 68 % radius');
check(!isStale({ ageAtHandoff: 2, maxAge: 8 }, 100, 106) && isStale({ ageAtHandoff: 2, maxAge: 8 }, 100, 106.5), 'freshness');
const gnss = JSON.parse(readFileSync(join(root, 'position-gnss-raw.json'), 'utf8')) as PositionEstimate;
const ble = JSON.parse(readFileSync(join(root, 'position-ble-ambiguous.json'), 'utf8')) as PositionEstimate;
check(dashboardSource(gnss) === 'gps' && dashboardSource(ble) === 'none', 'dashboard source mapping');
check(dashboardSource({ kind: 'measured', method: 'uwb' }) === 'uwb' && dashboardSource({ kind: 'declared', method: 'manual' }) === 'manual',
  'dashboard source mapping: measured UWB is uwb (wire v4), declared is manual');

if (failures) {
  console.error(`${failures} check(s) failed`);
  process.exit(1);
}
console.log('ghostcore contract: all checks passed');
