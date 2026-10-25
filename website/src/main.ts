import {
  DEVICE_FADE_MS,
  DEVICE_STALE_MS,
  GATEWAY_WARN_MS,
  RADIO_MODEL,
  type DeviceSnapshot,
  type SceneMode,
  type SceneSnapshot,
} from '../shared/contract.ts';
import { toCanvas } from 'qrcode';
import { FIELD_ANCHOR_LABELS, type MapSnapshot } from '../shared/map.ts';
import { coordinateText, geoOrigin, latLonText, toFrame, toLatLon } from '../shared/geoframe.ts';
import { buildMeshGraph, edgesOf, type MeshEdge } from './graph.ts';
import { ANCHOR_COLORS, MapView, PHONE_COLORS, type MapLayers } from './map.ts';
import { MeshNodePanel } from './meshnodepanel.ts';
import { PagesView, type PageView } from './pages.ts';
import { SceneView, sourceText, type DisplayToggles } from './scene.ts';

const $ = <T extends HTMLElement>(id: string): T => {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Missing element #${id}`);
  return element as T;
};

const sceneRoot = $('scene-root');
const scene = new SceneView(sceneRoot);

const modeDot = $('mode-dot');
const modeBadge = $('mode-badge');
const gatewayValue = $('gateway-value');
const streamValue = $('stream-value');
const frameValue = $('frame-value');
const uploadUrl = $('upload-url');
const deviceCount = $('device-count');
const deviceList = $<HTMLUListElement>('device-list');
const detailsPanel = $('details-panel');
const details = $<HTMLDListElement>('details');
const followToggle = $<HTMLInputElement>('follow-toggle');
const anchorStatus = $('anchor-status');
const pinInputs = (['pin-a', 'pin-b', 'pin-height'] as const).map((id) => $<HTMLInputElement>(id));
const pinLabels = (['pin-a-label', 'pin-b-label', 'pin-height-label'] as const).map((id) => $(id));
const pinButton = $<HTMLButtonElement>('btn-pin');
const unpinButton = $<HTMLButtonElement>('btn-unpin');
/** The device whose coordinates are in the pin inputs; refilled only when the selection changes. */
let pinEditorFor: string | null = null;
const emptyState = $('empty-state');
const emptyHint = $('empty-hint');
const btnLive = $<HTMLButtonElement>('btn-live');
const btnSimulated = $<HTMLButtonElement>('btn-simulated');
const simControls = $('sim-controls');
const simFaults = $('sim-faults');
const simToggle = $<HTMLButtonElement>('btn-sim-toggle');
const simStale = $<HTMLButtonElement>('btn-sim-stale');
const simDown = $<HTMLButtonElement>('btn-sim-down');
const statsLine = $('stats-line');
const toast = $('toast');

const mapView = new MapView($('map-root'));
const mapInactive = $('map-inactive');
const mapStatus = $('map-status');
const mapCard = $('map-card');
const mapCardTitle = $('map-card-title');
const mapCardDetails = $<HTMLDListElement>('map-card-details');
const fieldList = $<HTMLUListElement>('field-list');
const fieldCount = $('field-count');
const tabScene = $<HTMLButtonElement>('tab-scene');
const tabMap = $<HTMLButtonElement>('tab-map');
const pages = new PagesView(
  { network: $('page-network'), positions: $('page-positions'), gateway: $('page-gateway') },
  (id) => {
    // Rows on the Network and Positions pages open the device in the 3D scene.
    setView('scene');
    scene.select(id);
  },
  (canvas, text) => toCanvas(canvas, text, { width: 220, margin: 0, errorCorrectionLevel: 'L' }),
);
let latestMap: MapSnapshot | null = null;

interface ConnectInfo {
  publicUrl: string | null;
  lanUrls: string[];
  gatewayToken: string;
  phoneLink: string;
  dashboardLink: string | null;
}

const connectStatus = $('connect-status');
const connectDashboard = $('connect-dashboard');
const copyPhone = $<HTMLButtonElement>('btn-copy-phone');
const copyDashboard = $<HTMLButtonElement>('btn-copy-dashboard');
let connectInfo: ConnectInfo | null = null;
let connectFor: string | null | undefined;

let latest: SceneSnapshot | null = null;
// The dashboard's own Bluetooth mesh node (Network page); after `latest`, which it reads.
const meshPanel = new MeshNodePanel(
  $('page-network').querySelector<HTMLElement>('[data-slot="mesh-node"]')!,
  () => latest?.frameId ?? 'hervanta-v1',
  (message, isError) => showToast(message, isError),
);
let clockOffset = 0;
let selectedId: string | null = null;
let source: EventSource | null = null;
let reconnectTimer: number | null = null;
let reconnectDelayMs = 1000;
let toastTimer = 0;
let simulatedStale = false;
let simulatedGatewayDown = false;

function showToast(message: string, isError = false): void {
  toast.textContent = message;
  toast.classList.toggle('error', isError);
  toast.classList.add('show');
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => toast.classList.remove('show'), 4200);
}

async function postJson(path: string, body: unknown): Promise<Record<string, unknown>> {
  const response = await fetch(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const payload = (await response.json().catch(() => ({}))) as Record<string, unknown>;
  if (!response.ok) {
    throw new Error(typeof payload.error === 'string' ? payload.error : `Request failed (${response.status})`);
  }
  return payload;
}

function ageText(timestamp: number | null): string {
  if (timestamp === null) return 'never';
  const ms = Math.max(0, serverNow() - timestamp);
  if (ms < 1000) return 'just now';
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)} s ago`;
  return `${Math.round(ms / 60_000)} min ago`;
}

const serverNow = (): number => Date.now() + clockOffset;

function applySnapshot(snapshot: SceneSnapshot): void {
  latest = snapshot;
  clockOffset = snapshot.serverTime - Date.now();

  modeDot.className = `dot ${snapshot.mode === 'idle' ? '' : snapshot.mode}`;
  modeBadge.className = `badge ${snapshot.mode === 'idle' ? '' : snapshot.mode}`;
  modeBadge.textContent = snapshot.mode === 'simulated' ? 'simulated' : snapshot.mode === 'live' ? 'live data' : 'offline';

  const space =
    snapshot.publicUrl ??
    (snapshot.lanUrls.length > 0 ? snapshot.lanUrls[0] : `http://localhost:${snapshot.uploadPort}`);
  uploadUrl.textContent = `${space}/api/updates`;
  uploadUrl.title = [snapshot.publicUrl, ...snapshot.lanUrls].filter(Boolean).join('\n') || space;
  if (connectFor !== snapshot.publicUrl) void loadConnectInfo(snapshot.publicUrl);

  frameValue.textContent = snapshot.frameId ?? '—';

  const stats = snapshot.stats;
  statsLine.textContent = `${stats.batches} batches · ${stats.accepted} accepted · ${stats.ignored} ignored · ${stats.rejected} rejected`;

  emptyState.hidden = snapshot.devices.length > 0;
  emptyHint.textContent =
    snapshot.mode === 'simulated'
      ? 'Simulation is paused or restarting.'
      : 'Phones appear here as soon as the gateway phone uploads.';
  renderSetupSteps(snapshot);

  btnLive.classList.toggle('active', snapshot.mode === 'live');
  btnSimulated.classList.toggle('active', snapshot.mode === 'simulated');
  simControls.hidden = snapshot.mode !== 'simulated';
  simFaults.hidden = snapshot.mode !== 'simulated';
  simToggle.textContent = snapshot.simulationRunning ? 'Pause simulation' : 'Resume simulation';
  simStale.classList.toggle('active', simulatedStale);
  simDown.classList.toggle('active', simulatedGatewayDown);

  applyScene(snapshot);
  renderDeviceList(snapshot);
  renderDetails(snapshot);
  pages.render(snapshot, serverNow());
  meshPanel.syncFrame();
  refreshStatus();
}

/** Show phones where they are in the world, or laid out by their Bluetooth ranges alone. */
let signalLayout = false;
const radioModelText = $('radio-model');
/** Draw the world with the anchors' midpoint at the axes, like the signal layout centers its groups. */
let centerOnAnchors = true;
const anchorOffsetText = $('anchor-offset');

/**
 * Display-only shift of the scene so the anchors' midpoint sits at the origin (axes and stage).
 * Anchors are fixed points, so the shift stays put while phones move. Panels and pages keep
 * frame coordinates; only the 3D drawing moves.
 */
function anchorCentered(snapshot: SceneSnapshot): { snapshot: SceneSnapshot; offset: { x: number; z: number } } {
  const anchors = snapshot.devices.filter((device) => device.role === 'anchor');
  if (!centerOnAnchors || anchors.length === 0) {
    anchorOffsetText.textContent = centerOnAnchors ? 'No anchors yet: select a phone and choose Make anchor.' : '';
    return { snapshot, offset: { x: 0, z: 0 } };
  }
  const cx = anchors.reduce((sum, device) => sum + device.position.x, 0) / anchors.length;
  const cz = anchors.reduce((sum, device) => sum + device.position.z, 0) / anchors.length;
  anchorOffsetText.textContent =
    `Axes at the anchors' center: x ${cx.toFixed(1)}, z ${cz.toFixed(1)} m in frame ${snapshot.frameId ?? '–'}. ` +
    'The side panel shows frame coordinates.';
  const offset = { x: cx, z: cz };
  if (cx === 0 && cz === 0) return { snapshot, offset };
  return {
    offset,
    snapshot: {
      ...snapshot,
      devices: snapshot.devices.map((device) => ({
        ...device,
        position: { ...device.position, x: device.position.x - cx, z: device.position.z - cz },
        trail: device.trail.map((point) => ({ ...point, x: point.x - cx, z: point.z - cz })),
      })),
    },
  };
}

const mapBackgroundStatus = $('map-bg-status');
const osmAttribution = $('osm-attribution');

function applyScene(snapshot: SceneSnapshot): void {
  const radio = snapshot.signalMap.radio;
  const fitted = radio.p0 !== RADIO_MODEL.p0 || radio.n !== RADIO_MODEL.n;
  radioModelText.textContent =
    `Radio: ${radio.p0.toFixed(1)} dBm at 1 m, exponent ${radio.n.toFixed(2)}` +
    (fitted ? ' (calibrated from phones pinned within 3 m)' : ' (default)');
  if (signalLayout) {
    // Signal-map positions have no place in the world: no compass, no map, no coordinates.
    scene.setFrame(null, { x: 0, z: 0 }, false);
    scene.applySnapshot(signalLayoutSnapshot(snapshot));
    return;
  }
  // A phone without a position and without a Bluetooth estimate yet has only a placeholder.
  const centered = anchorCentered({
    ...snapshot,
    // Phones without a position are drawn once placed: estimated, pinned, or held at their last GPS fix.
    devices: snapshot.devices.filter(
      (device) => device.positionSource !== 'none' || device.estimate !== null || device.pinned || device.gpsHold !== null,
    ),
  });
  scene.setFrame(geoOrigin(snapshot.frameId), centered.offset, true);
  scene.applySnapshot(centered.snapshot);
}

/**
 * The signal map as a scene: every connected group of phones laid out by its Bluetooth ranges,
 * groups side by side. Distances between phones are what the radio measured; a group's
 * orientation means something only when two placed phones anchor it.
 */
function signalLayoutSnapshot(snapshot: SceneSnapshot): SceneSnapshot {
  const groups = new Map<number, DeviceSnapshot[]>();
  for (const device of snapshot.devices) {
    if (!device.signal?.placed) continue;
    const members = groups.get(device.signal.component) ?? [];
    members.push(device);
    groups.set(device.signal.component, members);
  }
  const devices: DeviceSnapshot[] = [];
  let cursor = 0;
  for (const [, members] of [...groups].sort((a, b) => a[0] - b[0])) {
    const xs = members.map((device) => device.signal!.x);
    const zs = members.map((device) => device.signal!.z);
    const minX = Math.min(...xs);
    const width = Math.max(...xs) - minX;
    const dz = -(Math.min(...zs) + Math.max(...zs)) / 2;
    const dx = cursor - minX;
    cursor += width + 4;
    for (const device of members) {
      const signal = device.signal!;
      const ring = signal.ringCenter !== null;
      devices.push({
        ...device,
        // Only the distance to its one link is known, so the direction it is drawn in is arbitrary.
        label: ring ? `${device.label ?? device.id} · distance only` : device.label,
        position: { x: signal.x + dx, y: 0, z: signal.z + dz },
        positionMode: 'floor',
        accuracyMeters: ring ? null : signal.r95,
        trail: [],
        estimate: null,
      });
    }
  }
  return { ...snapshot, devices };
}

function refreshStatus(): void {
  if (!latest) return;

  const lastUpload = latest.gateway.lastUploadAt;
  const gatewayAge = lastUpload === null ? Infinity : serverNow() - lastUpload;
  const gatewayDown = gatewayAge > GATEWAY_WARN_MS;

  gatewayValue.textContent = lastUpload === null ? 'waiting' : ageText(lastUpload);
  gatewayValue.className = `value ${gatewayDown ? 'warn' : 'ok'}`;
  gatewayValue.title = latest.gateway.id ? `Gateway ${latest.gateway.id}` : 'No gateway upload received';

  // The phone reached the dashboard (health check with its token) but sends no positions.
  const lastCheck = latest.gateway.lastCheckAt;
  if (gatewayDown && lastCheck !== null && serverNow() - lastCheck < 120_000 && (lastUpload === null || lastCheck > lastUpload)) {
    gatewayValue.textContent = 'connected, not uploading';
    gatewayValue.title = 'The gateway phone checked in but sends no positions. Turn on "Upload as gateway" in the app.';
  }

  if (!latest.simulationRunning && latest.mode === 'simulated') {
    gatewayValue.textContent = 'simulation paused';
    gatewayValue.className = 'value';
  }
}

interface DeviceRow {
  item: HTMLLIElement;
  name: HTMLSpanElement;
  rolePill: HTMLSpanElement;
  freshPill: HTMLSpanElement;
  meta: HTMLDivElement;
}

// Rows are reused across renders; rebuilding them every tick swallowed clicks and hover state.
const deviceRows = new Map<string, DeviceRow>();

function selectDevice(id: string): void {
  // The scene's selection handler re-renders the list and details.
  scene.select(id);
}

function createDeviceRow(id: string, onSelect: (id: string) => void = selectDevice): DeviceRow {
  const item = document.createElement('li');
  item.dataset.id = id;
  item.tabIndex = 0;

  const row = document.createElement('div');
  row.className = 'device-row';
  const name = document.createElement('span');
  name.className = 'device-name';
  const rolePill = document.createElement('span');
  const freshPill = document.createElement('span');
  row.append(name, rolePill, freshPill);

  const meta = document.createElement('div');
  meta.className = 'device-meta';
  item.append(row, meta);

  item.addEventListener('click', () => onSelect(id));
  item.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      onSelect(id);
    }
  });

  return { item, name, rolePill, freshPill, meta };
}

function renderDeviceList(snapshot: SceneSnapshot): void {
  deviceCount.textContent = String(snapshot.devices.length);

  const now = serverNow();
  const edges = buildMeshGraph(snapshot.devices, now);
  const seen = new Set<string>();
  snapshot.devices.forEach((device, index) => {
    seen.add(device.id);
    const age = now - device.receivedAt;
    const stale = age > DEVICE_STALE_MS;
    const faded = age > DEVICE_FADE_MS;

    let row = deviceRows.get(device.id);
    if (!row) {
      row = createDeviceRow(device.id);
      deviceRows.set(device.id, row);
    }

    row.item.setAttribute('aria-selected', String(device.id === selectedId));
    row.item.style.opacity = faded || device.gpsHold ? '0.6' : '';
    row.name.textContent = device.label ?? device.id;
    row.rolePill.className = `pill ${device.role}`;
    row.rolePill.textContent = device.role;
    row.freshPill.className = `pill ${stale || device.gpsHold ? 'stale' : 'fresh'}`;
    row.freshPill.textContent = stale ? 'stale' : device.gpsHold ? 'GPS lost' : aged(age);
    const linkCount = edgesOf(edges, device.id).size;
    row.meta.textContent =
      `${positionText(device)} · ${linkCount} ${linkCount === 1 ? 'link' : 'links'}`;

    if (deviceList.children[index] !== row.item) {
      deviceList.insertBefore(row.item, deviceList.children[index] ?? null);
    }
  });

  for (const [id, row] of deviceRows) {
    if (!seen.has(id)) {
      row.item.remove();
      deviceRows.delete(id);
    }
  }
}

/** Where a device's position comes from, as one line for the device list. */
function positionText(device: DeviceSnapshot): string {
  const { x, y, z } = device.position;
  const at = `${x.toFixed(1)}, ${device.positionMode === 'floor' ? '—' : y.toFixed(1)}, ${z.toFixed(1)} m`;
  // Pinned and held phones report no usable position of their own but have a fixed one here.
  if (device.pinned || device.gpsHold) return `${sourceText(device)} · ${at}`;
  if (device.positionSource === 'none') {
    const estimate = device.estimate;
    if (!estimate) return 'No GPS · waiting for a Bluetooth link to a placed phone';
    const hops = estimate.hops === null ? '' : ` · ${estimate.hops} ${estimate.hops === 1 ? 'hop' : 'hops'}`;
    return `Bluetooth estimate ±${Math.round(estimate.r95)} m${hops}${estimate.ambiguous ? ' · direction unclear' : ''}`;
  }
  const where = `${x.toFixed(1)}, ${device.positionMode === 'floor' ? '—' : y.toFixed(1)}, ${z.toFixed(1)} m`;
  const measured = { gps: 'GPS', uwb: 'UWB', fused: 'Motion + anchors' } as const;
  if (device.positionSource === 'gps' || device.positionSource === 'uwb' || device.positionSource === 'fused') {
    const source = measured[device.positionSource];
    return `${source}${device.accuracyMeters === null ? '' : ` ±${Math.round(device.accuracyMeters)} m`} · ${where}`;
  }
  return `${where}${device.positionMode === 'floor' ? ' · height assumed' : ''}`;
}

// ---- Setup checklist ---------------------------------------------------

const setupSteps = $<HTMLOListElement>('setup-steps');

function renderSetupSteps(snapshot: SceneSnapshot): void {
  const gatewayAge = snapshot.gateway.lastUploadAt === null ? null : serverNow() - snapshot.gateway.lastUploadAt;
  const gatewayOk = gatewayAge !== null && gatewayAge < GATEWAY_WARN_MS;
  const laptop = snapshot.lanUrls[0] ?? `http://localhost:${snapshot.uploadPort}`;
  const steps: [boolean, string][] = [
    [true, `Dashboard running at ${laptop}`],
    [
      gatewayOk,
      gatewayOk
        ? 'Gateway phone uploading'
        : 'Gateway phone: scan the QR code in the Connect panel with the iPhone Camera, then turn on Upload',
    ],
    [snapshot.devices.length > 0, 'Open MeshMapper on every phone: it starts by itself'],
  ];
  setupSteps.replaceChildren(
    ...steps.map(([done, text]) => {
      const item = document.createElement('li');
      item.className = done ? 'done' : '';
      item.textContent = text;
      return item;
    }),
  );
}


function aged(ms: number): string {
  return ms < 1000 ? 'live' : `${(ms / 1000).toFixed(1)}s`;
}

function signalText(device: DeviceSnapshot): string {
  const signal = device.signal;
  if (!signal) return 'not in the current map';
  if (!signal.placed) return 'no links and no position yet';
  const frame =
    signal.frame === 'world'
      ? 'anchored in the world by two or more placed phones'
      : signal.frame === 'pinned'
        ? 'one placed phone: distances known, directions not'
        : 'no placed phone: distances only';
  if (signal.ringCenter !== null && signal.ringRadius !== null) {
    const center = latest?.devices.find((entry) => entry.id === signal.ringCenter);
    return `${signal.ringRadius.toFixed(1)} m from ${center?.label ?? signal.ringCenter}, direction unknown · ${frame}`;
  }
  return `±${signal.r95.toFixed(1)} m · ${frame}`;
}

/** Current links of a device after reconciling both ends' reports (see buildMeshGraph). */
function linkText(snapshot: SceneSnapshot, device: DeviceSnapshot, edges: MeshEdge[]): string {
  const links = edgesOf(edges, device.id);
  if (links.size === 0) return device.neighbors.length === 0 ? 'none reported' : 'none current';
  return [...links]
    .map(([peerId, edge]) => {
      const name = snapshot.devices.find((entry) => entry.id === peerId)?.label ?? peerId;
      const parts = [edge.status === 'confirmed' ? 'both ends' : 'one end only'];
      if (edge.rssi !== null) parts.unshift(`${Math.round(edge.rssi)} dBm`);
      // The range the radio measured (UWB when the pair measured one), and the distance on the signal map (equal when the map fits).
      const signal = snapshot.signalMap.links.find((link) => link.a === edge.a && link.b === edge.b);
      if (signal) {
        const measured = signal.uwb !== null ? `${signal.uwb.toFixed(2)} m UWB` : `${signal.measured.toFixed(1)} ± ${signal.sigma.toFixed(1)} m measured`;
        parts.unshift(`${measured}, ${signal.layout.toFixed(1)} m on map`);
      }
      // Per-phone radio differences show up as one direction reading much stronger.
      if (edge.asymmetryDb !== null && edge.asymmetryDb >= 6) parts.push(`${Math.round(edge.asymmetryDb)} dB asymmetric`);
      return `${name} (${parts.join(', ')})`;
    })
    .join(', ');
}

function renderDetails(snapshot: SceneSnapshot): void {
  const device = snapshot.devices.find((entry) => entry.id === selectedId);
  if (!device) {
    detailsPanel.hidden = true;
    return;
  }
  detailsPanel.hidden = false;
  details.replaceChildren();

  const rows: Array<[string, string]> = [
    ['ID', device.id],
    ['Role', device.pinned ? 'anchor (pinned on the dashboard)' : device.role],
    ['Position', `${device.position.x.toFixed(2)}, ${device.position.y.toFixed(2)}, ${device.position.z.toFixed(2)} m`],
    ...(geoOrigin(snapshot.frameId)
      ? [['Location', `${coordinateText(geoOrigin(snapshot.frameId), device.position.x, device.position.z)} · ${latLonText(geoOrigin(snapshot.frameId), device.position.x, device.position.z)}`] as [string, string]]
      : []),
    ...(device.reported
      ? [['Phone reports', `${device.reported.role} at ${device.reported.position.x.toFixed(2)}, ${device.reported.position.y.toFixed(2)}, ${device.reported.position.z.toFixed(2)} m`] as [string, string]]
      : []),
    ['Position source', sourceText(device)],
    ['Height', device.positionMode === 'floor' ? 'assumed floor' : 'measured / estimated 3D'],
    ['Accuracy (95 %)', device.accuracyMeters === null ? 'unknown' : `±${device.accuracyMeters.toFixed(2)} m`],
    ...(device.reportedPosition
      ? [['Reported', `${device.reportedPosition.x.toFixed(2)}, ${device.reportedPosition.z.toFixed(2)} m (moved to agree with its Bluetooth ranges)`] as [string, string]]
      : []),
    ['Signal map', signalText(device)],
    ['Measurement age', device.measurementAgeMs === null ? 'unknown' : `${device.measurementAgeMs} ms`],
    ['Received', ageText(device.receivedAt)],
    ['Sequence', String(device.sequence)],
    ['Epoch', device.epochId],
    ['Trail points', String(device.trail.length)],
    ['BLE links', linkText(snapshot, device, buildMeshGraph(snapshot.devices, serverNow()))],
  ];

  for (const [key, value] of rows) {
    const dt = document.createElement('dt');
    dt.textContent = key;
    const dd = document.createElement('dd');
    dd.textContent = value;
    details.append(dt, dd);
  }
  renderAnchorEditor(device);
}

function renderAnchorEditor(device: DeviceSnapshot): void {
  const origin = geoOrigin(latest?.frameId ?? null);
  pinLabels[0].textContent = origin ? 'Lat' : 'x';
  pinLabels[1].textContent = origin ? 'Lon' : 'z';
  pinLabels[2].textContent = origin ? 'Height' : 'y';
  if (pinEditorFor !== device.id) {
    pinEditorFor = device.id;
    // Pre-filled with where the phone is now, which for a GPS phone is its GPS position.
    const { x, y, z } = device.position;
    if (origin) {
      const { latitude, longitude } = toLatLon(origin, x, z);
      pinInputs[0].value = latitude.toFixed(6);
      pinInputs[1].value = longitude.toFixed(6);
    } else {
      pinInputs[0].value = x.toFixed(2);
      pinInputs[1].value = z.toFixed(2);
    }
    pinInputs[2].value = y.toFixed(2);
  }
  anchorStatus.textContent = device.pinned
    ? 'Pinned here on the dashboard. Phones without their own position are placed from their Bluetooth links to anchors, and the 3D view centers on the anchors.'
    : device.role === 'anchor'
      ? 'Anchor set on the phone. Pin it to use the coordinates below instead.'
      : 'Enter where this phone really is (meters) and make it an anchor. The 3D view centers on the anchors.';
  pinButton.textContent = device.pinned ? 'Move anchor' : 'Make anchor';
  unpinButton.hidden = !device.pinned;
}

async function setPin(pin: { x: number; y: number; z: number } | null): Promise<void> {
  if (!selectedId) return;
  try {
    await postJson('/api/anchors', { id: selectedId, pin });
    pinEditorFor = null;
    showToast(pin ? 'Anchor set' : 'Anchor removed');
  } catch (error) {
    showToast((error as Error).message, true);
  }
}

async function loadConnectInfo(publicUrl: string | null): Promise<void> {
  connectFor = publicUrl;
  try {
    const response = await fetch('/api/connect');
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    connectInfo = (await response.json()) as ConnectInfo;
  } catch {
    connectStatus.textContent = 'Connection details are unavailable.';
    return;
  }

  const info = connectInfo;
  pages.setConnect(info);
  if (latest) pages.render(latest, serverNow());
  connectStatus.textContent = info.publicUrl
    ? `Public at ${info.publicUrl}. Phones can upload from any network, including mobile data.`
    : 'Not public yet: run `npm run tunnel` on the laptop. Until then the QR code connects a gateway phone on this Wi-Fi.';
  const qrOptions = { width: 150, margin: 0, errorCorrectionLevel: 'L' as const };
  await toCanvas($('qr-phone'), info.phoneLink, qrOptions);
  connectDashboard.hidden = !info.dashboardLink;
  copyDashboard.hidden = !info.dashboardLink;
  if (info.dashboardLink) await toCanvas($('qr-dashboard'), info.dashboardLink, qrOptions);
}

async function copyText(text: string, label: string): Promise<void> {
  try {
    await navigator.clipboard.writeText(text);
    showToast(`${label} copied`);
  } catch {
    // Clipboard needs a secure context; plain-http LAN pages fall back to a prompt.
    window.prompt(`Copy the ${label.toLowerCase()}:`, text);
  }
}

type View = 'scene' | 'map' | PageView;

const viewTabs: Record<View, HTMLButtonElement> = {
  scene: tabScene,
  map: tabMap,
  network: $<HTMLButtonElement>('tab-network'),
  positions: $<HTMLButtonElement>('tab-positions'),
  gateway: $<HTMLButtonElement>('tab-gateway'),
};

function viewFromHash(): View {
  const name = window.location.hash.slice(1);
  return name in viewTabs ? (name as View) : 'scene';
}

/** Elements list the views they belong to in data-view (space separated). */
function setView(view: View): void {
  for (const element of document.querySelectorAll<HTMLElement>('[data-view]')) {
    element.classList.toggle('view-hidden', !(element.dataset.view ?? '').split(' ').includes(view));
  }
  for (const [name, tab] of Object.entries(viewTabs)) tab.setAttribute('aria-selected', String(name === view));
  mapView.setVisible(view === 'map');
  pages.setActive(view === 'scene' || view === 'map' ? null : view);
  if (latest) pages.render(latest, serverNow());
  const hash = view === 'scene' ? '' : `#${view}`;
  if (window.location.hash !== hash) history.replaceState(null, '', hash || window.location.pathname);
}

function applyMap(snapshot: MapSnapshot): void {
  latestMap = snapshot;
  mapInactive.hidden = snapshot.active;
  mapView.apply(snapshot);
  const minutes = Math.floor(snapshot.elapsedSeconds / 60);
  const seconds = Math.floor(snapshot.elapsedSeconds % 60);
  mapStatus.textContent =
    `${snapshot.name} · ${snapshot.running ? 'running' : 'paused'} · ` +
    `${minutes}:${String(seconds).padStart(2, '0')} simulated`;
  renderFieldList(snapshot);
  renderMapCard(snapshot);
}

interface FieldRowEntry {
  name: string;
  kind: string;
  color: string;
  meta: string;
}

// Rows are reused like the device list so once-a-second map updates do not swallow clicks.
const fieldRows = new Map<string, DeviceRow>();
const fieldSections = new Map<string, HTMLLIElement>();

function fieldSection(text: string): HTMLLIElement {
  let item = fieldSections.get(text);
  if (!item) {
    item = document.createElement('li');
    item.className = 'section-label';
    item.textContent = text;
    fieldSections.set(text, item);
  }
  return item;
}

function fieldRow(id: string, entry: FieldRowEntry): HTMLLIElement {
  let row = fieldRows.get(id);
  if (!row) {
    row = createDeviceRow(id, (selected) => mapView.select(selected, true));
    row.freshPill.remove();
    fieldRows.set(id, row);
  }
  row.item.setAttribute('aria-selected', String(mapView.getSelectedId() === id));
  row.name.textContent = entry.name;
  row.rolePill.className = 'pill';
  row.rolePill.style.color = entry.color;
  row.rolePill.textContent = entry.kind;
  row.meta.textContent = entry.meta;
  return row.item;
}

function renderFieldList(snapshot: MapSnapshot): void {
  fieldCount.textContent = String(snapshot.anchors.length + snapshot.phones.length);
  const items = [
    fieldSection('Anchors'),
    ...snapshot.anchors.map((anchor) =>
      fieldRow(anchor.id, {
        name: anchor.label,
        kind: FIELD_ANCHOR_LABELS[anchor.kind],
        color: ANCHOR_COLORS[anchor.kind],
        meta: `${anchor.position.x.toFixed(0)}, ${anchor.position.z.toFixed(0)} m · range ${anchor.rangeMeters} m`,
      }),
    ),
    fieldSection('Phones'),
    ...snapshot.phones.map((phone) =>
      fieldRow(phone.id, {
        name: phone.label,
        kind: phone.role,
        color: PHONE_COLORS[phone.role],
        meta:
          phone.accuracyMeters === null
            ? 'no anchor in range · no fix'
            : `±${phone.accuracyMeters} m · ${phone.anchorsInRange.length} anchors · ` +
              `${snapshot.links.filter((link) => link.a === phone.id || link.b === phone.id).length} links`,
      }),
    ),
  ];

  items.forEach((item, index) => {
    if (fieldList.children[index] !== item) fieldList.insertBefore(item, fieldList.children[index] ?? null);
  });
  while (fieldList.children.length > items.length) fieldList.lastElementChild?.remove();
}

function renderMapCard(snapshot: MapSnapshot): void {
  const id = mapView.getSelectedId();
  const anchor = snapshot.anchors.find((entry) => entry.id === id);
  const phone = snapshot.phones.find((entry) => entry.id === id);
  if (!anchor && !phone) {
    mapCard.hidden = true;
    return;
  }
  mapCard.hidden = false;

  const nameOf = (key: string): string =>
    snapshot.anchors.find((entry) => entry.id === key)?.label ??
    snapshot.phones.find((entry) => entry.id === key)?.label ??
    key;
  const linksOf = (key: string): string => {
    const peers = snapshot.links
      .filter((link) => link.a === key || link.b === key)
      .map((link) => `${nameOf(link.a === key ? link.b : link.a)} (${link.rssi} dBm)`);
    return peers.length ? peers.join(', ') : 'none in range';
  };

  let rows: Array<[string, string]>;
  if (anchor) {
    mapCardTitle.textContent = anchor.label;
    rows = [
      ['Type', FIELD_ANCHOR_LABELS[anchor.kind]],
      ['Position', `${anchor.position.x.toFixed(1)}, ${anchor.position.z.toFixed(1)} m (x, z)`],
      ['Range', `${anchor.rangeMeters} m (simulated)`],
      [
        'Phones using it',
        String(snapshot.phones.filter((entry) => entry.anchorsInRange.includes(anchor.id)).length),
      ],
    ];
    if (anchor.kind === 'anchor-phone') rows.push(['BLE links', linksOf(anchor.id)]);
  } else {
    const current = phone!;
    mapCardTitle.textContent = current.label;
    rows = [
      ['Role', current.role],
      ['Position', `${current.position.x.toFixed(1)}, ${current.position.z.toFixed(1)} m (x, z)`],
      ['Accuracy', current.accuracyMeters === null ? 'no fix' : `±${current.accuracyMeters} m (simulated)`],
      ['Anchors in range', current.anchorsInRange.map(nameOf).join(', ') || 'none'],
      ['BLE links', linksOf(current.id)],
    ];
  }

  mapCardDetails.replaceChildren(
    ...rows.flatMap(([key, value]) => {
      const dt = document.createElement('dt');
      dt.textContent = key;
      const dd = document.createElement('dd');
      dd.textContent = value;
      return [dt, dd];
    }),
  );
}

function bindMap(): void {
  for (const [name, tab] of Object.entries(viewTabs)) tab.addEventListener('click', () => setView(name as View));
  window.addEventListener('hashchange', () => setView(viewFromHash()));

  copyPhone.addEventListener('click', () => connectInfo && void copyText(connectInfo.phoneLink, 'App link'));
  copyDashboard.addEventListener('click', () => {
    if (connectInfo?.dashboardLink) void copyText(connectInfo.dashboardLink, 'Dashboard link');
  });

  $('btn-map-fit').addEventListener('click', () => mapView.fit());
  $('btn-map-zoom-in').addEventListener('click', () => mapView.zoom(1.4));
  $('btn-map-zoom-out').addEventListener('click', () => mapView.zoom(1 / 1.4));
  $('btn-map-start').addEventListener('click', () => void switchMode('simulated'));

  const layer = (id: string, key: keyof MapLayers): void => {
    const input = $<HTMLInputElement>(id);
    input.addEventListener('change', () => mapView.setLayers({ [key]: input.checked }));
  };
  layer('map-labels', 'labels');
  layer('map-links', 'links');
  layer('map-fixes', 'fixes');
  layer('map-coverage', 'coverage');
  layer('map-trails', 'trails');
  layer('map-grid', 'grid');

  mapView.setSelectionHandler(() => {
    if (!latestMap) return;
    renderFieldList(latestMap);
    renderMapCard(latestMap);
  });
}

function connectStream(): void {
  source?.close();
  source = new EventSource('/api/events');

  source.addEventListener('open', () => {
    streamValue.textContent = 'connected';
    streamValue.className = 'value ok';
  });

  source.addEventListener('snapshot', (event) => {
    streamValue.textContent = 'connected';
    streamValue.className = 'value ok';
    try {
      applySnapshot(JSON.parse((event as MessageEvent<string>).data) as SceneSnapshot);
    } catch (error) {
      console.error('Bad snapshot', error);
    }
  });

  source.addEventListener('map', (event) => {
    try {
      applyMap(JSON.parse((event as MessageEvent<string>).data) as MapSnapshot);
    } catch (error) {
      console.error('Bad map snapshot', error);
    }
  });

  source.addEventListener('error', () => {
    streamValue.textContent = 'reconnecting';
    streamValue.className = 'value warn';
    // EventSource retries a dropped connection by itself, but gives up for good after an HTTP
    // error: a 502 from the tunnel while the backend restarts, or 401 when the session expired.
    if (source?.readyState !== EventSource.CLOSED || reconnectTimer !== null) return;
    const delay = reconnectDelayMs;
    reconnectDelayMs = Math.min(30_000, reconnectDelayMs * 2);
    reconnectTimer = window.setTimeout(() => {
      reconnectTimer = null;
      fetch('/api/health', { cache: 'no-store' })
        .then((response) => {
          // Signed out (public listener): the page itself now answers with the sign-in form.
          if (response.status === 401) window.location.reload();
          else connectStream();
        })
        .catch(() => connectStream());
    }, delay);
  });
  source.addEventListener('open', () => {
    reconnectDelayMs = 1000;
  });
}

function bindDisplayToggles(): void {
  const bind = (id: string, key: keyof DisplayToggles): void => {
    const input = $<HTMLInputElement>(id);
    input.addEventListener('change', () => scene.setToggles({ [key]: input.checked }));
  };
  bind('toggle-labels', 'labels');
  bind('toggle-trails', 'trails');
  bind('toggle-uncertainty', 'uncertainty');
  bind('toggle-gps', 'gps');
  bind('toggle-grid', 'grid');
  bind('toggle-stems', 'stems');
  bind('toggle-links', 'links');
  const layout = $<HTMLInputElement>('toggle-signal-layout');
  layout.addEventListener('change', () => {
    signalLayout = layout.checked;
    // The two layouts conflict: the signal map has no world position to center on anchors.
    if (signalLayout && centerAnchors.checked) {
      centerAnchors.checked = false;
      centerOnAnchors = false;
    }
    if (latest) applyScene(latest);
    window.requestAnimationFrame(() => scene.fitAll());
  });
  const mapBackground = $<HTMLInputElement>('toggle-map-bg');
  mapBackground.addEventListener('change', () => {
    osmAttribution.hidden = !mapBackground.checked;
    scene.setMapBackground(mapBackground.checked, (status) => {
      mapBackgroundStatus.textContent = status;
    });
  });
  const centerAnchors = $<HTMLInputElement>('toggle-center-anchors');
  centerAnchors.addEventListener('change', () => {
    centerOnAnchors = centerAnchors.checked;
    if (centerOnAnchors && layout.checked) {
      layout.checked = false;
      signalLayout = false;
    }
    if (latest) applyScene(latest);
    window.requestAnimationFrame(() => scene.fitAll());
  });
}

async function switchMode(mode: SceneMode): Promise<void> {
  if (mode === latest?.mode) return;
  if (latest && latest.devices.length > 0) {
    const label = mode === 'simulated' ? 'simulated data' : 'live data';
    if (!window.confirm(`Switch to ${label}? The current scene will be cleared.`)) return;
  }
  try {
    await postJson('/api/mode', { mode });
    selectedId = null;
    scene.select(null);
    showToast(mode === 'simulated' ? 'Simulation started' : 'Switched to live data');
  } catch (error) {
    showToast((error as Error).message, true);
  }
}

function bindButtons(): void {
  $('btn-fit').addEventListener('click', () => scene.fitAll());
  $('btn-top').addEventListener('click', () => scene.topDown());
  $('btn-reset-camera').addEventListener('click', () => scene.resetCamera());

  followToggle.addEventListener('change', () => scene.setFollow(followToggle.checked));

  pinButton.addEventListener('click', () => {
    const [a, b, height] = pinInputs.map((input) => Number.parseFloat(input.value));
    if (![a, b, height].every(Number.isFinite)) {
      showToast('Enter all three values', true);
      return;
    }
    // GPS frames take real coordinates (latitude, longitude); others take frame meters.
    const origin = geoOrigin(latest?.frameId ?? null);
    if (origin && (Math.abs(a) > 90 || Math.abs(b) > 180)) {
      showToast('Latitude must be within ±90° and longitude within ±180°', true);
      return;
    }
    const { x, z } = origin ? toFrame(origin, a, b) : { x: a, z: b };
    void setPin({ x, y: height, z });
  });
  unpinButton.addEventListener('click', () => void setPin(null));

  btnLive.addEventListener('click', () => void switchMode('live'));
  btnSimulated.addEventListener('click', () => void switchMode('simulated'));

  simToggle.addEventListener('click', async () => {
    try {
      await postJson('/api/simulation', { running: !latest?.simulationRunning });
    } catch (error) {
      showToast((error as Error).message, true);
    }
  });

  $('btn-sim-reset').addEventListener('click', async () => {
    try {
      await postJson('/api/simulation', { reset: true });
      showToast('Simulation restarted');
    } catch (error) {
      showToast((error as Error).message, true);
    }
  });

  simStale.addEventListener('click', async () => {
    simulatedStale = !simulatedStale;
    try {
      await postJson('/api/simulation', { stale: simulatedStale });
    } catch (error) {
      simulatedStale = !simulatedStale;
      showToast((error as Error).message, true);
    }
  });

  simDown.addEventListener('click', async () => {
    simulatedGatewayDown = !simulatedGatewayDown;
    try {
      await postJson('/api/simulation', { gatewayDown: simulatedGatewayDown });
    } catch (error) {
      simulatedGatewayDown = !simulatedGatewayDown;
      showToast((error as Error).message, true);
    }
  });

  $('btn-reset-scene').addEventListener('click', async () => {
    if (!window.confirm('Clear all positions for the current scene? This cannot be undone.')) return;
    try {
      await postJson('/api/reset', { confirm: true, mode: latest?.mode === 'simulated' ? 'simulated' : 'live' });
      selectedId = null;
      scene.select(null);
      showToast('Scene cleared');
    } catch (error) {
      showToast((error as Error).message, true);
    }
  });
}

scene.setSelectionHandler((id) => {
  selectedId = id;
  if (latest) renderDeviceList(latest);
  if (latest) renderDetails(latest);
});

scene.setStaleTickHandler(() => {
  refreshStatus();
  scene.refreshAges(serverNow());
  if (latest) renderDeviceList(latest);
  if (latest) renderDetails(latest);
  if (latest) pages.render(latest, serverNow());
  meshPanel.render();
});

bindDisplayToggles();
bindButtons();
bindMap();
setView(viewFromHash());
connectStream();

fetch('/api/state')
  .then((response) => response.json())
  // The stream's first snapshot may already be newer than this one.
  .then((snapshot: SceneSnapshot) => {
    if (!latest || snapshot.serverTime > latest.serverTime) applySnapshot(snapshot);
  })
  .catch(() => showToast('Could not load initial state', true));

window.addEventListener('beforeunload', () => source?.close());
