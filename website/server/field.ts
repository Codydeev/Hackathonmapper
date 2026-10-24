import type {
  FieldAnchor,
  FieldAnchorKind,
  FieldLink,
  FieldPhone,
  MapPoint,
  MapSnapshot,
} from '../shared/map.ts';
import type { SceneStore } from './store.ts';

const TICK_MS = 1000;
/** Simulated seconds per real second, so walking speeds read on a site-sized map. */
const TIME_SCALE = 3;
const BLE_RANGE_M = 50;
const TRAIL_POINTS = 40;

const ANCHORS: FieldAnchor[] = [
  { id: 'tower-north', label: 'Tower North', kind: 'cell-tower', position: { x: -250, z: 220 }, rangeMeters: 450 },
  { id: 'tower-east', label: 'Tower East', kind: 'cell-tower', position: { x: 330, z: -40 }, rangeMeters: 420 },
  { id: 'tower-southwest', label: 'Tower South-West', kind: 'cell-tower', position: { x: -300, z: -240 }, rangeMeters: 400 },
  { id: 'ap-depot', label: 'Depot Wi-Fi', kind: 'wifi-ap', position: { x: 40, z: 60 }, rangeMeters: 70 },
  { id: 'ap-gate', label: 'Gate Wi-Fi', kind: 'wifi-ap', position: { x: -120, z: -110 }, rangeMeters: 70 },
  { id: 'beacon-bridge', label: 'Bridge beacon', kind: 'ble-beacon', position: { x: 180, z: 140 }, rangeMeters: 35 },
  { id: 'anchor-alpha', label: 'Anchor Alpha', kind: 'anchor-phone', position: { x: -60, z: 20 }, rangeMeters: BLE_RANGE_M },
  { id: 'anchor-bravo', label: 'Anchor Bravo', kind: 'anchor-phone', position: { x: 110, z: -90 }, rangeMeters: BLE_RANGE_M },
];

interface PhoneRoute {
  id: string;
  label: string;
  role: FieldPhone['role'];
  /** Closed loop of waypoints, walked at `speed` m/s starting `offset` meters in. */
  route: MapPoint[];
  speed: number;
  offset: number;
}

const PHONES: PhoneRoute[] = [
  { id: 'field-gateway', label: 'Gateway Phone', role: 'gateway', route: [{ x: 20, z: 40 }, { x: 45, z: 40 }, { x: 45, z: 70 }, { x: 20, z: 70 }], speed: 0.3, offset: 0 },
  { id: 'field-patrol-1', label: 'Patrol 1', role: 'mobile', route: [{ x: -80, z: 0 }, { x: 60, z: 0 }, { x: 60, z: 80 }, { x: -80, z: 80 }], speed: 1.4, offset: 0 },
  { id: 'field-patrol-2', label: 'Patrol 2', role: 'mobile', route: [{ x: -80, z: 0 }, { x: 60, z: 0 }, { x: 60, z: 80 }, { x: -80, z: 80 }], speed: 1.4, offset: 35 },
  { id: 'field-survey', label: 'Survey', role: 'mobile', route: [{ x: -150, z: -120 }, { x: 100, z: -120 }, { x: 140, z: -60 }, { x: -120, z: -60 }], speed: 1.2, offset: 0 },
  { id: 'field-bridge', label: 'Bridge crew', role: 'mobile', route: [{ x: 120, z: 100 }, { x: 220, z: 160 }, { x: 160, z: 200 }, { x: 90, z: 150 }], speed: 1.0, offset: 0 },
  { id: 'field-scout', label: 'Scout', role: 'mobile', route: [{ x: -350, z: 150 }, { x: -200, z: 250 }, { x: -100, z: 180 }, { x: -250, z: 60 }], speed: 1.6, offset: 0 },
  { id: 'field-vehicle', label: 'Vehicle', role: 'mobile', route: [{ x: -300, z: -200 }, { x: 300, z: -200 }, { x: 300, z: 200 }, { x: -300, z: 200 }], speed: 6, offset: 0 },
];

const distance = (a: MapPoint, b: MapPoint): number => Math.hypot(a.x - b.x, a.z - b.z);

function pointAlong(route: MapPoint[], travelled: number): MapPoint {
  const legs = route.map((from, index) => ({ from, to: route[(index + 1) % route.length] }));
  const perimeter = legs.reduce((sum, leg) => sum + distance(leg.from, leg.to), 0);
  let remaining = ((travelled % perimeter) + perimeter) % perimeter;
  for (const { from, to } of legs) {
    const length = distance(from, to);
    if (remaining <= length) {
      const t = length === 0 ? 0 : remaining / length;
      return { x: from.x + (to.x - from.x) * t, z: from.z + (to.z - from.z) * t };
    }
    remaining -= length;
  }
  return { ...route[0] };
}

/** Simulated accuracy from the best anchors in range; a stand-in for a real solver. */
function simulatedAccuracy(kinds: FieldAnchorKind[]): number | null {
  if (kinds.includes('ble-beacon') || kinds.includes('anchor-phone')) return 3;
  if (kinds.includes('wifi-ap')) return 8;
  const towers = kinds.filter((kind) => kind === 'cell-tower').length;
  if (towers >= 3) return 30;
  if (towers === 2) return 60;
  if (towers === 1) return 150;
  return null;
}

function computeBounds(): MapSnapshot['bounds'] {
  const points = [...ANCHORS.map((anchor) => anchor.position), ...PHONES.flatMap((phone) => phone.route)];
  const pad = 40;
  return {
    minX: Math.min(...points.map((p) => p.x)) - pad,
    maxX: Math.max(...points.map((p) => p.x)) + pad,
    minZ: Math.min(...points.map((p) => p.z)) - pad,
    maxZ: Math.max(...points.map((p) => p.z)) + pad,
  };
}

/**
 * A GNSS-denied field site for the map view: fixed infrastructure anchors plus phones walking
 * looping routes. Runs only while the dashboard is in simulated mode and not paused; it never
 * touches the live or simulated scene state.
 */
export class FieldSimulation {
  private elapsed = 0;
  private trails = new Map<string, MapPoint[]>();
  private readonly bounds = computeBounds();
  private readonly timer: NodeJS.Timeout;

  constructor(private readonly store: SceneStore) {
    this.timer = setInterval(() => this.advance(), TICK_MS);
  }

  private get active(): boolean {
    return this.store.getMode() === 'simulated';
  }

  private advance(): void {
    if (!this.active || !this.store.isSimulationRunning()) return;
    this.elapsed += (TICK_MS / 1000) * TIME_SCALE;
    for (const phone of PHONES) {
      const trail = this.trails.get(phone.id) ?? [];
      trail.push(this.positionOf(phone));
      while (trail.length > TRAIL_POINTS) trail.shift();
      this.trails.set(phone.id, trail);
    }
  }

  private positionOf(phone: PhoneRoute): MapPoint {
    return pointAlong(phone.route, phone.offset + phone.speed * this.elapsed);
  }

  reset(): void {
    this.elapsed = 0;
    this.trails.clear();
  }

  snapshot(now = Date.now()): MapSnapshot {
    const phones: FieldPhone[] = PHONES.map((phone) => {
      const position = this.positionOf(phone);
      const inRange = ANCHORS.filter((anchor) => distance(anchor.position, position) <= anchor.rangeMeters);
      return {
        id: phone.id,
        label: phone.label,
        role: phone.role,
        position,
        accuracyMeters: simulatedAccuracy(inRange.map((anchor) => anchor.kind)),
        anchorsInRange: inRange.map((anchor) => anchor.id),
        trail: (this.trails.get(phone.id) ?? []).map((point) => ({ ...point })),
      };
    });

    // BLE links: phones and anchor phones within radio range of each other.
    const bleNodes = [
      ...phones.map((phone) => ({ id: phone.id, position: phone.position })),
      ...ANCHORS.filter((anchor) => anchor.kind === 'anchor-phone'),
    ];
    const links: FieldLink[] = [];
    for (let i = 0; i < bleNodes.length; i += 1) {
      for (let j = i + 1; j < bleNodes.length; j += 1) {
        const d = distance(bleNodes[i].position, bleNodes[j].position);
        if (d <= BLE_RANGE_M) {
          links.push({ a: bleNodes[i].id, b: bleNodes[j].id, rssi: Math.round(-45 - 20 * Math.log10(Math.max(d, 1))) });
        }
      }
    }

    return {
      serverTime: now,
      active: this.active,
      running: this.store.isSimulationRunning(),
      elapsedSeconds: this.elapsed,
      name: 'Field site (simulated, GNSS denied)',
      bounds: { ...this.bounds },
      anchors: ANCHORS.map((anchor) => ({ ...anchor, position: { ...anchor.position } })),
      phones,
      links,
    };
  }

  dispose(): void {
    clearInterval(this.timer);
  }
}
