import * as THREE from 'three';
import { CSS2DObject, CSS2DRenderer } from 'three/addons/renderers/CSS2DRenderer.js';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import {
  DEVICE_FADE_MS,
  DEVICE_STALE_MS,
  type DeviceSnapshot,
  type SceneSnapshot,
} from '../shared/contract.ts';

const ROLE_COLORS: Record<DeviceSnapshot['role'], number> = {
  anchor: 0xf4b942,
  gateway: 0xb07cff,
  mobile: 0x48d597,
};

const STALE_COLOR = 0x6b7590;
const INTERPOLATION_MS = 700;
const HIT_SCALE = 0.75;

interface DeviceVisual {
  group: THREE.Group;
  body: THREE.Mesh;
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
  private readonly labelsRoot = new THREE.Group();
  private readonly trailsRoot = new THREE.Group();
  private readonly stemsRoot = new THREE.Group();
  private readonly accuracyRoot = new THREE.Group();
  private readonly clock = new THREE.Clock();
  private readonly container: HTMLElement;
  private readonly toggles: DisplayToggles = {
    labels: true,
    trails: true,
    uncertainty: true,
    grid: true,
    stems: true,
  };

  private selectedId: string | null = null;
  private follow = false;
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
    this.renderer.setSize(container.clientWidth || 1, container.clientHeight || 1);
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;
    container.appendChild(this.renderer.domElement);

    this.labelRenderer = new CSS2DRenderer();
    this.labelRenderer.setSize(container.clientWidth || 1, container.clientHeight || 1);
    this.labelRenderer.domElement.style.position = 'absolute';
    this.labelRenderer.domElement.style.inset = '0';
    this.labelRenderer.domElement.style.pointerEvents = 'none';
    container.appendChild(this.labelRenderer.domElement);

    this.scene.background = new THREE.Color(0x0a1020);
    this.scene.fog = new THREE.Fog(0x0a1020, 30, 90);

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
      new THREE.HemisphereLight(0xbfd4ff, 0x1a2138, 1.1),
      this.buildDirectionalLight(),
      this.labelsRoot,
      this.trailsRoot,
      this.stemsRoot,
      this.accuracyRoot,
    );

    this.resizeObserver = new ResizeObserver(() => this.resize());
    this.resizeObserver.observe(container);

    this.renderer.domElement.addEventListener('pointerdown', this.handlePointerDown);
    this.clock.start();
    this.loop();

    this.staleTimer = window.setInterval(() => this.onStaleTick(), 1000);
  }

  private buildDirectionalLight(): THREE.DirectionalLight {
    const light = new THREE.DirectionalLight(0xffffff, 1.6);
    light.position.set(8, 14, 6);
    return light;
  }

  private buildGrid(): void {
    const grid = new THREE.GridHelper(20, 20, 0x2c3a5c, 0x1a2338);
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
    this.labelsRoot.visible = this.toggles.labels;
    this.trailsRoot.visible = this.toggles.trails;
    this.stemsRoot.visible = this.toggles.stems;
    this.accuracyRoot.visible = this.toggles.uncertainty;
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

    if (snapshot.devices.length > 0 && !this.hasFramedContent) {
      this.hasFramedContent = true;
      window.requestAnimationFrame(() => this.fitAll());
    }
  }

  private clearDevices(): void {
    for (const [id, visual] of [...this.visuals]) {
      this.removeVisual(id, visual);
    }
    this.hitboxes.length = 0;
    this.selectedId = null;
    this.onSelect(null);
  }

  private createVisual(device: DeviceSnapshot): DeviceVisual {
    const group = new THREE.Group();
    const color = ROLE_COLORS[device.role];

    const geometry =
      device.role === 'anchor'
        ? new THREE.ConeGeometry(0.32, 0.7, 6)
        : device.role === 'gateway'
          ? new THREE.OctahedronGeometry(0.34)
          : new THREE.SphereGeometry(0.26, 24, 18);

    const bodyMaterial = new THREE.MeshStandardMaterial({
      color,
      metalness: 0.25,
      roughness: 0.4,
      emissive: new THREE.Color(color),
      emissiveIntensity: 0.12,
    });

    const body = new THREE.Mesh(geometry, bodyMaterial);
    if (device.role === 'anchor') body.rotation.x = Math.PI;
    group.add(body);

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
    label.position.set(0, 0.72, 0);
    this.labelsRoot.add(label);

    this.scene.add(group);

    return {
      group,
      body,
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
      lastTrailRevision: -1,
    };
  }

  private updateVisual(
    visual: DeviceVisual,
    device: DeviceSnapshot,
    serverTime: number,
    now: number,
  ): void {
    const color = ROLE_COLORS[device.role];
    const age = serverTime - device.receivedAt;
    const stale = age > DEVICE_STALE_MS;
    const faded = age > DEVICE_FADE_MS;

    const targetX = device.position.x;
    const targetY = device.position.y;
    const targetZ = device.position.z;

    if (visual.target.x !== targetX || visual.target.y !== targetY || visual.target.z !== targetZ) {
      visual.from.copy(visual.current);
      visual.target.set(targetX, targetY, targetZ);
      visual.startAt = now;
      visual.targetAt = now;
    }

    visual.stale = stale;
    visual.role = device.role;
    visual.positionMode = device.positionMode;

    const bodyMaterial = visual.body.material as THREE.MeshStandardMaterial;
    const baseColor = stale ? STALE_COLOR : color;
    bodyMaterial.color.setHex(baseColor);
    bodyMaterial.emissive.setHex(baseColor);
    bodyMaterial.opacity = faded ? 0.45 : 1;
    bodyMaterial.transparent = faded;

    visual.labelEl.textContent = device.label ?? device.id;
    visual.labelEl.dataset.role = device.role;
    visual.labelEl.classList.toggle('stale', stale);
    visual.labelEl.classList.toggle('floor', device.positionMode === 'floor');
    visual.labelEl.classList.toggle('selected', this.selectedId === device.id);
    visual.labelEl.style.opacity = faded ? '0.5' : '1';

    visual.body.visible = true;
    visual.hitbox.userData.deviceId = device.id;

    const stemMaterial = visual.stem.material as THREE.MeshBasicMaterial;
    stemMaterial.color.setHex(baseColor);
    stemMaterial.opacity = faded ? 0.2 : 0.45;

    visual.markerMat.color.setHex(baseColor);
    visual.marker.visible = device.positionMode === 'floor' || !stale;
    visual.marker.position.set(device.position.x, 0.012, device.position.z);

    const accuracyMaterial = visual.accuracy.material as THREE.MeshBasicMaterial;
    accuracyMaterial.color.setHex(baseColor);
    visual.accuracy.visible = this.toggles.uncertainty && device.accuracyMeters !== null;
    if (device.accuracyMeters !== null) {
      const radius = Math.max(0.12, Math.min(device.accuracyMeters, 25));
      visual.accuracy.scale.setScalar(radius);
      visual.accuracy.position.copy(visual.current);
    }

    this.updateTrail(visual, device, baseColor);
  }

  private updateTrail(visual: DeviceVisual, device: DeviceSnapshot, color: number): void {
    const trailMaterial = visual.trail.material as THREE.LineBasicMaterial;
    trailMaterial.color.setHex(color);
    trailMaterial.opacity = visual.stale ? 0.2 : 0.55;

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
    if (visual.label) this.labelsRoot.remove(visual.label);

    visual.body.geometry.dispose();
    (visual.body.material as THREE.Material).dispose();
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

      visual.body.rotation.y += delta * 0.6;
    }

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
    const target = this.visuals.size
      ? [...this.visuals.values()]
          .reduce((acc, visual) => acc.add(visual.target), new THREE.Vector3())
          .divideScalar(this.visuals.size)
      : new THREE.Vector3(4, 0, 3.5);

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
