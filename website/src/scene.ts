import * as THREE from 'three';
import { CSS2DObject, CSS2DRenderer } from 'three/addons/renderers/CSS2DRenderer.js';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import {
  DEVICE_FADE_MS,
  DEVICE_STALE_MS,
  LINK_EXPIRE_MS,
  LINK_FADE_MS,
  type DeviceSnapshot,
  type SceneSnapshot,
} from '../shared/contract.ts';

const ROLE_COLORS: Record<DeviceSnapshot['role'], number> = {
  anchor: 0xf4b942,
  gateway: 0xb07cff,
  mobile: 0x48d597,
};

const STALE_COLOR = 0x8a8a8a;
const LINK_COLOR = 0xe8e8e8;
const INTERPOLATION_MS = 700;
const HIT_SCALE = 0.75;
const MAX_LINK_SEGMENTS = 512;

// Every node is a phone; role only changes color and the anchor halo. Shared across visuals.
const PHONE_DEPTH = 0.08;
const PHONE_GEOMETRY = new RoundedBoxGeometry(0.42, 0.78, PHONE_DEPTH, 3, 0.06);
const SCREEN_GEOMETRY = new THREE.PlaneGeometry(0.35, 0.66);
const SCREEN_MATERIAL = new THREE.MeshBasicMaterial({ color: 0x050505, side: THREE.DoubleSide });
const HALO_GEOMETRY = new THREE.TorusGeometry(0.56, 0.024, 8, 48);

interface SceneLink {
  a: DeviceVisual;
  b: DeviceVisual;
  fresh: boolean;
}

function convexHull(points: THREE.Vector2[]): THREE.Vector2[] {
  const sorted = [...points].sort((p, q) => p.x - q.x || p.y - q.y);
  if (sorted.length < 3) return sorted;
  const cross = (o: THREE.Vector2, a: THREE.Vector2, b: THREE.Vector2): number =>
    (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  const half = (input: THREE.Vector2[]): THREE.Vector2[] => {
    const hull: THREE.Vector2[] = [];
    for (const point of input) {
      while (hull.length >= 2 && cross(hull[hull.length - 2], hull[hull.length - 1], point) <= 0) hull.pop();
      hull.push(point);
    }
    hull.pop();
    return hull;
  };
  return [...half(sorted), ...half([...sorted].reverse())];
}

interface DeviceVisual {
  group: THREE.Group;
  body: THREE.Mesh;
  halo: THREE.Mesh | null;
  hitbox: THREE.Mesh;
  stem: THREE.Mesh;
  accuracy: THREE.Mesh;
  trail: THREE.Line;
  trailPositions: Float32Array;
  label: CSS2DObject | null;
  labelEl: HTMLDivElement;
  marker: THREE.Mesh;
  markerMat: THREE.MeshBasicMaterial;
  current: THREE.Vector3;
  target: THREE.Vector3;
  targetAt: number;
  startAt: number;
  from: THREE.Vector3;
  role: DeviceSnapshot['role'];
  positionMode: DeviceSnapshot['positionMode'];
  stale: boolean;
  receivedAt: number;
  lastTrailRevision: number;
}

export interface SceneOptions {
  snapToFloor?: boolean;
}

export interface DisplayToggles {
  labels: boolean;
  trails: boolean;
  uncertainty: boolean;
  grid: boolean;
  stems: boolean;
  links: boolean;
}

type SelectHandler = (deviceId: string | null) => void;

const tmpVec = new THREE.Vector3();

export class SceneView {
  private readonly renderer: THREE.WebGLRenderer;
  private readonly labelRenderer: CSS2DRenderer;
  private readonly scene = new THREE.Scene();
  private readonly camera: THREE.PerspectiveCamera;
  private readonly controls: OrbitControls;
  private readonly raycaster = new THREE.Raycaster();
  private readonly pointer = new THREE.Vector2();
  private readonly visuals = new Map<string, DeviceVisual>();
  private readonly hitboxes: THREE.Mesh[] = [];
  private readonly gridGroup = new THREE.Group();
  private readonly trailsRoot = new THREE.Group();
  private readonly stemsRoot = new THREE.Group();
  private readonly accuracyRoot = new THREE.Group();
  private readonly anchorArea = new THREE.Group();
  private readonly linksRoot = new THREE.Group();
  private readonly linkFresh = SceneView.makeLinkLines(0.8);
  private readonly linkAging = SceneView.makeLinkLines(0.22);
  private links: SceneLink[] = [];
  private readonly clock = new THREE.Clock();
  private readonly container: HTMLElement;
  private readonly toggles: DisplayToggles = {
    labels: true,
    trails: true,
    uncertainty: true,
    grid: true,
    stems: true,
    links: true,
  };

  private selectedId: string | null = null;
  private follow = false;
  private pointerDownAt: { x: number; y: number } | null = null;
  private onSelect: SelectHandler = () => {};
  private lastSnapshot: SceneSnapshot | null = null;
  private frameId: string | null = null;
  private hasFramedContent = false;
  private animationHandle = 0;
  private resizeObserver: ResizeObserver;
  private staleTimer = 0;
  private onStaleTick: () => void = () => {};

  constructor(container: HTMLElement) {
    this.container = container;

    this.renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    // Keep CSS sizing in control of the canvas; an inline pixel size would freeze it on resize.
    this.renderer.setSize(container.clientWidth || 1, container.clientHeight || 1, false);
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;
    container.appendChild(this.renderer.domElement);

    this.labelRenderer = new CSS2DRenderer();
    this.labelRenderer.setSize(container.clientWidth || 1, container.clientHeight || 1);
    this.labelRenderer.domElement.style.position = 'absolute';
    this.labelRenderer.domElement.style.inset = '0';
    this.labelRenderer.domElement.style.pointerEvents = 'none';
    container.appendChild(this.labelRenderer.domElement);

    this.scene.background = new THREE.Color(0x000000);
    this.scene.fog = new THREE.Fog(0x000000, 30, 90);

    this.camera = new THREE.PerspectiveCamera(
      52,
      (container.clientWidth || 1) / (container.clientHeight || 1),
      0.05,
      500,
    );
    this.camera.position.set(10, 9, 13);

    this.controls = new OrbitControls(this.camera, this.renderer.domElement);
    this.controls.enableDamping = true;
    this.controls.dampingFactor = 0.08;
    this.controls.maxPolarAngle = Math.PI * 0.495;
    this.controls.target.set(4, 1, 3.5);
    this.controls.update();

    this.buildGrid();
    this.scene.add(
      new THREE.HemisphereLight(0xffffff, 0x222222, 1.1),
      this.buildDirectionalLight(),
      this.trailsRoot,
      this.stemsRoot,
      this.accuracyRoot,
      this.anchorArea,
      this.linksRoot,
    );
    this.linksRoot.add(this.linkFresh, this.linkAging);

    this.resizeObserver = new ResizeObserver(() => this.resize());
    this.resizeObserver.observe(container);

    this.renderer.domElement.addEventListener('pointerdown', this.handlePointerDown);
    this.renderer.domElement.addEventListener('pointerup', this.handlePointerUp);
    this.clock.start();
    this.loop();

    this.staleTimer = window.setInterval(() => this.onStaleTick(), 1000);
  }

  private static makeLinkLines(opacity: number): THREE.LineSegments {
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute(
      'position',
      new THREE.BufferAttribute(new Float32Array(MAX_LINK_SEGMENTS * 6), 3).setUsage(THREE.DynamicDrawUsage),
    );
    geometry.setDrawRange(0, 0);
    const lines = new THREE.LineSegments(
      geometry,
      new THREE.LineBasicMaterial({ color: LINK_COLOR, transparent: true, opacity, depthWrite: false }),
    );
    lines.frustumCulled = false;
    return lines;
  }

  private buildDirectionalLight(): THREE.DirectionalLight {
    const light = new THREE.DirectionalLight(0xffffff, 1.6);
    light.position.set(8, 14, 6);
    return light;
  }

  private buildGrid(): void {
    const grid = new THREE.GridHelper(20, 20, 0x4a4a4a, 0x262626);
    const gridMaterial = grid.material as THREE.Material;
    gridMaterial.transparent = true;
    gridMaterial.opacity = 0.85;
    this.gridGroup.add(grid);

    const axes: Array<[THREE.Vector3, THREE.Vector3, number]> = [
      [new THREE.Vector3(0, 0.002, 0), new THREE.Vector3(3, 0.002, 0), 0xff6b6b],
      [new THREE.Vector3(0, 0.002, 0), new THREE.Vector3(0, 3, 0), 0x48d597],
      [new THREE.Vector3(0, 0.002, 0), new THREE.Vector3(0, 0.002, 3), 0x4da3ff],
    ];

    for (const [start, end, color] of axes) {
      const geometry = new THREE.BufferGeometry().setFromPoints([start, end]);
      this.gridGroup.add(new THREE.Line(geometry, new THREE.LineBasicMaterial({ color })));
    }

    this.gridGroup.add(this.makeAxisLabel('X', 3.2, 0.15, 0, '#ff9b9b'));
    this.gridGroup.add(this.makeAxisLabel('Y', 0.15, 3.2, 0, '#8ff0c0'));
    this.gridGroup.add(this.makeAxisLabel('Z', 0.15, 0.1, 3.2, '#9dc9ff'));

    this.scene.add(this.gridGroup);
  }

  private makeAxisLabel(text: string, x: number, y: number, z: number, color: string): CSS2DObject {
    const el = document.createElement('div');
    el.textContent = text;
    el.style.color = color;
    el.style.font = '600 11px ui-monospace, monospace';
    el.style.opacity = '0.9';
    const object = new CSS2DObject(el);
    object.position.set(x, y, z);
    return object;
  }

  setSelectionHandler(handler: SelectHandler): void {
    this.onSelect = handler;
  }

  setStaleTickHandler(handler: () => void): void {
    this.onStaleTick = handler;
  }

  getSelectedId(): string | null {
    return this.selectedId;
  }

  select(deviceId: string | null): void {
    this.selectedId = deviceId;
    for (const [id, visual] of this.visuals) {
      const isSelected = id === deviceId;
      const material = visual.body.material as THREE.MeshStandardMaterial;
      material.emissiveIntensity = isSelected ? 0.6 : 0.12;
      visual.labelEl.classList.toggle('selected', isSelected);
    }
    this.onSelect(deviceId);
  }

  setFollow(follow: boolean): void {
    this.follow = follow;
  }

  setToggles(toggles: Partial<DisplayToggles>): void {
    Object.assign(this.toggles, toggles);
    this.gridGroup.visible = this.toggles.grid;
    this.trailsRoot.visible = this.toggles.trails;
    this.stemsRoot.visible = this.toggles.stems;
    this.accuracyRoot.visible = this.toggles.uncertainty;
    this.linksRoot.visible = this.toggles.links;
    for (const visual of this.visuals.values()) {
      if (visual.label) visual.label.visible = this.toggles.labels;
    }
  }

  applySnapshot(snapshot: SceneSnapshot): void {
    this.lastSnapshot = snapshot;

    if (this.frameId !== snapshot.frameId) {
      this.clearDevices();
      this.frameId = snapshot.frameId;
      this.hasFramedContent = false;
    }

    const seen = new Set<string>();
    const now = performance.now();

    for (const device of snapshot.devices) {
      seen.add(device.id);
      let visual = this.visuals.get(device.id);
      if (!visual) {
        visual = this.createVisual(device);
        this.visuals.set(device.id, visual);
        this.hitboxes.push(visual.hitbox);
      }
      this.updateVisual(visual, device, snapshot.serverTime, now);
    }

    for (const [id, visual] of [...this.visuals]) {
      if (!seen.has(id)) {
        this.removeVisual(id, visual);
        const index = this.hitboxes.indexOf(visual.hitbox);
        if (index >= 0) this.hitboxes.splice(index, 1);
      }
    }

    this.rebuildAnchorArea();
    this.rebuildLinks(snapshot.serverTime);

    if (snapshot.devices.length > 0 && !this.hasFramedContent) {
      this.hasFramedContent = true;
      window.requestAnimationFrame(() => this.fitAll());
    }
  }

  /** Outline the floor area spanned by the anchor phones, which fix the coordinate frame. */
  private rebuildAnchorArea(): void {
    for (const child of [...this.anchorArea.children]) {
      this.anchorArea.remove(child);
      const object = child as THREE.Mesh | THREE.Line;
      object.geometry.dispose();
      (object.material as THREE.Material).dispose();
    }

    const anchors = [...this.visuals.values()].filter((visual) => visual.role === 'anchor');
    if (anchors.length < 2) return;

    const hull = convexHull(anchors.map((visual) => new THREE.Vector2(visual.target.x, visual.target.z)));
    const outline = new THREE.LineLoop(
      new THREE.BufferGeometry().setFromPoints(hull.map((point) => new THREE.Vector3(point.x, 0.02, point.y))),
      new THREE.LineDashedMaterial({ color: ROLE_COLORS.anchor, dashSize: 0.3, gapSize: 0.18, transparent: true, opacity: 0.7 }),
    );
    outline.computeLineDistances();
    this.anchorArea.add(outline);

    if (hull.length >= 3) {
      // Shape is built in the XY plane; flip y to -z so rotating onto the floor keeps orientation.
      const fill = new THREE.Mesh(
        new THREE.ShapeGeometry(new THREE.Shape(hull.map((point) => new THREE.Vector2(point.x, -point.y)))),
        new THREE.MeshBasicMaterial({
          color: ROLE_COLORS.anchor,
          transparent: true,
          opacity: 0.05,
          side: THREE.DoubleSide,
          depthWrite: false,
        }),
      );
      fill.rotation.x = -Math.PI / 2;
      fill.position.y = 0.01;
      this.anchorArea.add(fill);
    }
  }

  /**
   * Edges come only from reported direct-neighbor observations, never from proximity.
   * A pair is drawn once, using the freshest report from either end.
   */
  private rebuildLinks(serverNow: number): void {
    const freshest = new Map<string, { a: DeviceVisual; b: DeviceVisual; age: number }>();
    for (const device of this.lastSnapshot?.devices ?? []) {
      const from = this.visuals.get(device.id);
      if (!from) continue;
      for (const neighbor of device.neighbors) {
        const to = this.visuals.get(neighbor.id);
        if (!to) continue;
        const age = serverNow - device.receivedAt + (neighbor.ageMs ?? 0);
        if (age > LINK_EXPIRE_MS) continue;
        const key = device.id < neighbor.id ? `${device.id}|${neighbor.id}` : `${neighbor.id}|${device.id}`;
        const existing = freshest.get(key);
        if (!existing || age < existing.age) freshest.set(key, { a: from, b: to, age });
      }
    }
    this.links = [...freshest.values()]
      .slice(0, MAX_LINK_SEGMENTS)
      .map(({ a, b, age }) => ({ a, b, fresh: age <= LINK_FADE_MS }));
  }

  private writeLinkPositions(): void {
    for (const [lines, fresh] of [
      [this.linkFresh, true],
      [this.linkAging, false],
    ] as const) {
      const attribute = lines.geometry.getAttribute('position') as THREE.BufferAttribute;
      const array = attribute.array as Float32Array;
      let count = 0;
      for (const link of this.links) {
        if (link.fresh !== fresh) continue;
        array.set([link.a.current.x, link.a.current.y, link.a.current.z], count * 6);
        array.set([link.b.current.x, link.b.current.y, link.b.current.z], count * 6 + 3);
        count += 1;
      }
      attribute.needsUpdate = true;
      lines.geometry.setDrawRange(0, count * 2);
    }
  }

  private clearDevices(): void {
    for (const [id, visual] of [...this.visuals]) {
      this.removeVisual(id, visual);
    }
    this.hitboxes.length = 0;
    this.links = [];
    this.selectedId = null;
    this.onSelect(null);
  }

  private createVisual(device: DeviceSnapshot): DeviceVisual {
    const group = new THREE.Group();
    const color = ROLE_COLORS[device.role];

    const bodyMaterial = new THREE.MeshStandardMaterial({
      color,
      metalness: 0.25,
      roughness: 0.4,
      emissive: new THREE.Color(color),
      emissiveIntensity: 0.12,
    });

    const body = new THREE.Mesh(PHONE_GEOMETRY, bodyMaterial);
    for (const side of [1, -1]) {
      const screen = new THREE.Mesh(SCREEN_GEOMETRY, SCREEN_MATERIAL);
      screen.position.z = side * (PHONE_DEPTH / 2 + 0.002);
      body.add(screen);
    }
    group.add(body);

    // Anchor phones are pinned at known coordinates; the halo marks them as fixed references.
    let halo: THREE.Mesh | null = null;
    if (device.role === 'anchor') {
      halo = new THREE.Mesh(
        HALO_GEOMETRY,
        new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.85 }),
      );
      halo.rotation.x = Math.PI / 2;
      group.add(halo);
    }

    const hitbox = new THREE.Mesh(
      new THREE.SphereGeometry(HIT_SCALE, 8, 6),
      new THREE.MeshBasicMaterial({ visible: false }),
    );
    hitbox.userData.deviceId = device.id;
    group.add(hitbox);

    const stem = new THREE.Mesh(
      new THREE.CylinderGeometry(0.012, 0.012, 1, 6),
      new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.45 }),
    );
    stem.geometry.translate(0, 0.5, 0);
    this.stemsRoot.add(stem);

    const markerMat = new THREE.MeshBasicMaterial({
      color,
      transparent: true,
      opacity: 0.3,
      side: THREE.DoubleSide,
      depthWrite: false,
    });
    const marker = new THREE.Mesh(new THREE.RingGeometry(0.26, 0.38, 32), markerMat);
    marker.rotation.x = -Math.PI / 2;
    marker.position.y = 0.012;

    const accuracy = new THREE.Mesh(
      new THREE.SphereGeometry(1, 20, 14),
      new THREE.MeshBasicMaterial({
        color,
        transparent: true,
        opacity: 0.08,
        depthWrite: false,
        wireframe: true,
      }),
    );
    this.accuracyRoot.add(accuracy);
    this.accuracyRoot.add(marker);

    const trailPositions = new Float32Array(120 * 3);
    const trailGeometry = new THREE.BufferGeometry();
    trailGeometry.setAttribute(
      'position',
      new THREE.BufferAttribute(trailPositions, 3).setUsage(THREE.DynamicDrawUsage),
    );
    trailGeometry.setDrawRange(0, 0);
    const trail = new THREE.Line(
      trailGeometry,
      new THREE.LineBasicMaterial({ color, transparent: true, opacity: 0.55 }),
    );
    trail.frustumCulled = false;
    this.trailsRoot.add(trail);

    const labelEl = document.createElement('div');
    labelEl.className = 'scene-label';
    labelEl.textContent = device.label ?? device.id;
    labelEl.dataset.role = device.role;
    const label = new CSS2DObject(labelEl);
    // Attach to the device group so the label follows the interpolated position.
    label.position.set(0, 0.7, 0);
    label.visible = this.toggles.labels;
    group.add(label);

    this.scene.add(group);

    return {
      group,
      body,
      halo,
      hitbox,
      stem,
      accuracy,
      trail,
      trailPositions,
      label,
      labelEl,
      marker,
      markerMat,
      current: new THREE.Vector3(device.position.x, device.position.y, device.position.z),
      target: new THREE.Vector3(device.position.x, device.position.y, device.position.z),
      from: new THREE.Vector3(device.position.x, device.position.y, device.position.z),
      targetAt: performance.now(),
      startAt: performance.now(),
      role: device.role,
      positionMode: device.positionMode,
      stale: false,
      receivedAt: device.receivedAt,
      lastTrailRevision: -1,
    };
  }

  private updateVisual(
    visual: DeviceVisual,
    device: DeviceSnapshot,
    serverTime: number,
    now: number,
  ): void {
    const targetX = device.position.x;
    const targetY = device.position.y;
    const targetZ = device.position.z;

    if (visual.target.x !== targetX || visual.target.y !== targetY || visual.target.z !== targetZ) {
      visual.from.copy(visual.current);
      visual.target.set(targetX, targetY, targetZ);
      visual.startAt = now;
      visual.targetAt = now;
    }

    visual.role = device.role;
    visual.positionMode = device.positionMode;
    visual.receivedAt = device.receivedAt;

    const name = device.label ?? device.id;
    visual.labelEl.textContent = device.estimate
      ? `${name} · Bluetooth ±${Math.round(device.estimate.r95)} m${device.estimate.ambiguous ? ' (direction unclear)' : ''}`
      : name;
    visual.labelEl.dataset.role = device.role;
    visual.labelEl.classList.toggle('floor', device.positionMode === 'floor');
    visual.labelEl.classList.toggle('selected', this.selectedId === device.id);

    visual.body.visible = true;
    visual.hitbox.userData.deviceId = device.id;

    visual.accuracy.visible = device.accuracyMeters !== null;
    if (device.accuracyMeters !== null) {
      // Bluetooth estimates across a field are honestly larger than room-scale fixes.
      const radius = Math.max(0.12, Math.min(device.accuracyMeters, device.estimate ? 150 : 25));
      visual.accuracy.scale.setScalar(radius);
    }

    this.updateTrail(visual, device);
    this.applyAge(visual, serverTime - device.receivedAt);
  }

  /** Re-evaluate fade/stale styling; the server only pushes when data changes. */
  refreshAges(serverNow: number): void {
    for (const visual of this.visuals.values()) {
      this.applyAge(visual, serverNow - visual.receivedAt);
    }
    this.rebuildLinks(serverNow);
  }

  private applyAge(visual: DeviceVisual, age: number): void {
    const stale = age > DEVICE_STALE_MS;
    const faded = age > DEVICE_FADE_MS;
    const baseColor = stale ? STALE_COLOR : ROLE_COLORS[visual.role];
    visual.stale = stale;

    const bodyMaterial = visual.body.material as THREE.MeshStandardMaterial;
    bodyMaterial.color.setHex(baseColor);
    bodyMaterial.emissive.setHex(baseColor);
    bodyMaterial.opacity = faded ? 0.45 : 1;
    bodyMaterial.transparent = faded;

    visual.labelEl.classList.toggle('stale', stale);
    visual.labelEl.style.opacity = faded ? '0.5' : '1';

    const stemMaterial = visual.stem.material as THREE.MeshBasicMaterial;
    stemMaterial.color.setHex(baseColor);
    stemMaterial.opacity = faded ? 0.2 : 0.45;

    if (visual.halo) (visual.halo.material as THREE.MeshBasicMaterial).color.setHex(baseColor);
    visual.markerMat.color.setHex(baseColor);
    visual.marker.visible = visual.positionMode === 'floor' || !stale;

    (visual.accuracy.material as THREE.MeshBasicMaterial).color.setHex(baseColor);

    const trailMaterial = visual.trail.material as THREE.LineBasicMaterial;
    trailMaterial.color.setHex(baseColor);
    trailMaterial.opacity = stale ? 0.2 : 0.55;
  }

  private updateTrail(visual: DeviceVisual, device: DeviceSnapshot): void {
    if (device.trail.length < 2) {
      visual.trail.geometry.setDrawRange(0, 0);
      return;
    }

    const positions = visual.trailPositions;
    const count = Math.min(device.trail.length, positions.length / 3);
    const offset = device.trail.length - count;

    for (let index = 0; index < count; index += 1) {
      const point = device.trail[offset + index];
      positions[index * 3] = point.x;
      positions[index * 3 + 1] = point.y;
      positions[index * 3 + 2] = point.z;
    }

    const attribute = visual.trail.geometry.getAttribute('position') as THREE.BufferAttribute;
    attribute.needsUpdate = true;
    visual.trail.geometry.setDrawRange(0, count);
  }

  private removeVisual(id: string, visual: DeviceVisual): void {
    this.scene.remove(visual.group);
    this.stemsRoot.remove(visual.stem);
    this.accuracyRoot.remove(visual.accuracy);
    this.accuracyRoot.remove(visual.marker);
    this.trailsRoot.remove(visual.trail);

    (visual.body.material as THREE.Material).dispose();
    if (visual.halo) (visual.halo.material as THREE.Material).dispose();
    visual.hitbox.geometry.dispose();
    (visual.hitbox.material as THREE.Material).dispose();
    visual.stem.geometry.dispose();
    (visual.stem.material as THREE.Material).dispose();
    visual.accuracy.geometry.dispose();
    (visual.accuracy.material as THREE.Material).dispose();
    visual.marker.geometry.dispose();
    visual.markerMat.dispose();
    visual.trail.geometry.dispose();
    (visual.trail.material as THREE.Material).dispose();
    visual.labelEl.remove();

    visual.group.removeFromParent();
    this.visuals.delete(id);

    if (this.selectedId === id) {
      this.selectedId = null;
      this.onSelect(null);
    }
  }

  private loop = (): void => {
    this.animationHandle = requestAnimationFrame(this.loop);
    const delta = this.clock.getDelta();
    const now = performance.now();

    for (const visual of this.visuals.values()) {
      const progress = Math.min(1, (now - visual.startAt) / INTERPOLATION_MS);
      const eased = progress < 1 ? 1 - (1 - progress) ** 3 : 1;
      visual.current.lerpVectors(visual.from, visual.target, eased);
      visual.group.position.copy(visual.current);

      // Do not extrapolate; hold at the last accepted sample when updates stop.
      const height = Math.max(0.0001, visual.current.y);
      visual.stem.position.set(visual.current.x, 0, visual.current.z);
      visual.stem.scale.y = height;
      visual.accuracy.position.copy(visual.current);
      visual.marker.position.set(visual.current.x, 0.012, visual.current.z);

      // Anchors stay still; moving phones turn slowly so they read as 3D objects.
      if (visual.role !== 'anchor') visual.body.rotation.y += delta * 0.6;
    }
    this.writeLinkPositions();

    if (this.follow && this.selectedId) {
      const visual = this.visuals.get(this.selectedId);
      if (visual) {
        tmpVec.copy(visual.current);
        const offset = tmpVec.clone().sub(this.controls.target);
        this.controls.target.lerp(visual.current, 0.12);
        this.camera.position.add(offset.multiplyScalar(0.12));
        this.controls.update();
      }
    }

    this.controls.update();
    this.renderer.render(this.scene, this.camera);
    this.labelRenderer.render(this.scene, this.camera);
  };

  private handlePointerDown = (event: PointerEvent): void => {
    if (event.button !== 0) return;
    this.pointerDownAt = { x: event.clientX, y: event.clientY };
  };

  // Select on release so orbit drags that start over a device do not change the selection.
  private handlePointerUp = (event: PointerEvent): void => {
    const start = this.pointerDownAt;
    this.pointerDownAt = null;
    if (event.button !== 0 || !start) return;
    if (Math.hypot(event.clientX - start.x, event.clientY - start.y) > 5) return;

    const rect = this.renderer.domElement.getBoundingClientRect();
    this.pointer.x = ((event.clientX - rect.left) / rect.width) * 2 - 1;
    this.pointer.y = -((event.clientY - rect.top) / rect.height) * 2 + 1;

    this.raycaster.setFromCamera(this.pointer, this.camera);
    const hits = this.raycaster.intersectObjects(this.hitboxes, false);
    if (hits.length > 0) {
      const id = hits[0].object.userData.deviceId as string | undefined;
      this.select(id ?? null);
    }
  };

  fitAll(): void {
    if (this.visuals.size === 0) {
      this.camera.position.set(10, 9, 13);
      this.controls.target.set(4, 1, 3.5);
      this.controls.update();
      return;
    }

    const box = new THREE.Box3();
    for (const visual of this.visuals.values()) {
      box.expandByPoint(visual.target);
    }
    box.expandByPoint(new THREE.Vector3(0, 0, 0));

    const center = box.getCenter(new THREE.Vector3());
    const size = box.getSize(new THREE.Vector3());
    const radius = Math.max(1.5, size.length() * 0.62);
    const distance = radius / Math.tan((this.camera.fov * Math.PI) / 360);

    const direction = new THREE.Vector3(0.72, 0.62, 0.9).normalize();
    this.controls.target.copy(center);
    this.camera.position.copy(center).addScaledVector(direction, distance * 1.25);
    this.controls.update();
  }

  topDown(): void {
    // Anchor phones define the frame, so center on them when there are any.
    const anchors = [...this.visuals.values()].filter((visual) => visual.role === 'anchor');
    const reference = anchors.length > 0 ? anchors : [...this.visuals.values()];
    const target = reference.length
      ? reference
          .reduce((acc, visual) => acc.add(visual.target), new THREE.Vector3())
          .divideScalar(reference.length)
      : new THREE.Vector3(4, 0, 3.5);
    target.y = 0;

    this.controls.target.copy(target);
    this.camera.position.set(target.x, target.y + 14, target.z + 0.001);
    this.controls.update();
  }

  resetCamera(): void {
    this.controls.target.set(4, 1, 3.5);
    this.camera.position.set(10, 9, 13);
    this.controls.update();
  }

  private resize(): void {
    const width = this.container.clientWidth || 1;
    const height = this.container.clientHeight || 1;
    this.camera.aspect = width / height;
    this.camera.updateProjectionMatrix();
    this.renderer.setSize(width, height, false);
    this.labelRenderer.setSize(width, height);
  }

  dispose(): void {
    cancelAnimationFrame(this.animationHandle);
    window.clearInterval(this.staleTimer);
    this.resizeObserver.disconnect();
    this.renderer.domElement.removeEventListener('pointerdown', this.handlePointerDown);
    this.renderer.domElement.removeEventListener('pointerup', this.handlePointerUp);
    this.clearDevices();
    this.controls.dispose();
    this.renderer.dispose();
    this.renderer.domElement.remove();
    this.labelRenderer.domElement.remove();
  }

  get snapshot(): SceneSnapshot | null {
    return this.lastSnapshot;
  }
}
