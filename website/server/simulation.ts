import { randomUUID } from 'node:crypto';
import { DEFAULT_FRAME_ID } from '../shared/contract.ts';
import type { SceneStore } from './store.ts';
import type { NormalizedBatch, NormalizedDevice } from './validate.ts';

/** Five reports per second per phone, like the app (MeshModel.publishInterval). */
const TICK_MS = 200;
const LINK_RANGE_M = 6.5;
const MAX_SIM_NEIGHBORS = 4;

/** Stable per-device value in [-1, 1], so each simulated phone keeps its radio character. */
function deviceBias(id: string, salt: number): number {
  let hash = salt;
  for (const char of id) hash = (Math.imul(hash, 31) + char.charCodeAt(0)) | 0;
  return ((hash >>> 0) % 2001) / 1000 - 1;
}

/**
 * RSSI device `observer` measures from `target`: path loss, plus the target's transmit and the
 * observer's receive gain (phones differ by several dB, so the two directions differ), plus fading.
 */
function simulatedRssi(observer: string, target: string, meters: number): number {
  const transmit = 3 * deviceBias(target, 17);
  const receive = 3 * deviceBias(observer, 29);
  const fading = (Math.random() - 0.5) * 4;
  return Math.round(-45 - 20 * Math.log10(Math.max(meters, 0.5)) + transmit + receive + fading);
}

/**
 * Simulated radio: phones within range link up, each keeping its nearest few neighbors
 * (the app's neighbor budget). A link is reported by both ends only if both kept it.
 */
function assignSimulatedLinks(devices: NormalizedDevice[]): void {
  const distance = (a: NormalizedDevice, b: NormalizedDevice): number =>
    Math.hypot(a.position.x - b.position.x, a.position.y - b.position.y, a.position.z - b.position.z);

  const preferred = new Map<string, Set<string>>();
  for (const device of devices) {
    const nearest = devices
      .filter((other) => other !== device && distance(device, other) <= LINK_RANGE_M)
      .sort((a, b) => distance(device, a) - distance(device, b))
      .slice(0, MAX_SIM_NEIGHBORS);
    preferred.set(device.id, new Set(nearest.map((other) => other.id)));
  }

  for (const device of devices) {
    device.neighbors = devices
      .filter((other) => preferred.get(device.id)?.has(other.id) && preferred.get(other.id)?.has(device.id))
      .map((other) => ({
        id: other.id,
        rssi: Math.max(-127, Math.min(20, simulatedRssi(device.id, other.id, distance(device, other)))),
        ageMs: 200,
      }));
  }
}

interface SimDevice {
  id: string;
  label: string;
  role: NormalizedDevice['role'];
  epochId: string;
  sequence: number;
  base: { x: number; z: number };
  radius: number;
  phase: number;
  height: number;
  heightAmplitude: number;
  positionMode: NormalizedDevice['positionMode'];
  accuracyMeters: number;
  /** Reports no position (positionSource "none"); the dashboard places it from its BLE links. */
  lost?: boolean;
}

/**
 * Generates three fixed anchor phones, two moving phones, and the gateway phone, each
 * reporting its direct BLE neighbors. Everything goes through the
 * same validation-free merge path used by live uploads so the dashboard exercises
 * deduplication, trails, and freshness identically in both modes.
 */
export class SimulationEngine {
  private readonly devices: SimDevice[] = [
    {
      id: 'anchor-north',
      label: 'Anchor North',
      role: 'anchor',
      epochId: randomUUID(),
      sequence: 0,
      base: { x: 0, z: 0 },
      radius: 0,
      phase: 0,
      height: 2.2,
      heightAmplitude: 0,
      positionMode: '3d',
      accuracyMeters: 0.1,
    },
    {
      id: 'anchor-east',
      label: 'Anchor East',
      role: 'anchor',
      epochId: randomUUID(),
      sequence: 0,
      base: { x: 8, z: 0 },
      radius: 0,
      phase: 0,
      height: 2.2,
      heightAmplitude: 0,
      positionMode: '3d',
      accuracyMeters: 0.1,
    },
    {
      id: 'anchor-southwest',
      label: 'Anchor South-West',
      role: 'anchor',
      epochId: randomUUID(),
      sequence: 0,
      base: { x: 1, z: 7 },
      radius: 0,
      phase: 0,
      height: 2.2,
      heightAmplitude: 0,
      positionMode: '3d',
      accuracyMeters: 0.1,
    },
    {
      id: 'phone-mobile-a',
      label: 'Mobile A',
      role: 'mobile',
      epochId: randomUUID(),
      sequence: 0,
      base: { x: 4, z: 3.5 },
      radius: 2.6,
      phase: 0,
      height: 1.3,
      heightAmplitude: 0.55,
      positionMode: '3d',
      accuracyMeters: 0.6,
    },
    {
      id: 'phone-mobile-b',
      label: 'Mobile B',
      role: 'mobile',
      epochId: randomUUID(),
      sequence: 0,
      base: { x: 5.5, z: 5 },
      radius: 1.8,
      phase: Math.PI,
      height: 1.1,
      heightAmplitude: 0,
      positionMode: 'floor',
      accuracyMeters: 1.4,
    },
    {
      id: 'phone-no-gps',
      label: 'No-GPS phone',
      role: 'mobile',
      epochId: randomUUID(),
      sequence: 0,
      base: { x: 3.5, z: 2 },
      radius: 1.6,
      phase: Math.PI / 2,
      height: 0,
      heightAmplitude: 0,
      positionMode: 'floor',
      accuracyMeters: 0,
      lost: true,
    },
  ];

  private gateway: SimDevice = {
    id: 'phone-gateway',
    label: 'Gateway Phone',
    role: 'gateway',
    epochId: randomUUID(),
    sequence: 0,
    base: { x: 0.6, z: 6.4 },
    radius: 0.4,
    phase: Math.PI / 3,
    height: 1.1,
    heightAmplitude: 0.1,
    positionMode: '3d',
    accuracyMeters: 0.4,
  };

  private timer: NodeJS.Timeout | null = null;
  private tick = 0;
  private simulatedStale = false;
  private simulatedGatewayDown = false;

  /** Called after each simulated batch, so browsers get it as fast as a real upload. */
  onAdvance: () => void = () => {};

  constructor(private readonly store: SceneStore) {}

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => this.advance(), TICK_MS);
    this.advance();
  }

  stop(): void {
    if (!this.timer) return;
    clearInterval(this.timer);
    this.timer = null;
  }

  setSimulatedStale(stale: boolean): void {
    this.simulatedStale = stale;
  }

  setSimulatedGatewayDown(down: boolean): void {
    this.simulatedGatewayDown = down;
  }

  reset(): void {
    this.tick = 0;
    this.simulatedStale = false;
    this.simulatedGatewayDown = false;
    for (const device of [...this.devices, this.gateway]) {
      device.epochId = randomUUID();
      device.sequence = 0;
    }
    this.store.resetSimulation();
  }

  dispose(): void {
    this.stop();
  }

  private advance(): void {
    if (!this.store.isSimulationRunning()) return;
    this.tick += 1;

    const elapsed = (this.tick * TICK_MS) / 1000;
    const devices: NormalizedDevice[] = [];

    // A downed gateway uploads nothing, so every phone ages toward stale on the dashboard.
    if (this.simulatedGatewayDown) return;

    for (const device of this.devices) {
      if (this.simulatedStale && device.id === 'phone-mobile-b') continue;

      const angle = device.phase + elapsed * 0.45;
      const x = device.base.x + Math.cos(angle) * device.radius;
      const z = device.base.z + Math.sin(angle) * device.radius;
      const y =
        device.positionMode === 'floor'
          ? 0
          : device.height + Math.sin(elapsed * 1.6 + device.phase) * device.heightAmplitude;

      device.sequence += 1;
      devices.push({
        id: device.id,
        label: device.label,
        epochId: device.epochId,
        sequence: device.sequence,
        role: device.role,
        position: { x, y, z },
        positionMode: device.positionMode,
        accuracyMeters: device.accuracyMeters,
        measurementAgeMs: 120,
        neighbors: [],
        positionSource: 'manual',
      });
    }

    const g = this.gateway;
    g.sequence += 1;
    devices.push({
      id: g.id,
      label: g.label,
      epochId: g.epochId,
      sequence: g.sequence,
      role: g.role,
      position: {
        x: g.base.x + Math.cos(elapsed * 0.2) * g.radius,
        y: g.height + Math.sin(elapsed * 1.1) * g.heightAmplitude,
        z: g.base.z + Math.sin(elapsed * 0.2) * g.radius,
      },
      positionMode: '3d',
      accuracyMeters: g.accuracyMeters,
      measurementAgeMs: 90,
      neighbors: [],
      positionSource: 'manual',
    });

    // Links come from true positions; a lost phone then reports only a placeholder position.
    assignSimulatedLinks(devices);
    for (const device of devices) {
      if (!this.devices.find((d) => d.id === device.id)?.lost) continue;
      device.position = { x: 0, y: 0, z: 0 };
      device.accuracyMeters = null;
      device.positionSource = 'none';
    }

    const batch: NormalizedBatch = {
      gatewayId: this.gateway.id,
      frameId: DEFAULT_FRAME_ID,
      devices,
    };

    this.store.mergeSimulated(batch);

    this.onAdvance();
  }
}
