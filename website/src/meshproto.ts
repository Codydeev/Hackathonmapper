// The iPhone app's BLE mesh wire format, ported for the dashboard's own mesh node.
// Mirrors ios/MeshCore (Framing.swift, Models.swift `Hello`/`MeshPacket`, MeshStore.swift relay
// rules) and MeshProtocol.version; a wire change in the app must be made here too.

import type { DeviceUpdate } from '../shared/contract.ts';

/** v4 added the uwb/fused position sources and relay frame types 5-7 (skipped here, like v3 phones do). */
export const MESH_PROTOCOL_VERSION = 4;
export const MAX_PATH_LENGTH = 8;
export const SERVICE_UUID = 'f7a40001-5ab1-4e90-a989-21b5e52e2210';
export const CHARACTERISTIC_UUID = 'f7a40002-5ab1-4e90-a989-21b5e52e2210';

export const FRAME_HELLO = 1;
export const FRAME_POSITION = 2;
const HEADER_LENGTH = 5;
const MAX_PAYLOAD = 4_096;
const MAX_BUFFERED = 8_192;
const MAX_HELLO_BYTES = 512;
/** A partial frame older than this is dropped, so a lost chunk cannot wedge the link. */
export const FRAME_TIMEOUT_MS = 10_000;

export interface Frame {
  type: number;
  payload: Uint8Array;
}

/** `[type: u8][length: u32 big-endian][payload]` */
export function encodeFrame(type: number, payload: Uint8Array): Uint8Array {
  if (payload.length < 1 || payload.length > MAX_PAYLOAD) throw new Error('frame payload size');
  const framed = new Uint8Array(HEADER_LENGTH + payload.length);
  framed[0] = type;
  new DataView(framed.buffer).setUint32(1, payload.length, false);
  framed.set(payload, HEADER_LENGTH);
  return framed;
}

/** Reassembles frames from one link's chunks (the app's `FrameAssembler`). */
export class FrameAssembler {
  private buffer = new Uint8Array(0);
  private updatedAt: number | null = null;

  /** Returns the frames completed by `chunk`; throws on malformed input and clears the buffer. */
  append(chunk: Uint8Array, now = Date.now()): Frame[] {
    const merged = new Uint8Array(this.buffer.length + chunk.length);
    merged.set(this.buffer);
    merged.set(chunk, this.buffer.length);
    this.buffer = merged;
    if (this.buffer.length > MAX_BUFFERED) {
      this.reset();
      throw new Error('frame buffer overflow');
    }
    const frames: Frame[] = [];
    while (this.buffer.length >= HEADER_LENGTH) {
      const length = new DataView(this.buffer.buffer, this.buffer.byteOffset).getUint32(1, false);
      // Type 0 is how a version 1 length prefix starts, so it is never valid.
      if (this.buffer[0] === 0 || length < 1 || length > MAX_PAYLOAD) {
        this.reset();
        throw new Error('invalid frame header');
      }
      if (this.buffer.length < HEADER_LENGTH + length) break;
      // Unknown types are skipped, like the app does.
      frames.push({ type: this.buffer[0], payload: this.buffer.slice(HEADER_LENGTH, HEADER_LENGTH + length) });
      this.buffer = this.buffer.slice(HEADER_LENGTH + length);
    }
    this.updatedAt = this.buffer.length === 0 ? null : now;
    return frames;
  }

  expire(now = Date.now()): boolean {
    if (this.updatedAt === null || now - this.updatedAt <= FRAME_TIMEOUT_MS) return false;
    this.reset();
    return true;
  }

  reset(): void {
    this.buffer = new Uint8Array(0);
    this.updatedAt = null;
  }
}

/**
 * Outgoing queue for one link (the app's `LinkOutbox`): at most one pending frame per key, so a
 * slow link only delivers the latest report per origin. The caller writes a taken frame's chunks
 * in order before taking the next, so frames are never interleaved.
 */
export class LinkOutbox {
  private readonly pending = new Map<string, Uint8Array>();

  enqueue(framed: Uint8Array, key: string): void {
    // Map keeps insertion order; replacing a value keeps its place in line, as in the app.
    this.pending.set(key, framed);
  }

  take(): { key: string; framed: Uint8Array } | null {
    const next = this.pending.entries().next();
    if (next.done) return null;
    const [key, framed] = next.value;
    this.pending.delete(key);
    return { key, framed };
  }

  clear(): void {
    this.pending.clear();
  }

  get size(): number {
    return this.pending.size;
  }
}

/** Write-sized pieces; fresh copies, so each is backed by its own ArrayBuffer as Web Bluetooth needs. */
export function chunk(framed: Uint8Array, size: number): Uint8Array<ArrayBuffer>[] {
  const chunks: Uint8Array<ArrayBuffer>[] = [];
  for (let start = 0; start < framed.length; start += Math.max(1, size)) chunks.push(framed.slice(start, start + size));
  return chunks;
}

export interface Hello {
  protocolVersion: number;
  frameId: string;
  deviceId: string;
  label?: string | null;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const isId = (value: unknown): value is string =>
  typeof value === 'string' && value.length > 0 && value.length <= 64 && value === value.trim();

export function encodeHello(hello: Omit<Hello, 'protocolVersion'>): Uint8Array {
  const payload = encoder.encode(JSON.stringify({ protocolVersion: MESH_PROTOCOL_VERSION, ...hello }));
  if (payload.length > MAX_HELLO_BYTES) throw new Error('hello too large');
  return encodeFrame(FRAME_HELLO, payload);
}

export function decodeHello(payload: Uint8Array): Hello {
  if (payload.length > MAX_HELLO_BYTES) throw new Error('hello too large');
  const hello = JSON.parse(decoder.decode(payload)) as Hello;
  if (typeof hello.protocolVersion !== 'number' || typeof hello.frameId !== 'string' || !isId(hello.deviceId)) {
    throw new Error('invalid hello');
  }
  return hello;
}

export interface MeshPacket {
  schemaVersion: number;
  frameId: string;
  hopsRemaining: number;
  path: string[];
  update: DeviceUpdate;
}

/** Decodes and checks a position packet like `MeshPacket.decode` (the server validates the update). */
export function decodePacket(payload: Uint8Array): MeshPacket {
  if (payload.length > MAX_PAYLOAD) throw new Error('packet too large');
  const packet = JSON.parse(decoder.decode(payload)) as MeshPacket;
  const seen = new Set<string>();
  const pathValid =
    Array.isArray(packet.path) &&
    packet.path.length <= MAX_PATH_LENGTH &&
    packet.path.every((id) => isId(id) && id !== packet.update?.id && !seen.has(id) && seen.add(id));
  if (
    packet.schemaVersion !== MESH_PROTOCOL_VERSION ||
    typeof packet.frameId !== 'string' ||
    !Number.isInteger(packet.hopsRemaining) ||
    packet.hopsRemaining < 0 ||
    packet.hopsRemaining > 8 ||
    !pathValid ||
    !isId(packet.update?.id) ||
    typeof packet.update.epochId !== 'string' ||
    !Number.isSafeInteger(packet.update.sequence)
  ) {
    throw new Error('invalid packet');
  }
  return packet;
}

export const encodePacket = (packet: MeshPacket): Uint8Array =>
  encodeFrame(FRAME_POSITION, encoder.encode(JSON.stringify(packet)));

/**
 * Newest report per origin with the app's epoch/sequence rules (MeshStore.ingest). Returns the
 * packet to relay (one hop fewer, this node appended to the path), `null` when nothing should be
 * relayed, or `undefined` for a duplicate or older report.
 */
export class PacketStore {
  readonly latest = new Map<string, DeviceUpdate>();
  private readonly epochs = new Map<string, Set<string>>();

  constructor(
    private readonly selfId: string,
    private readonly frameId: string,
  ) {}

  ingest(packet: MeshPacket): MeshPacket | null | undefined {
    if (packet.frameId !== this.frameId) return undefined;
    // This copy already passed through this node, or it is our own report coming back.
    if (packet.path.includes(this.selfId) || packet.update.id === this.selfId) return undefined;
    const update = packet.update;
    const epoch = update.epochId.toUpperCase();
    const known = this.epochs.get(update.id) ?? new Set<string>();
    const previous = this.latest.get(update.id);
    if (previous) {
      if (previous.epochId.toUpperCase() === epoch) {
        if (update.sequence <= previous.sequence) return undefined;
      } else if (known.has(epoch)) {
        return undefined;
      }
    }
    known.add(epoch);
    this.epochs.set(update.id, known);
    this.latest.set(update.id, update);
    const path = [...packet.path, this.selfId];
    if (packet.hopsRemaining <= 0 || path.length > MAX_PATH_LENGTH) return null;
    return { ...packet, hopsRemaining: packet.hopsRemaining - 1, path };
  }
}
