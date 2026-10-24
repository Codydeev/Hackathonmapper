import {
  DEVICE_FADE_MS,
  DEVICE_STALE_MS,
  GATEWAY_WARN_MS,
  type SceneMode,
  type SceneSnapshot,
} from '../shared/contract.ts';
import { SceneView } from './scene.ts';

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
const simControls = $('sim-controls');
const simFaults = $('sim-faults');
const simToggle = $<HTMLButtonElement>('btn-sim-toggle');
const simStale = $<HTMLButtonElement>('btn-sim-stale');
const simDown = $<HTMLButtonElement>('btn-sim-down');
const statsLine = $('stats-line');
const toast = $('toast');

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

  const space = snapshot.lanUrls.length > 0 ? snapshot.lanUrls[0] : `http://localhost:${snapshot.uploadPort}`;
  uploadUrl.textContent = `${space}/api/updates`;
  uploadUrl.title = snapshot.lanUrls.join('\n') || space;

  frameValue.textContent = snapshot.frameId ?? '—';

  const stats = snapshot.stats;
  statsLine.textContent = `${stats.batches} batches · ${stats.accepted} accepted · ${stats.ignored} ignored · ${stats.rejected} rejected`;

  emptyState.hidden = snapshot.devices.length > 0;
  emptyHint.textContent =
    snapshot.mode === 'simulated'
      ? 'Simulation is paused or restarting.'
      : 'Start the gateway upload in the iPhone app, or switch to simulated data to preview the scene.';

  simControls.hidden = snapshot.mode !== 'simulated';
  simFaults.hidden = snapshot.mode !== 'simulated';
  simToggle.textContent = snapshot.simulationRunning ? 'Pause simulation' : 'Resume simulation';
  simStale.classList.toggle('active', simulatedStale);
  simDown.classList.toggle('active', simulatedGatewayDown);

  scene.applySnapshot(snapshot);
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

function renderDeviceList(snapshot: SceneSnapshot): void {
  deviceCount.textContent = String(snapshot.devices.length);
  deviceList.replaceChildren();

  const now = serverNow();
  for (const device of snapshot.devices) {
    const age = now - device.receivedAt;
    const stale = age > DEVICE_STALE_MS;
    const faded = age > DEVICE_FADE_MS;

    const item = document.createElement('li');
    item.dataset.id = device.id;
    item.setAttribute('aria-selected', String(device.id === selectedId));
    item.tabIndex = 0;

    const row = document.createElement('div');
    row.className = 'device-row';

    const name = document.createElement('span');
    name.className = 'device-name';
    name.textContent = device.label ?? device.id;

    const rolePill = document.createElement('span');
    rolePill.className = `pill ${device.role}`;
    rolePill.textContent = device.role;

    const freshPill = document.createElement('span');
    freshPill.className = `pill ${stale ? 'stale' : 'fresh'}`;
    freshPill.textContent = stale ? 'stale' : aged(age);

    row.append(name, rolePill, freshPill);

    const meta = document.createElement('div');
    meta.className = 'device-meta';
    meta.textContent =
      `${device.position.x.toFixed(2)}, ${device.position.y.toFixed(2)}, ${device.position.z.toFixed(2)} m` +
      (device.positionMode === 'floor' ? ' · height assumed' : '');

    item.append(row, meta);
    if (faded) item.style.opacity = '0.6';

    const select = (): void => {
      selectedId = device.id;
      scene.select(device.id);
      renderDeviceList(snapshot);
      renderDetails(snapshot);
    };

    item.addEventListener('click', select);
    item.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        select();
      }
    });

    deviceList.append(item);
  }
}

function aged(ms: number): string {
  return ms < 1000 ? 'live' : `${(ms / 1000).toFixed(1)}s`;
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
  ];

  for (const [key, value] of rows) {
    const dt = document.createElement('dt');
    dt.textContent = key;
    const dd = document.createElement('dd');
    dd.textContent = value;
    details.append(dt, dd);
  }
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

  source.addEventListener('error', () => {
    streamValue.textContent = 'reconnecting';
    streamValue.className = 'value warn';
  });
}

function bindDisplayToggles(): void {
  const bind = (id: string, key: 'labels' | 'trails' | 'uncertainty' | 'grid' | 'stems'): void => {
    const input = $<HTMLInputElement>(id);
    input.addEventListener('change', () => scene.setToggles({ [key]: input.checked }));
  };
  bind('toggle-labels', 'labels');
  bind('toggle-trails', 'trails');
  bind('toggle-uncertainty', 'uncertainty');
  bind('toggle-grid', 'grid');
  bind('toggle-stems', 'stems');
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

  $('btn-live').addEventListener('click', () => void switchMode('live'));
  $('btn-simulated').addEventListener('click', () => void switchMode('simulated'));

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
  if (latest) renderDeviceList(latest);
  if (latest) renderDetails(latest);
});

bindDisplayToggles();
bindButtons();
connectStream();

fetch('/api/state')
  .then((response) => response.json())
  .then((snapshot: SceneSnapshot) => applySnapshot(snapshot))
  .catch(() => showToast('Could not load initial state', true));

window.addEventListener('beforeunload', () => source?.close());
