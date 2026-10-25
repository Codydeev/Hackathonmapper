import {
  DEVICE_FADE_MS,
  DEVICE_STALE_MS,
  GATEWAY_WARN_MS,
  LINK_EXPIRE_MS,
  type DeviceSnapshot,
  type SceneSnapshot,
} from '../shared/contract.ts';

// Dashboard counterparts of the iPhone app's Network, Position and Gateway tabs, built from the
// same scene snapshots as the 3D view. All device-provided text goes in through textContent.

export type PageView = 'network' | 'positions' | 'gateway';

export interface ConnectDetails {
  publicUrl: string | null;
  lanUrls: string[];
  phoneLink: string;
}

interface MeshLink {
  key: string;
  a: DeviceSnapshot;
  b: DeviceSnapshot;
  rssi: number | null;
  /** Mean UWB distance from the ends that measured one, m. */
  uwb: number | null;
  reporters: number;
  ageMs: number;
}

// Only long generated IDs (UUIDs) are shortened; readable IDs such as phone-gateway stay whole.
const shortId = (id: string): string => (id.length > 20 ? id.slice(0, 8) : id);
const nameOf = (device: DeviceSnapshot): string => device.label ?? shortId(device.id);

function ageText(ms: number | null): string {
  if (ms === null) return 'never';
  if (ms < 1000) return 'just now';
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)} s ago`;
  return `${Math.round(ms / 60_000)} min ago`;
}

/**
 * Current links from the phones' own neighbor reports: one row per pair, kept while the
 * freshest report from either end is younger than LINK_EXPIRE_MS (matching the 3D view).
 */
export function currentLinks(snapshot: SceneSnapshot, now: number): MeshLink[] {
  const byId = new Map(snapshot.devices.map((device) => [device.id, device]));
  const links = new Map<string, MeshLink & { rssiSum: number; rssiCount: number; uwbSum: number; uwbCount: number }>();
  for (const device of snapshot.devices) {
    for (const neighbor of device.neighbors) {
      const peer = byId.get(neighbor.id);
      if (!peer) continue;
      const ageMs = now - device.receivedAt + (neighbor.ageMs ?? 0);
      if (ageMs > LINK_EXPIRE_MS) continue;
      const [a, b] = device.id < peer.id ? [device, peer] : [peer, device];
      const key = `${a.id}|${b.id}`;
      const link = links.get(key) ?? { key, a, b, rssi: null, uwb: null, reporters: 0, ageMs, rssiSum: 0, rssiCount: 0, uwbSum: 0, uwbCount: 0 };
      link.reporters += 1;
      link.ageMs = Math.min(link.ageMs, ageMs);
      if (neighbor.rssi !== null) {
        link.rssiSum += neighbor.rssi;
        link.rssiCount += 1;
        link.rssi = link.rssiSum / link.rssiCount;
      }
      if (neighbor.uwbDistanceM !== null) {
        link.uwbSum += neighbor.uwbDistanceM;
        link.uwbCount += 1;
        link.uwb = link.uwbSum / link.uwbCount;
      }
      links.set(key, link);
    }
  }
  return [...links.values()].sort((x, y) => x.key.localeCompare(y.key));
}

/** Reuses rows by key so once-a-second refreshes do not swallow clicks or reset hover. */
export function syncRows<T>(
  body: HTMLTableSectionElement,
  items: T[],
  key: (item: T) => string,
  fill: (cells: HTMLTableCellElement[], item: T, row: HTMLTableRowElement) => void,
  empty: string,
  onClick?: (key: string) => void,
): void {
  const columns = body.parentElement?.querySelectorAll('thead th').length ?? 1;
  const existing = new Map(
    [...body.rows].map((row) => [row.dataset.key ?? '', row] as [string, HTMLTableRowElement]),
  );
  const wanted: HTMLTableRowElement[] = [];

  if (items.length === 0) {
    let row = existing.get('__empty');
    if (!row) {
      row = document.createElement('tr');
      row.dataset.key = '__empty';
      row.className = 'empty-row';
      const cell = row.insertCell();
      cell.colSpan = columns;
    }
    row.cells[0].textContent = empty;
    wanted.push(row);
  }

  for (const item of items) {
    const id = key(item);
    let row = existing.get(id);
    if (!row) {
      row = document.createElement('tr');
      row.dataset.key = id;
      for (let index = 0; index < columns; index += 1) row.insertCell();
      if (onClick) {
        row.tabIndex = 0;
        row.classList.add('clickable');
        row.addEventListener('click', () => onClick(id));
        row.addEventListener('keydown', (event) => {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            onClick(id);
          }
        });
      }
    }
    fill([...row.cells], item, row);
    wanted.push(row);
  }

  wanted.forEach((row, index) => {
    if (body.rows[index] !== row) body.insertBefore(row, body.rows[index] ?? null);
  });
  while (body.rows.length > wanted.length) body.deleteRow(-1);
}

function setTile(root: HTMLElement, name: string, value: string, detail = '', tone = ''): void {
  const tile = root.querySelector<HTMLElement>(`[data-tile="${name}"]`);
  if (!tile) return;
  tile.querySelector('.tile-value')!.textContent = value;
  tile.querySelector('.tile-detail')!.textContent = detail;
  tile.dataset.tone = tone;
}

function setDetails(list: HTMLDListElement, rows: Array<[string, string]>): void {
  list.replaceChildren(
    ...rows.flatMap(([term, value]) => {
      const dt = document.createElement('dt');
      dt.textContent = term;
      const dd = document.createElement('dd');
      dd.textContent = value;
      return [dt, dd];
    }),
  );
}

const tile = (name: string, label: string): string =>
  `<div class="tile" data-tile="${name}"><span class="tile-label">${label}</span>` +
  '<span class="tile-value">–</span><span class="tile-detail"></span></div>';

const table = (rows: string, headers: string[]): string =>
  `<div class="table-wrap"><table><thead><tr>${headers.map((h) => `<th>${h}</th>`).join('')}</tr></thead>` +
  `<tbody data-rows="${rows}"></tbody></table></div>`;

const NETWORK_HTML = `
  <header class="page-head">
    <h2>Network</h2>
    <p>The mesh as reported through the gateway. Links come only from each phone's own report of its direct BLE neighbors.</p>
  </header>
  <section class="card" data-slot="mesh-node"></section>
  <div class="tiles">${tile('mode', 'Data')}${tile('devices', 'Devices')}${tile('links', 'BLE links')}${tile('gateway', 'Gateway')}</div>
  <section class="card"><h3>Devices</h3>
    ${table('devices', ['Device', 'Role', 'Links', 'Last report', 'Sequence', 'Epoch'])}
    <p class="hint">Select a device to show it in the 3D scene.</p>
  </section>
  <section class="card"><h3>BLE links</h3>
    ${table('links', ['Link', 'Signal', 'Reported by', 'Age'])}
  </section>
  <section class="card"><h3>Diagnostics</h3><dl class="details" data-list="diagnostics"></dl></section>`;

const POSITIONS_HTML = `
  <header class="page-head">
    <h2>Positions</h2>
    <p data-text="frame"></p>
  </header>
  <section class="card">
    ${table('positions', ['Device', 'Role', 'x (m)', 'y (m)', 'z (m)', 'Height', 'Accuracy', 'Measurement age', 'Received', 'Trail'])}
    <p class="hint">Positions as each phone reported them; a phone without one shows where the signal map places it. Manual or RSSI-derived coordinates are estimates, not measurements; "assumed" heights were not measured. Accuracy is a 95 % radius.</p>
  </section>`;

const GATEWAY_HTML = `
  <header class="page-head">
    <h2>Gateway</h2>
    <p>The gateway phone uploads the latest report of every phone it hears to this dashboard.</p>
  </header>
  <div class="tiles">${tile('gateway', 'Gateway phone')}${tile('upload', 'Last upload')}${tile('accepting', 'Uploads')}</div>
  <div class="page-columns">
    <section class="card"><h3>Upload addresses</h3><dl class="details" data-list="addresses"></dl></section>
    <section class="card"><h3>Upload counts</h3><dl class="details" data-list="counts"></dl></section>
  </div>
  <section class="card connect-card"><h3>Connect the gateway phone</h3>
    <div class="connect-layout">
      <canvas class="qr-large" data-qr="phone" aria-label="QR code for the gateway phone"></canvas>
      <ol>
        <li>Scan the code with the iPhone camera. MeshMapper opens with the dashboard URL and token filled in.</li>
        <li>In the app's Network tab, turn on <strong>Mesh running</strong>.</li>
        <li>In the Gateway tab, tap <strong>Check connection</strong>, then turn on <strong>Upload as gateway</strong>.</li>
        <li>Other phones only need the mesh running; they reach the dashboard through the gateway over Bluetooth.</li>
      </ol>
    </div>
    <p class="hint" data-text="connect"></p>
  </section>`;

export class PagesView {
  private readonly pages: Record<PageView, HTMLElement>;
  private active: PageView | null = null;
  private connect: ConnectDetails | null = null;
  private drawnPhoneLink: string | null = null;

  constructor(
    root: Record<PageView, HTMLElement>,
    private readonly onSelectDevice: (id: string) => void,
    private readonly drawQr: (canvas: HTMLCanvasElement, text: string) => Promise<void>,
  ) {
    this.pages = root;
    root.network.innerHTML = NETWORK_HTML;
    root.positions.innerHTML = POSITIONS_HTML;
    root.gateway.innerHTML = GATEWAY_HTML;
  }

  setActive(view: PageView | null): void {
    this.active = view;
  }

  setConnect(details: ConnectDetails): void {
    this.connect = details;
  }

  /** Renders only the visible page; called on every snapshot and once a second. */
  render(snapshot: SceneSnapshot, now: number): void {
    if (this.active === 'network') this.renderNetwork(snapshot, now);
    else if (this.active === 'positions') this.renderPositions(snapshot, now);
    else if (this.active === 'gateway') this.renderGateway(snapshot, now);
  }

  private rows(page: PageView, name: string): HTMLTableSectionElement {
    return this.pages[page].querySelector<HTMLTableSectionElement>(`[data-rows="${name}"]`)!;
  }

  private list(page: PageView, name: string): HTMLDListElement {
    return this.pages[page].querySelector<HTMLDListElement>(`[data-list="${name}"]`)!;
  }

  private renderNetwork(snapshot: SceneSnapshot, now: number): void {
    const root = this.pages.network;
    const links = currentLinks(snapshot, now);
    const stale = snapshot.devices.filter((device) => now - device.receivedAt > DEVICE_STALE_MS).length;
    const gatewayAge = snapshot.gateway.lastUploadAt === null ? null : now - snapshot.gateway.lastUploadAt;

    setTile(root, 'mode', snapshot.mode === 'simulated' ? 'Simulated' : snapshot.mode === 'live' ? 'Live' : 'Waiting',
      snapshot.frameId ? `frame ${snapshot.frameId}` : 'no frame yet');
    setTile(root, 'devices', String(snapshot.devices.length), stale ? `${stale} stale` : 'all reporting', stale ? 'warn' : 'ok');
    setTile(root, 'links', String(links.length),
      `${links.filter((link) => link.reporters > 1).length} confirmed by both ends`);
    setTile(root, 'gateway', ageText(gatewayAge),
      snapshot.gateway.id ? `phone ${shortId(snapshot.gateway.id)}` : 'no upload yet',
      gatewayAge !== null && gatewayAge <= GATEWAY_WARN_MS ? 'ok' : 'warn');

    const linkCount = (id: string): number => links.filter((link) => link.a.id === id || link.b.id === id).length;
    syncRows(this.rows('network', 'devices'), snapshot.devices, (device) => device.id, (cells, device, row) => {
      const age = now - device.receivedAt;
      cells[0].textContent = nameOf(device);
      cells[0].title = device.id;
      cells[1].textContent = device.pinned ? 'anchor · pinned' : device.role;
      cells[1].className = `role ${device.role}`;
      cells[2].textContent = String(linkCount(device.id));
      cells[3].textContent = age > DEVICE_STALE_MS ? `stale · ${ageText(age)}` : ageText(age);
      cells[3].className = age > DEVICE_STALE_MS ? 'warn' : '';
      cells[4].textContent = String(device.sequence);
      cells[5].textContent = shortId(device.epochId);
      cells[5].title = device.epochId;
      row.classList.toggle('faded', age > DEVICE_FADE_MS);
    }, 'No devices have reported yet.', this.onSelectDevice);

    syncRows(this.rows('network', 'links'), links, (link) => link.key, (cells, link) => {
      cells[0].textContent = `${nameOf(link.a)} ↔ ${nameOf(link.b)}`;
      const rssi = link.rssi === null ? 'unknown' : `${Math.round(link.rssi)} dBm`;
      cells[1].textContent = link.uwb === null ? rssi : `${rssi} · UWB ${link.uwb.toFixed(2)} m`;
      cells[2].textContent = link.reporters > 1 ? 'both ends' : 'one end';
      cells[3].textContent = ageText(link.ageMs);
    }, 'No current links. Phones report direct neighbors in their own updates.');

    setDetails(this.list('network', 'diagnostics'), [
      ['Batches received', String(snapshot.stats.batches)],
      ['Accepted reports', String(snapshot.stats.accepted)],
      ['Ignored (duplicate / old)', String(snapshot.stats.ignored)],
      ['Rejected batches', String(snapshot.stats.rejected)],
    ]);
  }

  private renderPositions(snapshot: SceneSnapshot, now: number): void {
    const frame = this.pages.positions.querySelector('[data-text="frame"]')!;
    frame.textContent =
      `Frame ${snapshot.frameId ?? '(none yet)'} · meters · y up; GPS frames: x east, z north; room frames: x right, z forward.`;

    syncRows(this.rows('positions', 'positions'), snapshot.devices, (device) => device.id, (cells, device, row) => {
      const age = now - device.receivedAt;
      cells[0].textContent = nameOf(device);
      cells[0].title = device.id;
      cells[1].textContent = device.pinned ? 'anchor · pinned' : device.role;
      cells[1].className = `role ${device.role}`;
      // The 3D view may move a phone to agree with its Bluetooth ranges; this table shows the report.
      const position = device.reportedPosition ?? device.position;
      cells[2].textContent = position.x.toFixed(2);
      cells[3].textContent = position.y.toFixed(2);
      cells[4].textContent = position.z.toFixed(2);
      cells[5].textContent = device.positionMode === 'floor' ? 'assumed (floor)' : 'estimated 3D';
      cells[6].textContent = device.accuracyMeters === null ? 'unknown' : `±${device.accuracyMeters.toFixed(2)} m`;
      cells[7].textContent = device.measurementAgeMs === null ? 'unknown' : `${device.measurementAgeMs} ms`;
      cells[8].textContent = age > DEVICE_STALE_MS ? `stale · ${ageText(age)}` : ageText(age);
      cells[8].className = age > DEVICE_STALE_MS ? 'warn' : '';
      cells[9].textContent = `${device.trail.length} pts`;
      for (const index of [2, 3, 4, 6, 7, 9]) cells[index].classList.add('num');
      row.classList.toggle('faded', age > DEVICE_FADE_MS);
    }, 'No positions yet.', this.onSelectDevice);
  }

  private renderGateway(snapshot: SceneSnapshot, now: number): void {
    const root = this.pages.gateway;
    const gatewayAge = snapshot.gateway.lastUploadAt === null ? null : now - snapshot.gateway.lastUploadAt;
    setTile(root, 'gateway', snapshot.gateway.id ? shortId(snapshot.gateway.id) : 'none yet',
      snapshot.gateway.id && snapshot.gateway.id.length > 20 ? snapshot.gateway.id : '');
    const checkAge = snapshot.gateway.lastCheckAt === null ? null : now - snapshot.gateway.lastCheckAt;
    const checkedNotUploading =
      checkAge !== null && checkAge < 120_000 && (gatewayAge === null || gatewayAge > GATEWAY_WARN_MS) &&
      (snapshot.gateway.lastUploadAt === null || snapshot.gateway.lastCheckAt! > snapshot.gateway.lastUploadAt);
    setTile(root, 'upload', ageText(gatewayAge),
      checkedNotUploading
        ? `phone checked in ${ageText(checkAge)} but is not uploading: turn on "Upload as gateway"`
        : gatewayAge !== null && gatewayAge <= GATEWAY_WARN_MS ? 'connected' : `warning after ${GATEWAY_WARN_MS / 1000} s`,
      gatewayAge !== null && gatewayAge <= GATEWAY_WARN_MS ? 'ok' : 'warn');
    setTile(root, 'accepting',
      snapshot.mode === 'simulated' ? 'Rejected' : 'Accepted',
      snapshot.mode === 'simulated'
        ? 'dashboard shows simulated data; switch to Live'
        : snapshot.mode === 'idle' ? 'the first upload switches to Live' : 'showing live data',
      snapshot.mode === 'simulated' ? 'warn' : 'ok');

    const connect = this.connect;
    const publicUrl = connect?.publicUrl ?? snapshot.publicUrl;
    const lanUrls = connect?.lanUrls ?? snapshot.lanUrls;
    setDetails(this.list('gateway', 'addresses'), [
      ['Public (any network)', publicUrl ?? 'not published (run npm run tunnel)'],
      ...lanUrls.map((url, index): [string, string] => [index === 0 ? 'Same Wi-Fi' : '', url]),
      ['Upload path', 'POST /api/updates'],
      ['Frame', snapshot.frameId ?? 'set by the first upload'],
    ]);
    setDetails(this.list('gateway', 'counts'), [
      ['Batches', String(snapshot.stats.batches)],
      ['Accepted reports', String(snapshot.stats.accepted)],
      ['Ignored (duplicate / old)', String(snapshot.stats.ignored)],
      ['Rejected batches', String(snapshot.stats.rejected)],
    ]);

    root.querySelector('[data-text="connect"]')!.textContent = publicUrl
      ? `The code points the phone at ${publicUrl}, so it can upload over mobile data or any Wi-Fi.`
      : 'Not published: the code points the phone at this laptop\'s Wi-Fi address. Run `npm run tunnel` to allow any network.';
    if (connect && connect.phoneLink !== this.drawnPhoneLink) {
      this.drawnPhoneLink = connect.phoneLink;
      void this.drawQr(root.querySelector<HTMLCanvasElement>('[data-qr="phone"]')!, connect.phoneLink);
    }
  }
}
