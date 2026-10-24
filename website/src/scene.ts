import * as THREE from 'three';
import { CSS2DObject, CSS2DRenderer } from 'three/addons/renderers/CSS2DRenderer.js';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
import {
  DEVICE_FADE_MS,
  DEVICE_STALE_MS,
  type DeviceSnapshot,
  type SceneSnapshot,
} from '../shared/contract.ts';
import { axisNames, coordinateText, latLonText, toFrame, toLatLon, type GeoOrigin } from '../shared/geoframe.ts';
import { buildMeshGraph, type LinkStatus } from './graph.ts';

const ROLE_COLORS: Record<DeviceSnapshot['role'], number> = {
  anchor: 0xf4b942,
  gateway: 0xb07cff,
  mobile: 0x48d597,
};

const STALE_COLOR = 0x8a8a8a;
/** GPS fixes: a beam to the sky and a ground ring of the reported accuracy. */
const GPS_COLOR = 0x4dd0e1;
const GPS_BEAM_TOP = 4.5;
const GPS_SATELLITE_GEOMETRY = new THREE.OctahedronGeometry(0.16);
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
  status: LinkStatus;
  /** 0–1 link quality; sets the line brightness. */
  quality: number;
}

type LinkLayer = 'confirmed' | 'one-sided' | 'aging';

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
  /** Shown while the phone reports a GPS fix: beam, satellite and accuracy ring. */
  gps: THREE.Group;
  gpsBeamMat: THREE.LineDashedMaterial;
  gpsSatelliteMat: THREE.MeshBasicMaterial;
  gpsRing: THREE.Group;
  gpsRingMat: THREE.LineBasicMaterial;
  gpsFillMat: THREE.MeshBasicMaterial;
  hasGps: boolean;
  /** An anchor held at its last GPS fix: GPS drawn grey. */
  gpsHeld: boolean;
}

export interface SceneOptions {
  snapToFloor?: boolean;
}

export interface DisplayToggles {
  labels: boolean;
  trails: boolean;
  uncertainty: boolean;
  gps: boolean;
  grid: boolean;
  stems: boolean;
  links: boolean;
}

type SelectHandler = (deviceId: string | null) => void;

const tmpVec = new THREE.Vector3();

/**
 * Frame coordinates (x east, z north in GPS frames) to scene coordinates. Three.js is right-handed
 * with y up, so frame +z must be drawn as scene -z; drawing it as +z mirrors the site.
 */
const toScene = (x: number, y: number, z: number): THREE.Vector3 => new THREE.Vector3(x, y, -z);

// OpenStreetMap tiles for the optional map background (needs internet; attribution is shown).
const TILE_URL = (zoom: number, x: number, y: number): string => `https://tile.openstreetmap.org/${zoom}/${x}/${y}.png`;
const EARTH_CIRCUMFERENCE_M = 40_075_016.686;
const MAX_TILES = 64;
const lonToTileX = (lon: number, zoom: number): number => ((lon + 180) / 360) * 2 ** zoom;
const latToTileY = (lat: number, zoom: number): number => {
  const rad = (lat * Math.PI) / 180;
  return ((1 - Math.log(Math.tan(rad) + 1 / Math.cos(rad)) / Math.PI) / 2) * 2 ** zoom;
};
const tileXToLon = (x: number, zoom: number): number => (x / 2 ** zoom) * 360 - 180;
const tileYToLat = (y: number, zoom: number): number =>
  (180 / Math.PI) * Math.atan(Math.sinh(Math.PI - (2 * Math.PI * y) / 2 ** zoom));

/** How a phone's position was obtained, for its label: "GPS ±8 m", "Bluetooth ±12 m", "manual"… */
export function sourceText(device: DeviceSnapshot): string {
  const accuracy = device.accuracyMeters === null ? '' : ` ±${Math.round(device.accuracyMeters)} m`;
  if (device.pinned) return 'pinned anchor';
  if (device.gpsHold) {
    const held = device.gpsHold.accuracyMeters === null ? '' : ` ±${Math.round(device.gpsHold.accuracyMeters)} m`;
    return `GPS lost · held at last fix${held}`;
  }
  if (device.estimate) {
    return `Bluetooth ±${Math.round(device.estimate.r95)} m${device.estimate.ambiguous ? ' (direction unclear)' : ''}`;
  }
  switch (device.positionSource) {
    case 'gps':
      return `GPS${accuracy}`;
    case 'fused':
      return `motion + anchors${accuracy}`;
    case 'uwb':
      return `UWB${accuracy}`;
    case 'none':
      return 'no position';
    default:
      return 'manual';
  }
}

/** Smallest 1/2/5 × 10ⁿ value that is at least `value`. */
function niceCeil(value: number): number {
  const power = 10 ** Math.floor(Math.log10(value));
  for (const factor of [1, 2, 5, 10]) if (factor * power >= value) return factor * power;
  return 10 * power;
}

interface Framing {
  center: THREE.Vector3;
  radius: number;
}

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
  private readonly linkLines: Record<LinkLayer, THREE.LineSegments> = {
    confirmed: SceneView.makeLinkLines(new THREE.LineBasicMaterial({
      color: LINK_COLOR, vertexColors: true, transparent: true, opacity: 0.85, depthWrite: false,
    })),
    'one-sided': SceneView.makeLinkLines(new THREE.LineDashedMaterial({
      color: LINK_COLOR, vertexColors: true, dashSize: 0.22, gapSize: 0.16, transparent: true, opacity: 0.6, depthWrite: false,
    })),
    aging: SceneView.makeLinkLines(new THREE.LineBasicMaterial({
      color: LINK_COLOR, vertexColors: true, transparent: true, opacity: 0.22, depthWrite: false,
    })),
  };
  private links: SceneLink[] = [];
  private readonly clock = new THREE.Clock();
  private readonly container: HTMLElement;
  private readonly toggles: DisplayToggles = {
    labels: true,
    trails: true,
    uncertainty: true,
    gps: true,
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
  /** Set when the user orbits or zooms; until then the camera keeps itself centered on the content. */
  private userMovedCamera = false;
  private lastFraming: Framing | null = null;
  private anchorKey = '';
  private gridPlane: THREE.GridHelper | null = null;
  private readonly axisLabels: Record<'x' | 'z', HTMLDivElement> = {
    x: document.createElement('div'),
    z: document.createElement('div'),
  };
  /** GPS origin of the current frame, if it has one. */
  private geo: GeoOrigin | null = null;
  /** Display shift applied by the caller (Center on anchors): frame = drawn + offset. */
  private frameOffset = { x: 0, z: 0 };
  private showCoordinates = true;
  private mapEnabled = false;
  private readonly mapRoot = new THREE.Group();
  private mapKey = '';
  private readonly textureLoader = new THREE.TextureLoader().setCrossOrigin('anonymous');
  private onMapStatus: (status: string) => void = () => {};
  private gridSize = 0;
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
    this.controls.addEventListener('start', () => {
      this.userMovedCamera = true;
    });

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
    this.linksRoot.add(...Object.values(this.linkLines));

    this.resizeObserver = new ResizeObserver(() => this.resize());
    this.resizeObserver.observe(container);

    this.renderer.domElement.addEventListener('pointerdown', this.handlePointerDown);
    this.renderer.domElement.addEventListener('pointerup', this.handlePointerUp);
    this.clock.start();
    this.loop();

    this.staleTimer = window.setInterval(() => this.onStaleTick(), 1000);
  }

  private static makeLinkLines(material: THREE.LineBasicMaterial | THREE.LineDashedMaterial): THREE.LineSegments {
    const geometry = new THREE.BufferGeometry();
    for (const [name, size] of [['position', 3], ['color', 3], ['lineDistance', 1]] as const) {
      geometry.setAttribute(
        name,
        new THREE.BufferAttribute(new Float32Array(MAX_LINK_SEGMENTS * 2 * size), size).setUsage(THREE.DynamicDrawUsage),
      );
    }
    geometry.setDrawRange(0, 0);
    const lines = new THREE.LineSegments(geometry, material);
    lines.frustumCulled = false;
    return lines;
  }

  private buildDirectionalLight(): THREE.DirectionalLight {
    const light = new THREE.DirectionalLight(0xffffff, 1.6);
    light.position.set(8, 14, 6);
    return light;
  }

  private buildGrid(): void {
    this.resizeGrid(20);

    const axes: Array<[THREE.Vector3, THREE.Vector3, number]> = [
      [new THREE.Vector3(0, 0.002, 0), new THREE.Vector3(3, 0.002, 0), 0xff6b6b],
      [new THREE.Vector3(0, 0.002, 0), new THREE.Vector3(0, 3, 0), 0x48d597],
      [new THREE.Vector3(0, 0.002, 0), toScene(0, 0.002, 3), 0x4da3ff],
    ];

    for (const [start, end, color] of axes) {
      const geometry = new THREE.BufferGeometry().setFromPoints([start, end]);
      this.gridGroup.add(new THREE.Line(geometry, new THREE.LineBasicMaterial({ color })));
    }

    this.gridGroup.add(this.makeAxisLabel('X', 3.2, 0.15, 0, '#ff9b9b', this.axisLabels.x));
    this.gridGroup.add(this.makeAxisLabel('Up', 0.15, 3.2, 0, '#8ff0c0'));
    const zLabel = toScene(0.15, 0.1, 3.2);
    this.gridGroup.add(this.makeAxisLabel('Z', zLabel.x, zLabel.y, zLabel.z, '#9dc9ff', this.axisLabels.z));
    this.scene.add(this.mapRoot);

    this.scene.add(this.gridGroup);
  }

  /** The floor grid (the "stage"); the axes beside it stay at the frame origin. */
  private resizeGrid(size: number): void {
    if (this.gridPlane) {
      this.gridGroup.remove(this.gridPlane);
      this.gridPlane.geometry.dispose();
      (this.gridPlane.material as THREE.Material).dispose();
    }
    const step = Math.max(1, niceCeil(size / 24));
    const grid = new THREE.GridHelper(size, Math.round(size / step), 0x4a4a4a, 0x262626);
    const gridMaterial = grid.material as THREE.Material;
    gridMaterial.transparent = true;
    gridMaterial.opacity = 0.85;
    if (this.gridPlane) grid.position.copy(this.gridPlane.position);
    this.gridPlane = grid;
    this.gridSize = size;
    this.gridGroup.add(grid);
  }

  /**
   * What the view frames: the anchors plus the main group of phones. A phone far from the rest
   * (a wrong manual entry, a bad fix) would shrink everyone else to a dot, so phones beyond 4x the
   * group's median spread are left out; anchors never are.
   */
  private focusPoints(): THREE.Vector3[] {
    const visuals = [...this.visuals.values()];
    const anchors = visuals.filter((visual) => visual.role === 'anchor').map((visual) => visual.target);
    const points = visuals.map((visual) => visual.target);
    if (points.length < 3) return points;
    const median = (values: number[]): number => {
      const sorted = [...values].sort((a, b) => a - b);
      return sorted[Math.floor(sorted.length / 2)];
    };
    const mx = median(points.map((p) => p.x));
    const mz = median(points.map((p) => p.z));
    const distances = points.map((p) => Math.hypot(p.x - mx, p.z - mz));
    const limit = Math.max(20, median(distances) * 4);
    const group = points.filter((_, index) => distances[index] <= limit);
    // Anchors are always in frame; far outliers are not.
    return [...new Set([...anchors, ...(group.length > 0 ? group : points)])];
  }

  private framing(): Framing | null {
    const points = this.focusPoints();
    if (points.length === 0) return null;
    const box = new THREE.Box3().setFromPoints(points);
    const center = box.getCenter(new THREE.Vector3());
    const radius = Math.max(4, box.getSize(new THREE.Vector3()).length() * 0.62);
    return { center, radius };
  }

  /** Moves and sizes the floor grid so it sits under the anchors (or phones), not at the origin. */
  private updateStage(framing: Framing): void {
    const size = niceCeil(Math.max(20, framing.radius * 3));
    if (size !== this.gridSize) this.resizeGrid(size);
    const step = size / Math.round(size / Math.max(1, niceCeil(size / 24)));
    this.gridPlane?.position.set(
      Math.round(framing.center.x / step) * step,
      0,
      Math.round(framing.center.z / step) * step,
    );
    if (this.mapEnabled) this.updateMapTiles(framing);
  }

  /**
   * Re-centers on new content until the user takes the camera; small movements are ignored so
   * walking phones do not make the view jump every second. Changing the anchors always re-centers.
   */
  private autoFrame(): void {
    const framing = this.framing();
    if (!framing) return;
    this.updateStage(framing);
    const anchorKey = [...this.visuals.entries()]
      .filter(([, visual]) => visual.role === 'anchor')
      .map(([id, visual]) => `${id}@${visual.target.x.toFixed(1)},${visual.target.z.toFixed(1)}`)
      .sort()
      .join(';');
    const anchorsChanged = anchorKey !== this.anchorKey;
    this.anchorKey = anchorKey;
    const last = this.lastFraming;
    const drifted =
      !last ||
      framing.center.distanceTo(last.center) > last.radius * 0.35 ||
      Math.abs(framing.radius - last.radius) > last.radius * 0.35;
    if (anchorsChanged || (!this.userMovedCamera && drifted)) this.fitAll();
  }

  private makeAxisLabel(
    text: string,
    x: number,
    y: number,
    z: number,
    color: string,
    el: HTMLDivElement = document.createElement('div'),
  ): CSS2DObject {
    el.textContent = text;
    el.style.color = color;
    el.style.font = '600 11px ui-monospace, monospace';
    el.style.opacity = '0.9';
    const object = new CSS2DObject(el);
    object.position.set(x, y, z);
    return object;
  }

  /**
   * The frame being drawn: its GPS origin (compass axes, map background), the display offset the
   * caller applied, and whether positions are meaningful enough to print on the phone labels.
   */
  setFrame(origin: GeoOrigin | null, offset: { x: number; z: number }, showCoordinates: boolean): void {
    const changed = origin !== this.geo || offset.x !== this.frameOffset.x || offset.z !== this.frameOffset.z;
    this.geo = origin;
    this.frameOffset = { ...offset };
    this.showCoordinates = showCoordinates;
    const names = axisNames(origin);
    this.axisLabels.x.textContent = names.x;
    this.axisLabels.z.textContent = names.z;
    if (changed && this.lastFraming) this.updateMapTiles(this.lastFraming);
  }

  setMapBackground(enabled: boolean, onStatus: (status: string) => void): void {
    this.mapEnabled = enabled;
    this.onMapStatus = onStatus;
    this.mapKey = '';
    const framing = this.lastFraming ?? this.framing();
    if (framing) this.updateMapTiles(framing);
    else this.clearMapTiles();
  }

  private clearMapTiles(): void {
    for (const child of [...this.mapRoot.children]) {
      this.mapRoot.remove(child);
      child.traverse((object) => {
        const mesh = object as THREE.Mesh;
        if (!mesh.isMesh) return;
        mesh.geometry.dispose();
        const material = mesh.material as THREE.MeshBasicMaterial;
        material.map?.dispose();
        material.dispose();
      });
    }
    this.mapKey = '';
  }

  /** Lays OpenStreetMap tiles on the floor under the stage, aligned with the frame. */
  private updateMapTiles(framing: Framing): void {
    if (!this.mapEnabled) {
      this.clearMapTiles();
      this.onMapStatus('');
      return;
    }
    const origin = this.geo;
    if (!origin) {
      this.clearMapTiles();
      this.onMapStatus('This frame has no GPS origin, so there is no map to show.');
      return;
    }
    // The stage in frame coordinates: scene z is -frame z, plus the caller's display offset.
    const cx = framing.center.x + this.frameOffset.x;
    const cz = -framing.center.z + this.frameOffset.z;
    const half = Math.max(this.gridSize, 40) / 2;
    const corners = [
      toLatLon(origin, cx - half, cz - half),
      toLatLon(origin, cx + half, cz + half),
      toLatLon(origin, cx - half, cz + half),
      toLatLon(origin, cx + half, cz - half),
    ];
    const lats = corners.map((c) => c.latitude);
    const lons = corners.map((c) => c.longitude);
    const metersAtZoom0 = EARTH_CIRCUMFERENCE_M * Math.cos((origin.latitude * Math.PI) / 180);
    let zoom = Math.max(3, Math.min(19, Math.floor(Math.log2(metersAtZoom0 / ((half * 2) / 4)))));
    let range = { x0: 0, x1: 0, y0: 0, y1: 0 };
    for (;;) {
      range = {
        x0: Math.floor(lonToTileX(Math.min(...lons), zoom)),
        x1: Math.floor(lonToTileX(Math.max(...lons), zoom)),
        y0: Math.floor(latToTileY(Math.max(...lats), zoom)),
        y1: Math.floor(latToTileY(Math.min(...lats), zoom)),
      };
      if ((range.x1 - range.x0 + 1) * (range.y1 - range.y0 + 1) <= MAX_TILES || zoom <= 3) break;
      zoom -= 1;
    }
    const key = `${zoom}:${range.x0}-${range.x1}:${range.y0}-${range.y1}:${this.frameOffset.x},${this.frameOffset.z}`;
    if (key === this.mapKey) return;
    this.clearMapTiles();
    this.mapKey = key;

    let failed = 0;
    const total = (range.x1 - range.x0 + 1) * (range.y1 - range.y0 + 1);
    this.onMapStatus(`Map © OpenStreetMap contributors · zoom ${zoom} · ${total} tiles`);
    const bearing = (origin.bearingDegrees * Math.PI) / 180;
    for (let tx = range.x0; tx <= range.x1; tx += 1) {
      for (let ty = range.y0; ty <= range.y1; ty += 1) {
        const west = tileXToLon(tx, zoom);
        const east = tileXToLon(tx + 1, zoom);
        const north = tileYToLat(ty, zoom);
        const south = tileYToLat(ty + 1, zoom);
        const nw = toFrame(origin, north, west);
        const ne = toFrame(origin, north, east);
        const sw = toFrame(origin, south, west);
        const center = toFrame(origin, (north + south) / 2, (west + east) / 2);
        // Measured along the tile's own edges, so a rotated frame (bearing) keeps true sizes.
        const tileWidth = Math.hypot(ne.x - nw.x, ne.z - nw.z);
        const tileDepth = Math.hypot(nw.x - sw.x, nw.z - sw.z);

        const material = new THREE.MeshBasicMaterial({ color: 0xb4b4b4, transparent: true, opacity: 0.95, depthWrite: false });
        const tile = new THREE.Mesh(new THREE.PlaneGeometry(tileWidth, tileDepth), material);
        tile.rotation.x = -Math.PI / 2; // lie flat; the image top (north) faces scene -z
        const holder = new THREE.Group();
        holder.rotation.y = bearing; // east runs along frame (cos b, sin b)
        holder.position.copy(toScene(center.x - this.frameOffset.x, -0.02, center.z - this.frameOffset.z));
        holder.add(tile);
        this.mapRoot.add(holder);

        this.textureLoader.load(
          TILE_URL(zoom, tx, ty),
          (texture) => {
            texture.colorSpace = THREE.SRGBColorSpace;
            material.map = texture;
            material.needsUpdate = true;
          },
          undefined,
          () => {
            failed += 1;
            this.onMapStatus(`Map tiles could not load (${failed}/${total}); the map needs internet.`);
          },
        );
      }
    }
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
      this.showGps(visual);
    }
  }

  /** GPS beam and ring only for phones reporting a fix, and only where positions are real. */
  private showGps(visual: DeviceVisual): void {
    const show = visual.hasGps && this.showCoordinates && this.toggles.gps;
    visual.gps.visible = show;
    visual.gpsRing.visible = show && visual.gpsRing.scale.x > 0;
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
      if (visual && (visual.role === 'anchor') !== (device.role === 'anchor')) {
        // Pinning or unpinning changes the anchor halo, which is built with the visual.
        this.removeVisual(device.id, visual, true);
        this.hitboxes.splice(this.hitboxes.indexOf(visual.hitbox), 1);
        visual = undefined;
      }
      if (!visual) {
        visual = this.createVisual(device);
        this.visuals.set(device.id, visual);
        this.hitboxes.push(visual.hitbox);
        if (this.selectedId === device.id) {
          (visual.body.material as THREE.MeshStandardMaterial).emissiveIntensity = 0.6;
        }
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
    } else {
      this.autoFrame();
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
   * Edges come only from reported direct-neighbor observations, never from proximity; see
   * `buildMeshGraph` for how the two ends' reports are reconciled.
   */
  private rebuildLinks(serverNow: number): void {
    const links: SceneLink[] = [];
    for (const edge of buildMeshGraph(this.lastSnapshot?.devices ?? [], serverNow)) {
      const a = this.visuals.get(edge.a);
      const b = this.visuals.get(edge.b);
      if (a && b) links.push({ a, b, fresh: edge.fresh, status: edge.status, quality: edge.quality });
    }
    this.links = links.slice(0, MAX_LINK_SEGMENTS);
  }

  private static linkLayer(link: SceneLink): LinkLayer {
    if (!link.fresh) return 'aging';
    return link.status === 'confirmed' ? 'confirmed' : 'one-sided';
  }

  private writeLinkPositions(): void {
    for (const [layer, lines] of Object.entries(this.linkLines) as Array<[LinkLayer, THREE.LineSegments]>) {
      const position = lines.geometry.getAttribute('position') as THREE.BufferAttribute;
      const color = lines.geometry.getAttribute('color') as THREE.BufferAttribute;
      const distance = lines.geometry.getAttribute('lineDistance') as THREE.BufferAttribute;
      const positions = position.array as Float32Array;
      const colors = color.array as Float32Array;
      const distances = distance.array as Float32Array;
      let count = 0;
      for (const link of this.links) {
        if (SceneView.linkLayer(link) !== layer) continue;
        positions.set([link.a.current.x, link.a.current.y, link.a.current.z], count * 6);
        positions.set([link.b.current.x, link.b.current.y, link.b.current.z], count * 6 + 3);
        // Weak links stay visible but recede.
        colors.fill(0.35 + 0.65 * link.quality, count * 6, count * 6 + 6);
        // Dashes restart at each segment, which is what the dashed material needs per pair.
        distances[count * 2] = 0;
        distances[count * 2 + 1] = link.a.current.distanceTo(link.b.current);
        count += 1;
      }
      position.needsUpdate = true;
      color.needsUpdate = true;
      distance.needsUpdate = true;
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
    const gpsParts = this.createGpsParts(group);
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
    const labelName = document.createElement('span');
    labelName.className = 'scene-label-name';
    labelName.textContent = device.label ?? device.id;
    const labelCoords = document.createElement('span');
    labelCoords.className = 'scene-label-coords';
    labelEl.append(labelName, labelCoords);
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
      current: toScene(device.position.x, device.position.y, device.position.z),
      target: toScene(device.position.x, device.position.y, device.position.z),
      from: toScene(device.position.x, device.position.y, device.position.z),
      targetAt: performance.now(),
      startAt: performance.now(),
      role: device.role,
      positionMode: device.positionMode,
      stale: false,
      receivedAt: device.receivedAt,
      lastTrailRevision: -1,
      ...gpsParts,
      hasGps: false,
      gpsHeld: false,
    };
  }

  /** Beam from the phone to a satellite marker (in the phone's group) plus a ground ring. */
  private createGpsParts(group: THREE.Group): Pick<
    DeviceVisual,
    'gps' | 'gpsBeamMat' | 'gpsSatelliteMat' | 'gpsRing' | 'gpsRingMat' | 'gpsFillMat'
  > {
    const gps = new THREE.Group();
    const gpsBeamMat = new THREE.LineDashedMaterial({ color: GPS_COLOR, dashSize: 0.25, gapSize: 0.15, transparent: true, opacity: 0.9 });
    const beam = new THREE.Line(
      new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(0, 0.5, 0), new THREE.Vector3(0, GPS_BEAM_TOP, 0)]),
      gpsBeamMat,
    );
    beam.computeLineDistances();
    const gpsSatelliteMat = new THREE.MeshBasicMaterial({ color: GPS_COLOR });
    const satellite = new THREE.Mesh(GPS_SATELLITE_GEOMETRY, gpsSatelliteMat);
    satellite.position.y = GPS_BEAM_TOP + 0.16;
    gps.add(beam, satellite);
    gps.visible = false;
    group.add(gps);

    const gpsRing = new THREE.Group();
    // A line edge stays one pixel wide however large the accuracy radius is.
    const gpsRingMat = new THREE.LineBasicMaterial({ color: GPS_COLOR, transparent: true, opacity: 0.8 });
    const gpsFillMat = new THREE.MeshBasicMaterial({ color: GPS_COLOR, transparent: true, opacity: 0.07, side: THREE.DoubleSide, depthWrite: false });
    const circle = Array.from({ length: 96 }, (_, i) => {
      const angle = (i / 96) * Math.PI * 2;
      return new THREE.Vector3(Math.cos(angle), 0, Math.sin(angle));
    });
    const edge = new THREE.LineLoop(new THREE.BufferGeometry().setFromPoints(circle), gpsRingMat);
    const fill = new THREE.Mesh(new THREE.CircleGeometry(1, 72), gpsFillMat);
    fill.rotation.x = -Math.PI / 2;
    gpsRing.add(edge, fill);
    gpsRing.visible = false;
    this.accuracyRoot.add(gpsRing);
    return { gps, gpsBeamMat, gpsSatelliteMat, gpsRing, gpsRingMat, gpsFillMat };
  }

  private updateVisual(
    visual: DeviceVisual,
    device: DeviceSnapshot,
    serverTime: number,
    now: number,
  ): void {
    const { x: targetX, y: targetY, z: targetZ } = toScene(device.position.x, device.position.y, device.position.z);

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
    (visual.labelEl.firstElementChild as HTMLElement).textContent = `${name} · ${sourceText(device)}`;
    visual.labelEl.dataset.source = device.pinned ? 'pinned' : device.gpsHold ? 'gps-held' : device.positionSource;
    // Always the real frame coordinates, even when the caller shifted the drawing.
    // Real GPS coordinates in GPS frames, frame meters otherwise.
    const frameX = device.position.x + this.frameOffset.x;
    const frameZ = device.position.z + this.frameOffset.z;
    (visual.labelEl.lastElementChild as HTMLElement).textContent = this.showCoordinates
      ? latLonText(this.geo, frameX, frameZ) ?? coordinateText(this.geo, frameX, frameZ)
      : '';
    visual.labelEl.dataset.role = device.role;
    visual.labelEl.classList.toggle('floor', device.positionMode === 'floor');
    visual.labelEl.classList.toggle('selected', this.selectedId === device.id);

    visual.body.visible = true;
    visual.hitbox.userData.deviceId = device.id;

    // A GPS fix gets the beam and a ground ring of its accuracy instead of the wireframe sphere.
    visual.hasGps = (device.positionSource === 'gps' || device.gpsHold !== null) && !device.pinned;
    visual.gpsHeld = device.gpsHold !== null;
    visual.gpsRing.scale.setScalar(
      visual.hasGps && device.accuracyMeters !== null ? Math.max(0.5, Math.min(device.accuracyMeters, 150)) : 0,
    );
    this.showGps(visual);
    visual.accuracy.visible = device.accuracyMeters !== null && !visual.hasGps;
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
    // A GPS fix that stopped arriving goes grey: the phone may have lost the sky.
    const gpsColor = stale || visual.gpsHeld ? STALE_COLOR : GPS_COLOR;
    visual.gpsBeamMat.color.setHex(gpsColor);
    visual.gpsSatelliteMat.color.setHex(gpsColor);
    visual.gpsRingMat.color.setHex(gpsColor);
    visual.gpsFillMat.color.setHex(gpsColor);
    visual.gpsBeamMat.opacity = faded ? 0.35 : 0.9;

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
      positions[index * 3 + 2] = -point.z;
    }

    const attribute = visual.trail.geometry.getAttribute('position') as THREE.BufferAttribute;
    attribute.needsUpdate = true;
    visual.trail.geometry.setDrawRange(0, count);
  }

  private removeVisual(id: string, visual: DeviceVisual, keepSelection = false): void {
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
    this.accuracyRoot.remove(visual.gpsRing);
    visual.gpsRing.traverse((object) => (object as THREE.Mesh | THREE.Line).geometry?.dispose());
    for (const material of [visual.gpsBeamMat, visual.gpsSatelliteMat, visual.gpsRingMat, visual.gpsFillMat]) material.dispose();
    visual.trail.geometry.dispose();
    (visual.trail.material as THREE.Material).dispose();
    visual.labelEl.remove();

    visual.group.removeFromParent();
    this.visuals.delete(id);

    if (this.selectedId === id && !keepSelection) {
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
      visual.gpsRing.position.set(visual.current.x, 0.02, visual.current.z);

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
    // An explicit fit (button, first content, anchor change) hands the camera back to auto-centering.
    this.userMovedCamera = false;
    if (this.visuals.size === 0) {
      this.camera.position.set(10, 9, 13);
      this.controls.target.set(4, 1, 3.5);
      this.controls.update();
      return;
    }

    // Frame the anchors (or every phone without anchors); the origin may be far away.
    const framing = this.framing()!;
    const { center, radius } = framing;
    this.lastFraming = { center: center.clone(), radius };
    this.updateStage(framing);
    const distance = radius / Math.tan((this.camera.fov * Math.PI) / 360);
    this.fitDepth(distance * 1.25);

    const direction = new THREE.Vector3(0.72, 0.62, 0.9).normalize();
    this.controls.target.copy(center);
    this.camera.position.copy(center).addScaledVector(direction, distance * 1.25);
    this.controls.update();
  }

  topDown(): void {
    // Anchor phones define the frame, so center on them when there are any.
    const framing = this.framing();
    const target = framing ? framing.center.clone() : new THREE.Vector3(4, 0, 3.5);
    target.y = 0;
    const height = framing ? Math.max(14, (framing.radius / Math.tan((this.camera.fov * Math.PI) / 360)) * 1.1) : 14;

    this.controls.target.copy(target);
    this.camera.position.set(target.x, height, target.z + 0.001);
    this.fitDepth(height);
    this.controls.update();
  }

  /** Scales fog and the far plane with the viewing distance so large scenes do not fade to black. */
  private fitDepth(viewDistance: number): void {
    const fog = this.scene.fog as THREE.Fog;
    fog.near = Math.max(30, viewDistance * 1.5);
    fog.far = Math.max(90, viewDistance * 4);
    this.camera.far = Math.max(500, viewDistance * 6);
    this.camera.updateProjectionMatrix();
  }

  /** Back to automatic framing on the anchors (or phones). */
  resetCamera(): void {
    this.userMovedCamera = false;
    this.fitAll();
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
