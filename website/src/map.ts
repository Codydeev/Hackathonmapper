import type { FieldAnchor, FieldAnchorKind, FieldPhone, MapPoint, MapSnapshot } from '../shared/map.ts';

export const ANCHOR_COLORS: Record<FieldAnchorKind, string> = {
  'cell-tower': '#f4b942',
  'wifi-ap': '#4dd0e1',
  'ble-beacon': '#7aa7ff',
  'anchor-phone': '#f4b942',
};

export const PHONE_COLORS: Record<FieldPhone['role'], string> = {
  mobile: '#48d597',
  gateway: '#b07cff',
};

const LINK_COLOR = '#e8e8e8';
const NO_FIX_COLOR = '#ff6b6b';
const INTERPOLATION_MS = 900;
const MIN_SCALE = 0.05;
const MAX_SCALE = 40;
const HIT_RADIUS_PX = 16;

export interface MapLayers {
  coverage: boolean;
  links: boolean;
  fixes: boolean;
  trails: boolean;
  labels: boolean;
  grid: boolean;
}

interface Motion {
  from: MapPoint;
  to: MapPoint;
  startAt: number;
}

type SelectHandler = (id: string | null) => void;

function rgba(hex: string, alpha: number): string {
  const value = Number.parseInt(hex.slice(1), 16);
  return `rgba(${(value >> 16) & 255}, ${(value >> 8) & 255}, ${value & 255}, ${alpha})`;
}

/** Picks a 1/2/5 × 10ⁿ step close to `target` meters. */
function niceStep(target: number): number {
  const power = 10 ** Math.floor(Math.log10(target));
  for (const factor of [1, 2, 5, 10]) {
    if (factor * power >= target) return factor * power;
  }
  return 10 * power;
}

const formatMeters = (meters: number): string =>
  meters >= 1000 ? `${meters / 1000} km` : `${meters} m`;

/**
 * Offline top-down map of the simulated field site, drawn on a 2D canvas.
 * World x is east and z is north; screen y grows downward, so z is flipped.
 */
export class MapView {
  private readonly canvas = document.createElement('canvas');
  private readonly ctx: CanvasRenderingContext2D;
  private readonly resizeObserver: ResizeObserver;
  private snapshot: MapSnapshot | null = null;
  private readonly motion = new Map<string, Motion>();
  private readonly layers: MapLayers = {
    coverage: true,
    links: true,
    fixes: true,
    trails: true,
    labels: true,
    grid: true,
  };
  private center: MapPoint = { x: 0, z: 0 };
  private scale = 1;
  private width = 1;
  private height = 1;
  private fitted = false;
  /** Set once the user pans or zooms; until then resizes keep the whole site framed. */
  private userAdjusted = false;
  private visible = false;
  private selectedId: string | null = null;
  private onSelect: SelectHandler = () => {};
  private drag: { x: number; y: number; center: MapPoint; moved: boolean } | null = null;
  private frameHandle = 0;

  constructor(private readonly container: HTMLElement) {
    const ctx = this.canvas.getContext('2d');
    if (!ctx) throw new Error('2D canvas is not available');
    this.ctx = ctx;
    this.canvas.className = 'map-canvas';
    container.prepend(this.canvas);

    this.resizeObserver = new ResizeObserver(() => this.resize());
    this.resizeObserver.observe(container);

    this.canvas.addEventListener('pointerdown', this.handlePointerDown);
    this.canvas.addEventListener('pointermove', this.handlePointerMove);
    this.canvas.addEventListener('pointerup', this.handlePointerUp);
    this.canvas.addEventListener('pointercancel', () => (this.drag = null));
    this.canvas.addEventListener('wheel', this.handleWheel, { passive: false });
  }

  setSelectionHandler(handler: SelectHandler): void {
    this.onSelect = handler;
  }

  setVisible(visible: boolean): void {
    this.visible = visible;
    if (visible) {
      this.resize();
      if (!this.fitted && this.snapshot) this.fit();
      this.requestRender();
    }
  }

  setLayers(layers: Partial<MapLayers>): void {
    Object.assign(this.layers, layers);
    this.requestRender();
  }

  getSelectedId(): string | null {
    return this.selectedId;
  }

  apply(snapshot: MapSnapshot): void {
    const now = performance.now();
    for (const phone of snapshot.phones) {
      const current = this.motion.has(phone.id) ? this.phonePosition(phone.id, now) : phone.position;
      this.motion.set(phone.id, { from: current, to: phone.position, startAt: now });
    }
    for (const id of [...this.motion.keys()]) {
      if (!snapshot.phones.some((phone) => phone.id === id)) this.motion.delete(id);
    }
    this.snapshot = snapshot;
    if (this.selectedId && !this.findItem(this.selectedId)) this.select(null);
    if (!this.fitted && this.visible) this.fit();
    this.requestRender();
  }

  select(id: string | null, centerOn = false): void {
    this.selectedId = id;
    if (id && centerOn) {
      const point = this.itemPosition(id);
      if (point) {
        this.center = { ...point };
        this.userAdjusted = true;
      }
    }
    this.onSelect(id);
    this.requestRender();
  }

  fit(): void {
    if (!this.snapshot) return;
    const { minX, maxX, minZ, maxZ } = this.snapshot.bounds;
    this.center = { x: (minX + maxX) / 2, z: (minZ + maxZ) / 2 };
    const scale = Math.min(this.width / (maxX - minX), this.height / (maxZ - minZ)) * 0.92;
    this.scale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale));
    this.fitted = true;
    this.userAdjusted = false;
    this.requestRender();
  }

  zoom(factor: number, screenX = this.width / 2, screenY = this.height / 2): void {
    this.userAdjusted = true;
    const before = this.toWorld(screenX, screenY);
    this.scale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, this.scale * factor));
    const after = this.toWorld(screenX, screenY);
    this.center = { x: this.center.x + before.x - after.x, z: this.center.z + before.z - after.z };
    this.requestRender();
  }

  private findItem(id: string): FieldAnchor | FieldPhone | undefined {
    return this.snapshot?.anchors.find((a) => a.id === id) ?? this.snapshot?.phones.find((p) => p.id === id);
  }

  private itemPosition(id: string, now = performance.now()): MapPoint | null {
    if (this.motion.has(id)) return this.phonePosition(id, now);
    return this.snapshot?.anchors.find((anchor) => anchor.id === id)?.position ?? null;
  }

  private phonePosition(id: string, now: number): MapPoint {
    const motion = this.motion.get(id);
    if (!motion) return { x: 0, z: 0 };
    const t = Math.min(1, (now - motion.startAt) / INTERPOLATION_MS);
    const eased = 1 - (1 - t) ** 3;
    return {
      x: motion.from.x + (motion.to.x - motion.from.x) * eased,
      z: motion.from.z + (motion.to.z - motion.from.z) * eased,
    };
  }

  private toScreen(point: MapPoint): [number, number] {
    return [
      this.width / 2 + (point.x - this.center.x) * this.scale,
      this.height / 2 - (point.z - this.center.z) * this.scale,
    ];
  }

  private toWorld(screenX: number, screenY: number): MapPoint {
    return {
      x: this.center.x + (screenX - this.width / 2) / this.scale,
      z: this.center.z - (screenY - this.height / 2) / this.scale,
    };
  }

  private resize(): void {
    const rect = this.container.getBoundingClientRect();
    this.width = Math.max(1, rect.width);
    this.height = Math.max(1, rect.height);
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    this.canvas.width = Math.round(this.width * ratio);
    this.canvas.height = Math.round(this.height * ratio);
    this.ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    if (this.fitted && !this.userAdjusted) this.fit();
    this.requestRender();
  }

  private requestRender(): void {
    if (!this.visible || this.frameHandle) return;
    this.frameHandle = requestAnimationFrame(() => {
      this.frameHandle = 0;
      const now = performance.now();
      this.render(now);
      const moving = [...this.motion.values()].some((m) => now - m.startAt < INTERPOLATION_MS);
      if (moving) this.requestRender();
    });
  }

  private render(now: number): void {
    const { ctx } = this;
    ctx.fillStyle = '#000000';
    ctx.fillRect(0, 0, this.width, this.height);
    if (!this.snapshot) return;
    const snapshot = this.snapshot;
    const phonePoints = new Map(snapshot.phones.map((phone) => [phone.id, this.phonePosition(phone.id, now)]));
    const pointOf = (id: string): MapPoint | undefined =>
      phonePoints.get(id) ?? snapshot.anchors.find((anchor) => anchor.id === id)?.position;

    if (this.layers.grid) this.drawGrid();
    if (this.layers.coverage) for (const anchor of snapshot.anchors) this.drawCoverage(anchor);

    if (this.layers.fixes) {
      for (const phone of snapshot.phones) {
        const from = phonePoints.get(phone.id);
        if (!from) continue;
        const emphasized = this.selectedId === phone.id;
        for (const anchorId of phone.anchorsInRange) {
          const anchor = snapshot.anchors.find((entry) => entry.id === anchorId);
          if (anchor) this.drawFix(from, anchor, emphasized);
        }
      }
    }

    if (this.layers.trails) for (const phone of snapshot.phones) this.drawTrail(phone);

    if (this.layers.links) {
      ctx.save();
      ctx.strokeStyle = rgba(LINK_COLOR, 0.75);
      ctx.lineWidth = 1.5;
      for (const link of snapshot.links) {
        const a = pointOf(link.a);
        const b = pointOf(link.b);
        if (!a || !b) continue;
        ctx.beginPath();
        ctx.moveTo(...this.toScreen(a));
        ctx.lineTo(...this.toScreen(b));
        ctx.stroke();
      }
      ctx.restore();
    }

    for (const phone of snapshot.phones) this.drawAccuracy(phone, phonePoints.get(phone.id)!);
    for (const anchor of snapshot.anchors) this.drawAnchor(anchor);
    for (const phone of snapshot.phones) this.drawPhone(phone, phonePoints.get(phone.id)!);

    if (this.layers.labels) {
      for (const anchor of snapshot.anchors) this.drawLabel(anchor.label, anchor.position, ANCHOR_COLORS[anchor.kind]);
      for (const phone of snapshot.phones) {
        const label = phone.accuracyMeters === null ? `${phone.label} · no fix` : phone.label;
        this.drawLabel(label, phonePoints.get(phone.id)!, PHONE_COLORS[phone.role]);
      }
    }

    if (this.selectedId) {
      const point = pointOf(this.selectedId);
      if (point) {
        const [x, y] = this.toScreen(point);
        ctx.save();
        ctx.strokeStyle = '#ffffff';
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.arc(x, y, 17, 0, Math.PI * 2);
        ctx.stroke();
        ctx.restore();
      }
    }

    this.drawScaleBar();
    this.drawNorthArrow();
  }

  private drawGrid(): void {
    const { ctx } = this;
    const step = niceStep(90 / this.scale);
    const topLeft = this.toWorld(0, 0);
    const bottomRight = this.toWorld(this.width, this.height);
    ctx.save();
    ctx.lineWidth = 1;
    for (let x = Math.floor(topLeft.x / step) * step; x <= bottomRight.x; x += step) {
      const [sx] = this.toScreen({ x, z: 0 });
      ctx.strokeStyle = Math.abs(x) < step / 2 ? '#3a3a3a' : '#1a1a1a';
      ctx.beginPath();
      ctx.moveTo(Math.round(sx) + 0.5, 0);
      ctx.lineTo(Math.round(sx) + 0.5, this.height);
      ctx.stroke();
    }
    for (let z = Math.floor(bottomRight.z / step) * step; z <= topLeft.z; z += step) {
      const [, sy] = this.toScreen({ x: 0, z });
      ctx.strokeStyle = Math.abs(z) < step / 2 ? '#3a3a3a' : '#1a1a1a';
      ctx.beginPath();
      ctx.moveTo(0, Math.round(sy) + 0.5);
      ctx.lineTo(this.width, Math.round(sy) + 0.5);
      ctx.stroke();
    }
    ctx.restore();
  }

  private drawCoverage(anchor: FieldAnchor): void {
    const { ctx } = this;
    const [x, y] = this.toScreen(anchor.position);
    const color = ANCHOR_COLORS[anchor.kind];
    ctx.save();
    ctx.beginPath();
    ctx.arc(x, y, anchor.rangeMeters * this.scale, 0, Math.PI * 2);
    ctx.fillStyle = rgba(color, anchor.kind === 'cell-tower' ? 0.025 : 0.05);
    ctx.fill();
    ctx.setLineDash([6, 6]);
    ctx.strokeStyle = rgba(color, 0.3);
    ctx.stroke();
    ctx.restore();
  }

  private drawFix(from: MapPoint, anchor: FieldAnchor, emphasized: boolean): void {
    const { ctx } = this;
    ctx.save();
    ctx.setLineDash([3, 5]);
    ctx.strokeStyle = rgba(ANCHOR_COLORS[anchor.kind], emphasized ? 0.85 : 0.22);
    ctx.lineWidth = emphasized ? 1.5 : 1;
    ctx.beginPath();
    ctx.moveTo(...this.toScreen(from));
    ctx.lineTo(...this.toScreen(anchor.position));
    ctx.stroke();
    ctx.restore();
  }

  private drawTrail(phone: FieldPhone): void {
    if (phone.trail.length < 2) return;
    const { ctx } = this;
    ctx.save();
    ctx.strokeStyle = rgba(PHONE_COLORS[phone.role], 0.35);
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    phone.trail.forEach((point, index) => {
      const [x, y] = this.toScreen(point);
      if (index === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });
    ctx.stroke();
    ctx.restore();
  }

  private drawAccuracy(phone: FieldPhone, point: MapPoint): void {
    const { ctx } = this;
    const [x, y] = this.toScreen(point);
    ctx.save();
    if (phone.accuracyMeters === null) {
      ctx.setLineDash([2, 3]);
      ctx.strokeStyle = rgba(NO_FIX_COLOR, 0.8);
      ctx.beginPath();
      ctx.arc(x, y, 13, 0, Math.PI * 2);
      ctx.stroke();
    } else {
      const radius = Math.max(phone.accuracyMeters * this.scale, 3);
      const color = PHONE_COLORS[phone.role];
      ctx.beginPath();
      ctx.arc(x, y, radius, 0, Math.PI * 2);
      ctx.fillStyle = rgba(color, 0.07);
      ctx.fill();
      ctx.strokeStyle = rgba(color, 0.35);
      ctx.stroke();
    }
    ctx.restore();
  }

  private drawPhoneGlyph(x: number, y: number, color: string): void {
    const { ctx } = this;
    ctx.beginPath();
    ctx.roundRect(x - 5.5, y - 9, 11, 18, 2.5);
    ctx.fillStyle = color;
    ctx.fill();
    ctx.beginPath();
    ctx.roundRect(x - 3.5, y - 6.5, 7, 12, 1);
    ctx.fillStyle = '#050505';
    ctx.fill();
  }

  private drawPhone(phone: FieldPhone, point: MapPoint): void {
    const [x, y] = this.toScreen(point);
    this.ctx.save();
    this.drawPhoneGlyph(x, y, PHONE_COLORS[phone.role]);
    this.ctx.restore();
  }

  private drawAnchor(anchor: FieldAnchor): void {
    const { ctx } = this;
    const [x, y] = this.toScreen(anchor.position);
    const color = ANCHOR_COLORS[anchor.kind];
    ctx.save();
    ctx.strokeStyle = color;
    ctx.fillStyle = color;
    ctx.lineWidth = 1.8;
    ctx.lineCap = 'round';

    switch (anchor.kind) {
      case 'cell-tower': {
        // Lattice mast with radio waves from the top.
        ctx.beginPath();
        ctx.moveTo(x, y - 12);
        ctx.lineTo(x - 7, y + 10);
        ctx.moveTo(x, y - 12);
        ctx.lineTo(x + 7, y + 10);
        ctx.moveTo(x - 4.5, y + 2);
        ctx.lineTo(x + 4.5, y + 2);
        ctx.moveTo(x - 2.5, y - 4);
        ctx.lineTo(x + 2.5, y - 4);
        ctx.stroke();
        for (const radius of [6, 10]) {
          ctx.beginPath();
          ctx.arc(x, y - 12, radius, -Math.PI * 0.85, -Math.PI * 0.15);
          ctx.stroke();
        }
        break;
      }
      case 'wifi-ap': {
        ctx.beginPath();
        ctx.arc(x, y + 6, 2.5, 0, Math.PI * 2);
        ctx.fill();
        for (const radius of [6, 10, 14]) {
          ctx.beginPath();
          ctx.arc(x, y + 6, radius, -Math.PI * 0.78, -Math.PI * 0.22);
          ctx.stroke();
        }
        break;
      }
      case 'ble-beacon': {
        ctx.beginPath();
        ctx.moveTo(x, y - 8);
        ctx.lineTo(x + 7, y);
        ctx.lineTo(x, y + 8);
        ctx.lineTo(x - 7, y);
        ctx.closePath();
        ctx.fill();
        break;
      }
      case 'anchor-phone': {
        ctx.beginPath();
        ctx.arc(x, y, 13, 0, Math.PI * 2);
        ctx.stroke();
        this.drawPhoneGlyph(x, y, color);
        break;
      }
    }
    ctx.restore();
  }

  private drawLabel(text: string, point: MapPoint, color: string): void {
    const { ctx } = this;
    const [x, y] = this.toScreen(point);
    ctx.save();
    ctx.font = '600 11px system-ui, -apple-system, "Segoe UI", sans-serif';
    const width = ctx.measureText(text).width + 12;
    const top = y - 36;
    ctx.beginPath();
    ctx.roundRect(x - width / 2, top, width, 18, 5);
    ctx.fillStyle = 'rgba(0, 0, 0, 0.8)';
    ctx.fill();
    ctx.strokeStyle = rgba(color, 0.55);
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.fillStyle = '#ffffff';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(text, x, top + 9.5);
    ctx.restore();
  }

  private drawScaleBar(): void {
    const { ctx } = this;
    const meters = niceStep(120 / this.scale);
    const length = meters * this.scale;
    const x = 16;
    const y = this.height - 20;
    ctx.save();
    ctx.strokeStyle = '#ffffff';
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(x, y - 5);
    ctx.lineTo(x, y);
    ctx.lineTo(x + length, y);
    ctx.lineTo(x + length, y - 5);
    ctx.stroke();
    ctx.fillStyle = '#ffffff';
    ctx.font = '600 11px system-ui, sans-serif';
    ctx.textBaseline = 'bottom';
    ctx.fillText(formatMeters(meters), x + 4, y - 6);
    ctx.restore();
  }

  private drawNorthArrow(): void {
    const { ctx } = this;
    const x = this.width - 28;
    const y = this.height - 40;
    ctx.save();
    ctx.fillStyle = '#ffffff';
    ctx.beginPath();
    ctx.moveTo(x, y - 12);
    ctx.lineTo(x + 7, y + 6);
    ctx.lineTo(x, y + 2);
    ctx.lineTo(x - 7, y + 6);
    ctx.closePath();
    ctx.fill();
    ctx.font = '700 11px system-ui, sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText('N', x, y + 20);
    ctx.restore();
  }

  private hitTest(screenX: number, screenY: number): string | null {
    if (!this.snapshot) return null;
    const now = performance.now();
    let best: { id: string; distance: number } | null = null;
    const consider = (id: string, point: MapPoint): void => {
      const [x, y] = this.toScreen(point);
      const distance = Math.hypot(x - screenX, y - screenY);
      if (distance <= HIT_RADIUS_PX && (!best || distance < best.distance)) best = { id, distance };
    };
    for (const phone of this.snapshot.phones) consider(phone.id, this.phonePosition(phone.id, now));
    for (const anchor of this.snapshot.anchors) consider(anchor.id, anchor.position);
    return (best as { id: string } | null)?.id ?? null;
  }

  private localPoint(event: PointerEvent | WheelEvent): [number, number] {
    const rect = this.canvas.getBoundingClientRect();
    return [event.clientX - rect.left, event.clientY - rect.top];
  }

  private handlePointerDown = (event: PointerEvent): void => {
    if (event.button !== 0) return;
    this.canvas.setPointerCapture(event.pointerId);
    this.drag = { x: event.clientX, y: event.clientY, center: { ...this.center }, moved: false };
  };

  private handlePointerMove = (event: PointerEvent): void => {
    if (this.drag) {
      const dx = event.clientX - this.drag.x;
      const dy = event.clientY - this.drag.y;
      if (Math.hypot(dx, dy) > 4) this.drag.moved = true;
      if (this.drag.moved) {
        this.userAdjusted = true;
        this.center = { x: this.drag.center.x - dx / this.scale, z: this.drag.center.z + dy / this.scale };
        this.requestRender();
      }
      return;
    }
    const [x, y] = this.localPoint(event);
    this.canvas.style.cursor = this.hitTest(x, y) ? 'pointer' : 'grab';
  };

  private handlePointerUp = (event: PointerEvent): void => {
    const drag = this.drag;
    this.drag = null;
    if (!drag || drag.moved) return;
    const [x, y] = this.localPoint(event);
    this.select(this.hitTest(x, y));
  };

  private handleWheel = (event: WheelEvent): void => {
    event.preventDefault();
    const [x, y] = this.localPoint(event);
    this.zoom(Math.exp(-event.deltaY * 0.0015), x, y);
  };

  dispose(): void {
    cancelAnimationFrame(this.frameHandle);
    this.resizeObserver.disconnect();
    this.canvas.remove();
  }
}
