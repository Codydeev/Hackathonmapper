import {
  DEVICE_FADE_MS,
  DEVICE_STALE_MS,
  GATEWAY_WARN_MS,
  type DeviceSnapshot,
  type SceneMode,
  type SceneSnapshot,
} from '../shared/contract.ts';
import { toCanvas } from 'qrcode';
import { FIELD_ANCHOR_LABELS, type MapSnapshot } from '../shared/map.ts';
import { buildMeshGraph, edgesOf, type MeshEdge } from './graph.ts';
import { ANCHOR_COLORS, MapView, PHONE_COLORS, type MapLayers } from './map.ts';
import { SceneView, type DisplayToggles } from './scene.ts';

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
let clockOffset = 0;
let selectedId: string | null = null;
let source: EventSource | null = null;
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

  // A phone without a position and without a Bluetooth estimate yet has only a placeholder.
  scene.applySnapshot({
    ...snapshot,
    devices: snapshot.devices.filter((device) => device.positionSource !== 'none' || device.estimate !== null),
  });
  renderDeviceList(snapshot);
  renderDetails(snapshot);
  refreshStatus();
}

function refreshStatus(): void {
  if (!latest) return;

  const lastUpload = latest.gateway.lastUploadAt;
  const gatewayAge = lastUpload === null ? Infinity : serverNow() - lastUpload;
  const gatewayDown = gatewayAge > GATEWAY_WARN_MS;

  gatewayValue.textContent = lastUpload === null ? 'waiting' : ageText(lastUpload);
  gatewayValue.className = `value ${gatewayDown ? 'warn' : 'ok'}`;
  gatewayValue.title = latest.gateway.id ? `Gateway ${latest.gateway.id}` : 'No gateway upload received';

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
    row.item.style.opacity = faded ? '0.6' : '';
    row.name.textContent = device.label ?? device.id;
    row.rolePill.className = `pill ${device.role}`;
    row.rolePill.textContent = device.role;
    row.freshPill.className = `pill ${stale ? 'stale' : 'fresh'}`;
    row.freshPill.textContent = stale ? 'stale' : aged(age);
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

/** Current links of a device after reconciling both ends' reports (see buildMeshGraph). */
function linkText(snapshot: SceneSnapshot, device: DeviceSnapshot, edges: MeshEdge[]): string {
  const links = edgesOf(edges, device.id);
  if (links.size === 0) return device.neighbors.length === 0 ? 'none reported' : 'none current';
  return [...links]
    .map(([peerId, edge]) => {
      const name = snapshot.devices.find((entry) => entry.id === peerId)?.label ?? peerId;
      const parts = [edge.status === 'confirmed' ? 'both ends' : 'one end only'];
      if (edge.rssi !== null) parts.unshift(`${Math.round(edge.rssi)} dBm`);
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
    ['Role', device.role],
    ['Position', `${device.position.x.toFixed(2)}, ${device.position.y.toFixed(2)}, ${device.position.z.toFixed(2)} m`],
    ['Height', device.positionMode === 'floor' ? 'assumed floor' : 'measured / estimated 3D'],
    ['Accuracy', device.accuracyMeters === null ? 'unknown' : `±${device.accuracyMeters.toFixed(2)} m`],
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

type View = 'scene' | 'map';

function setView(view: View): void {
  document.body.classList.toggle('view-map', view === 'map');
  tabScene.setAttribute('aria-selected', String(view === 'scene'));
  tabMap.setAttribute('aria-selected', String(view === 'map'));
  mapView.setVisible(view === 'map');
  const hash = view === 'map' ? '#map' : '';
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
  tabScene.addEventListener('click', () => setView('scene'));
  tabMap.addEventListener('click', () => setView('map'));
  window.addEventListener('hashchange', () => setView(window.location.hash === '#map' ? 'map' : 'scene'));

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
  bind('toggle-grid', 'grid');
  bind('toggle-stems', 'stems');
  bind('toggle-links', 'links');
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
});

bindDisplayToggles();
bindButtons();
bindMap();
setView(window.location.hash === '#map' ? 'map' : 'scene');
connectStream();

fetch('/api/state')
  .then((response) => response.json())
  .then((snapshot: SceneSnapshot) => applySnapshot(snapshot))
  .catch(() => showToast('Could not load initial state', true));

window.addEventListener('beforeunload', () => source?.close());
