#!/usr/bin/env node
// Repeatable laptop-side upload check matching the iPhone gateway contract.
// Usage: node scripts/send-sample.mjs [baseUrl]
//        node scripts/send-sample.mjs --duplicate http://192.168.1.20:3000
//        node scripts/send-sample.mjs --stale http://localhost:3000
//        node scripts/send-sample.mjs --frame=demo-room-v1
// The live scene accepts one frame until it is reset, so the default is the phones' default frame
// (hervanta-v1): a sample run must not make the real phones' uploads fail with 409.

const args = process.argv.slice(2);
const flags = new Set(args.filter((arg) => arg.startsWith('--') && !arg.startsWith('--frame=')));
const positional = args.filter((arg) => !arg.startsWith('--'));
const baseUrl = (positional[0] ?? 'http://localhost:3000').replace(/\/+$/, '');

const epochId = 'sample-epoch-1';
const frameId = args.find((arg) => arg.startsWith('--frame='))?.slice('--frame='.length) || 'hervanta-v1';

function batch(sequence, overrides = {}) {
  return {
    schemaVersion: 1,
    gatewayId: 'sample-gateway',
    frameId,
    units: 'm',
    devices: [
      {
        id: 'anchor-north',
        label: 'Anchor North',
        epochId,
        sequence,
        role: 'anchor',
        position: { x: 0, y: 2.2, z: 0 },
        positionMode: '3d',
        accuracyMeters: 0.1,
        neighbors: [{ id: 'phone-4', rssi: -60, ageMs: 250 }],
      },
      {
        id: 'phone-4',
        label: 'Moving phone',
        epochId,
        sequence,
        role: 'mobile',
        position: { x: 2.1, y: 1.2, z: 3.4 },
        positionMode: '3d',
        accuracyMeters: 1.5,
        measurementAgeMs: 350,
        neighbors: [{ id: 'anchor-north', rssi: -61, ageMs: 300 }],
        ...overrides,
      },
    ],
  };
}

async function post(payload) {
  const response = await fetch(`${baseUrl}/api/updates`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const body = await response.json().catch(() => ({}));
  const ok = response.ok;
  console.log(`${ok ? 'OK  ' : 'FAIL'} ${response.status} ${JSON.stringify(body)}`);
  return ok;
}

const health = await fetch(`${baseUrl}/api/health`).then((r) => r.json());
console.log('Health:', JSON.stringify(health));

if (flags.has('--stale')) {
  await post({ ...batch(Date.now() % 1_000_000), schemaVersion: 99 });
  console.log('Sent an intentionally invalid schemaVersion to exercise rejection handling.');
  // A different frame than the scene's: expect 409 (unless the scene is empty, which adopts it).
  await post({ ...batch(Date.now() % 1_000_000), frameId: 'other-frame' });
  process.exit(0);
}

if (flags.has('--duplicate')) {
  const sequence = Date.now() % 1_000_000;
  await post(batch(sequence));
  const ok = await post(batch(sequence));
  console.log(ok ? 'Duplicate delivered; dashboard should report it as ignored.' : 'Duplicate upload failed.');
  process.exit(0);
}

// Three accepted positions 1.5m apart plus one deliberate duplicate.
let sequence = Date.now() % 1_000_000;
for (let step = 0; step < 3; step += 1) {
  await post(batch(sequence, { position: { x: 2 + step * 1.5, y: 1 + step * 0.4, z: 3.4 + step } }));
  sequence += 1;
  await new Promise((resolve) => setTimeout(resolve, 900));
}
await post(batch(sequence - 1));
console.log(`\nOpen ${baseUrl} — expect a moving phone at x=5.00, y=1.80, z=5.40 m (frame ${frameId}).`);
