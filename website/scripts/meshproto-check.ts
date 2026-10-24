// Checks the dashboard's port of the app's BLE mesh wire format (src/meshproto.ts) against the
// behavior of ios/MeshCore (Framing.swift, MeshStore.swift). Run: npx tsx scripts/meshproto-check.ts
import assert from 'node:assert/strict';
import {
  FRAME_HELLO,
  FRAME_POSITION,
  FrameAssembler,
  LinkOutbox,
  PacketStore,
  chunk,
  decodeHello,
  decodePacket,
  encodeFrame,
  encodeHello,
  encodePacket,
  type MeshPacket,
} from '../src/meshproto.ts';

const text = new TextEncoder();
let passed = 0;
const check = (name: string, run: () => void): void => {
  run();
  passed += 1;
  console.log(`ok  ${name}`);
};

check('frame header is [type][u32 big-endian length]', () => {
  const framed = encodeFrame(FRAME_POSITION, text.encode('abc'));
  assert.deepEqual([...framed], [2, 0, 0, 0, 3, 97, 98, 99]);
});

check('assembler joins frames split across arbitrary chunks', () => {
  const a = encodeFrame(FRAME_HELLO, text.encode('{"x":1}'));
  const b = encodeFrame(FRAME_POSITION, text.encode('payload two'));
  const stream = new Uint8Array([...a, ...b]);
  const assembler = new FrameAssembler();
  const frames = chunk(stream, 3).flatMap((part) => assembler.append(part));
  assert.equal(frames.length, 2);
  assert.equal(frames[0].type, FRAME_HELLO);
  assert.equal(new TextDecoder().decode(frames[1].payload), 'payload two');
});

check('type 0 (a version 1 length prefix) and oversize lengths are rejected', () => {
  assert.throws(() => new FrameAssembler().append(new Uint8Array([0, 0, 0, 0, 1, 7])));
  assert.throws(() => new FrameAssembler().append(new Uint8Array([2, 0, 0, 0x10, 1])));
});

check('unknown frame types are skipped without breaking the stream', () => {
  const unknown = encodeFrame(9, text.encode('later'));
  const known = encodeFrame(FRAME_POSITION, text.encode('kept'));
  const frames = new FrameAssembler().append(new Uint8Array([...unknown, ...known]));
  assert.deepEqual(frames.map((f) => f.type), [9, FRAME_POSITION]);
});

check('a stale partial frame expires after the timeout', () => {
  const assembler = new FrameAssembler();
  assembler.append(new Uint8Array([2, 0, 0, 0, 10, 1]), 0);
  assert.equal(assembler.expire(5_000), false);
  assert.equal(assembler.expire(10_001), true);
});

check('hello round trip carries protocol version 3', () => {
  const framed = encodeHello({ frameId: 'hervanta-v1', deviceId: 'dashboard-1234', label: 'Dashboard' });
  const [frame] = new FrameAssembler().append(framed);
  const hello = decodeHello(frame.payload);
  assert.equal(hello.protocolVersion, 3);
  assert.equal(hello.deviceId, 'dashboard-1234');
});

check('outbox keeps one frame per key and its place in line', () => {
  const outbox = new LinkOutbox();
  outbox.enqueue(new Uint8Array([1]), 'a');
  outbox.enqueue(new Uint8Array([2]), 'b');
  outbox.enqueue(new Uint8Array([3]), 'a');
  assert.deepEqual(outbox.take(), { key: 'a', framed: new Uint8Array([3]) });
  assert.equal(outbox.take()?.key, 'b');
  assert.equal(outbox.take(), null);
});

const packet = (sequence: number, extra: Partial<MeshPacket> = {}): MeshPacket => ({
  schemaVersion: 3,
  frameId: 'hervanta-v1',
  hopsRemaining: 4,
  path: [],
  update: {
    id: 'phone-a',
    epochId: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
    sequence,
    role: 'mobile',
    position: { x: 1, y: 0, z: 2 },
    positionMode: 'floor',
  },
  ...extra,
});

check('packets round trip and invalid paths are rejected', () => {
  const [frame] = new FrameAssembler().append(encodePacket(packet(1)));
  assert.equal(decodePacket(frame.payload).update.sequence, 1);
  const bad = text.encode(JSON.stringify(packet(1, { path: ['phone-a'] })));
  assert.throws(() => decodePacket(bad));
});

check('store relays newer reports with one hop fewer and itself on the path', () => {
  const store = new PacketStore('dashboard-1', 'hervanta-v1');
  const relay = store.ingest(packet(5, { path: ['phone-b'] }));
  assert.deepEqual(relay && { hops: relay.hopsRemaining, path: relay.path }, { hops: 3, path: ['phone-b', 'dashboard-1'] });
  assert.equal(store.ingest(packet(5)), undefined, 'duplicate sequence');
  assert.equal(store.ingest(packet(4)), undefined, 'older sequence');
  assert.equal(store.ingest(packet(6, { hopsRemaining: 0 })), null, 'accepted but not relayed');
  assert.equal(store.ingest(packet(7, { path: ['dashboard-1'] })), undefined, 'already passed through us');
  assert.equal(store.ingest(packet(8, { frameId: 'other' })), undefined, 'other frame');
});

check('a retired epoch cannot come back', () => {
  const store = new PacketStore('dashboard-1', 'hervanta-v1');
  store.ingest(packet(10));
  const next = packet(1);
  next.update = { ...next.update, epochId: '11111111-2222-3333-4444-555555555555' };
  assert.notEqual(store.ingest(next), undefined);
  assert.equal(store.ingest(packet(11)), undefined);
});

console.log(`\n${passed} checks passed`);
