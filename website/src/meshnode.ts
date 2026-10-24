// The dashboard as a mesh node: the laptop's Bluetooth (Web Bluetooth, central role) links to
// nearby phones exactly like a phone would, receives their position packets, relays them between
// its phones under the app's rules, and uploads the newest reports to this dashboard, so no
// gateway phone or network is needed near the laptop. Web Bluetooth needs a secure page
// (http://localhost or https) in Chrome or Edge, and the user picks each phone once.

import type { DeviceUpdate } from '../shared/contract.ts';
import {
  CHARACTERISTIC_UUID,
  FRAME_HELLO,
  FRAME_POSITION,
  FrameAssembler,
  LinkOutbox,
  MESH_PROTOCOL_VERSION,
  PacketStore,
  SERVICE_UUID,
  chunk,
  decodeHello,
  decodePacket,
  encodeHello,
  encodePacket,
} from './meshproto.ts';

/** Bytes per write before the link proves it can take more; a longer write than the link's ATT
 * payload becomes a prepared write, which the phone rejects. */
const LARGE_CHUNK = 180;
const SAFE_CHUNK = 20;
const HANDSHAKE_TIMEOUT_MS = 15_000;
const UPLOAD_INTERVAL_MS = 1000;
const NODE_LABEL = 'Dashboard (laptop)';

export type LinkState = 'connecting' | 'linking' | 'ready' | 'reconnecting' | 'closed';

export interface NodeLink {
  key: string;
  name: string;
  state: LinkState;
  deviceId: string | null;
  label: string | null;
  error: string | null;
  received: number;
  relayed: number;
  lastHeard: number | null;
}

interface Link extends NodeLink {
  device: BluetoothDevice;
  characteristic: BluetoothRemoteGATTCharacteristic | null;
  assembler: FrameAssembler;
  outbox: LinkOutbox;
  chunkSize: number;
  writing: boolean;
  subscribed: boolean;
  removed: boolean;
  attempts: number;
  handshakeTimer: number;
}

export interface NodeStats {
  received: number;
  accepted: number;
  duplicates: number;
  relayed: number;
  rejected: number;
  uploaded: number;
  lastUploadAt: number | null;
  uploadError: string | null;
}

export function meshNodeSupport(): { ok: true } | { ok: false; reason: string } {
  if (!('bluetooth' in navigator)) {
    return { ok: false, reason: 'This browser has no Web Bluetooth. Use Chrome or Edge on the laptop.' };
  }
  if (!window.isSecureContext) {
    return {
      ok: false,
      reason: `Web Bluetooth needs a secure page. Open the dashboard on the laptop at http://localhost:${window.location.port || 3000}.`,
    };
  }
  return { ok: true };
}

function stableNodeId(): string {
  try {
    const saved = localStorage.getItem('meshNodeId');
    if (saved) return saved;
  } catch {
    // Storage blocked: a new ID per page load still works, the mesh just sees a new device.
  }
  const id = `dashboard-${crypto.randomUUID().slice(0, 8)}`;
  try {
    localStorage.setItem('meshNodeId', id);
  } catch {
    // Ignore.
  }
  return id;
}

export class MeshNode {
  readonly deviceId = stableNodeId();
  private readonly epochId = crypto.randomUUID().toUpperCase();
  private sequence = 0;
  private frameId: string;
  private store: PacketStore;
  private readonly links = new Map<string, Link>();
  private readonly pending = new Map<string, DeviceUpdate>();
  private uploading = false;
  private readonly timer: number;
  relayEnabled = true;
  readonly stats: NodeStats = {
    received: 0,
    accepted: 0,
    duplicates: 0,
    relayed: 0,
    rejected: 0,
    uploaded: 0,
    lastUploadAt: null,
    uploadError: null,
  };
  onChange: () => void = () => {};

  constructor(frameId: string) {
    this.frameId = frameId;
    this.store = new PacketStore(this.deviceId, frameId);
    this.timer = window.setInterval(() => this.tick(), UPLOAD_INTERVAL_MS);
  }

  get frame(): string {
    return this.frameId;
  }

  get linkList(): NodeLink[] {
    return [...this.links.values()].map(({ key, name, state, deviceId, label, error, received, relayed, lastHeard }) => ({
      key, name, state, deviceId, label, error, received, relayed, lastHeard,
    }));
  }

  /** Changing the frame restarts every link: the Hello carries the frame. */
  setFrame(frameId: string): void {
    if (frameId === this.frameId) return;
    this.frameId = frameId;
    this.store = new PacketStore(this.deviceId, frameId);
    this.pending.clear();
    for (const link of this.links.values()) {
      if (!link.removed) void this.connect(link);
    }
    this.onChange();
  }

  /** Opens the browser's picker for phones running MeshMapper and links to the chosen one. */
  async addPhone(): Promise<void> {
    const device = await navigator.bluetooth.requestDevice({ filters: [{ services: [SERVICE_UUID] }] });
    const existing = this.links.get(device.id);
    if (existing && !existing.removed) {
      if (existing.state === 'closed') void this.connect(existing);
      return;
    }
    const link: Link = {
      key: device.id,
      name: device.name ?? 'Phone',
      state: 'connecting',
      deviceId: null,
      label: null,
      error: null,
      received: 0,
      relayed: 0,
      lastHeard: null,
      device,
      characteristic: null,
      assembler: new FrameAssembler(),
      outbox: new LinkOutbox(),
      chunkSize: LARGE_CHUNK,
      writing: false,
      subscribed: false,
      removed: false,
      attempts: 0,
      handshakeTimer: 0,
    };
    this.links.set(device.id, link);
    device.addEventListener('gattserverdisconnected', () => this.disconnected(link));
    await this.connect(link);
  }

  remove(key: string): void {
    const link = this.links.get(key);
    if (!link) return;
    link.removed = true;
    window.clearTimeout(link.handshakeTimer);
    link.device.gatt?.disconnect();
    this.links.delete(key);
    this.onChange();
  }

  private async connect(link: Link): Promise<void> {
    window.clearTimeout(link.handshakeTimer);
    link.state = link.attempts > 0 ? 'reconnecting' : 'connecting';
    link.error = null;
    link.subscribed = false;
    link.deviceId = null;
    link.assembler.reset();
    link.outbox.clear();
    link.chunkSize = LARGE_CHUNK;
    this.onChange();
    link.handshakeTimer = window.setTimeout(() => {
      if (link.state !== 'ready') this.fail(link, 'The phone did not finish the handshake. Is the mesh running in the app?');
    }, HANDSHAKE_TIMEOUT_MS);
    try {
      const server = await link.device.gatt!.connect();
      const service = await server.getPrimaryService(SERVICE_UUID);
      const characteristic = await service.getCharacteristic(CHARACTERISTIC_UUID);
      link.characteristic = characteristic;
      characteristic.addEventListener('characteristicvaluechanged', () => {
        const value = characteristic.value;
        if (value) this.receive(link, new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
      });
      await characteristic.startNotifications();
      link.subscribed = true;
      link.state = 'linking';
      link.outbox.enqueue(encodeHello({ frameId: this.frameId, deviceId: this.deviceId, label: NODE_LABEL }), 'hello');
      this.onChange();
      void this.pump(link);
    } catch (error) {
      this.fail(link, (error as Error).message);
    }
  }

  private fail(link: Link, reason: string): void {
    link.error = reason;
    link.state = 'closed';
    window.clearTimeout(link.handshakeTimer);
    if (link.device.gatt?.connected) link.device.gatt.disconnect();
    this.onChange();
  }

  private disconnected(link: Link): void {
    window.clearTimeout(link.handshakeTimer);
    const wasReady = link.state === 'ready';
    if (link.removed) return;
    link.subscribed = false;
    link.characteristic = null;
    link.state = 'closed';
    this.onChange();
    // Reconnect with backoff; a phone that left range comes back by itself while the page is open.
    link.attempts = wasReady ? 1 : link.attempts + 1;
    const delay = Math.min(30_000, 2000 * 2 ** Math.min(link.attempts - 1, 4));
    window.setTimeout(() => {
      if (!link.removed && link.state === 'closed') void this.connect(link);
    }, delay);
  }

  private receive(link: Link, bytes: Uint8Array): void {
    let frames;
    try {
      frames = link.assembler.append(bytes);
    } catch {
      this.fail(link, 'Invalid Bluetooth frame. Is the phone on the same app version?');
      return;
    }
    link.lastHeard = Date.now();
    for (const frame of frames) {
      if (frame.type === FRAME_HELLO) this.handleHello(link, frame.payload);
      else if (frame.type === FRAME_POSITION) this.handlePacket(link, frame.payload);
    }
  }

  private handleHello(link: Link, payload: Uint8Array): void {
    let hello;
    try {
      hello = decodeHello(payload);
    } catch {
      this.fail(link, 'Invalid hello from the phone');
      return;
    }
    if (hello.protocolVersion !== MESH_PROTOCOL_VERSION) {
      this.fail(link, `The phone runs mesh protocol ${hello.protocolVersion}; the dashboard speaks ${MESH_PROTOCOL_VERSION}. Update the app or the dashboard.`);
      return;
    }
    if (hello.frameId !== this.frameId) {
      this.fail(link, `The phone uses frame "${hello.frameId}"; this node is set to "${this.frameId}".`);
      return;
    }
    if (hello.deviceId === this.deviceId) {
      this.fail(link, 'The phone reported this node\'s own ID');
      return;
    }
    link.deviceId = hello.deviceId;
    link.label = hello.label ?? null;
    if (link.subscribed && link.state !== 'ready') {
      link.state = 'ready';
      link.attempts = 0;
      window.clearTimeout(link.handshakeTimer);
    }
    this.onChange();
  }

  private handlePacket(link: Link, payload: Uint8Array): void {
    if (link.state !== 'ready') return;
    let packet;
    try {
      packet = decodePacket(payload);
    } catch {
      this.stats.rejected += 1;
      return;
    }
    this.stats.received += 1;
    link.received += 1;
    const relay = this.store.ingest(packet);
    if (relay === undefined) {
      this.stats.duplicates += 1;
      return;
    }
    this.stats.accepted += 1;
    this.pending.set(packet.update.id, packet.update);
    if (!relay || !this.relayEnabled) return;
    // Forward to the other phones this node links, never back along the path.
    const framed = encodePacket(relay);
    for (const other of this.links.values()) {
      if (other === link || other.state !== 'ready' || !other.deviceId) continue;
      if (relay.path.includes(other.deviceId) || relay.update.id === other.deviceId) continue;
      other.outbox.enqueue(framed, relay.update.id);
      other.relayed += 1;
      this.stats.relayed += 1;
      void this.pump(other);
    }
  }

  /** Writes queued frames chunk by chunk, one write at a time, as the phone expects. */
  private async pump(link: Link): Promise<void> {
    if (link.writing) return;
    link.writing = true;
    try {
      for (let next = link.outbox.take(); next && link.characteristic; next = link.outbox.take()) {
        let sent = false;
        while (!sent && link.characteristic) {
          try {
            for (const part of chunk(next.framed, link.chunkSize)) await link.characteristic.writeValueWithResponse(part);
            sent = true;
          } catch (error) {
            if (link.chunkSize > SAFE_CHUNK) {
              // The first chunk was too long for this link; the phone rejected all of it.
              link.chunkSize = SAFE_CHUNK;
              continue;
            }
            throw error;
          }
        }
      }
    } catch (error) {
      this.fail(link, `Write failed: ${(error as Error).message}`);
    } finally {
      link.writing = false;
    }
  }

  /** This node's own report: no position (place it by pinning), its ready links as neighbors. */
  private selfUpdate(now: number): DeviceUpdate {
    const neighbors = [...this.links.values()]
      .filter((link) => link.state === 'ready' && link.deviceId)
      .slice(0, 16)
      .map((link) => ({ id: link.deviceId!, ageMs: link.lastHeard === null ? 0 : Math.max(0, now - link.lastHeard) }));
    const unique = [...new Map(neighbors.map((n) => [n.id, n])).values()];
    this.sequence += 1;
    return {
      id: this.deviceId,
      label: NODE_LABEL,
      epochId: this.epochId,
      sequence: this.sequence,
      role: 'gateway',
      position: { x: 0, y: 0, z: 0 },
      positionMode: 'floor',
      positionSource: 'none',
      neighbors: unique,
    };
  }

  private async tick(): Promise<void> {
    for (const link of this.links.values()) link.assembler.expire();
    const anyLink = [...this.links.values()].some((link) => link.state === 'ready');
    if (this.uploading || (!anyLink && this.pending.size === 0)) return;
    this.uploading = true;
    const sent = [...this.pending.values()];
    const now = Date.now();
    try {
      const response = await fetch('/api/updates', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          schemaVersion: 1,
          gatewayId: this.deviceId,
          frameId: this.frameId,
          units: 'm',
          devices: [...sent, this.selfUpdate(now)].slice(0, 100),
        }),
      });
      if (!response.ok) {
        const body = (await response.json().catch(() => ({}))) as { error?: string };
        throw new Error(body.error ?? `HTTP ${response.status}`);
      }
      // Drop only what was sent; newer reports that arrived meanwhile stay queued.
      for (const update of sent) {
        if (this.pending.get(update.id) === update) this.pending.delete(update.id);
      }
      this.stats.uploaded += sent.length;
      this.stats.lastUploadAt = now;
      this.stats.uploadError = null;
    } catch (error) {
      this.stats.uploadError = (error as Error).message;
    } finally {
      this.uploading = false;
      this.onChange();
    }
  }

  dispose(): void {
    window.clearInterval(this.timer);
    for (const key of [...this.links.keys()]) this.remove(key);
  }
}
