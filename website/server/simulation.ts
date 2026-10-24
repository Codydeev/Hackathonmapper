import { randomUUID } from 'node:crypto';
import { DEFAULT_FRAME_ID } from '../shared/contract.ts';
import type { SceneStore } from './store.ts';
import type { NormalizedBatch, NormalizedDevice } from './validate.ts';

const TICK_MS = 1000;

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
}

/**
 * Generates three fixed anchors and two moving devices. Everything goes through the
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
      });
    }

    if (!this.simulatedGatewayDown) {
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
      });
    }

    if (devices.length === 0) return;

    const batch: NormalizedBatch = {
      gatewayId: this.gateway.id,
      frameId: DEFAULT_FRAME_ID,
      devices,
    };

    this.store.mergeSimulated(batch);
  }
}
